//! Native helper supervision on macOS.
//!
//! The Linux peer supervises four GTK/GStreamer/Wayland helper processes. On macOS the menu-bar
//! app is started by the user (or at login) and the daemon exposes everything it needs over the
//! control socket. Mirroring, App streaming and Screen share / Mobile desktop are answered by the
//! menu-bar app's stream host (a WKWebView answerer, see `macapp/SmartConnectApp.swift`), so the
//! corresponding tiles (services 1 and 15) are advertised by default — the Screen share flow is
//! verified end-to-end on a device (video + input; the answer keeps the phone's offer untouched
//! and mDNS ICE candidates are rewritten to their real LAN address, see
//! docs/protocol/mirroring.md). Cross control (26) and phone-as-display helpers are not part of
//! this port yet, so those tiles stay hidden unless the user opts in with --extra-tiles or
//! --all-tiles.
//!
//! The one external helper supervised here is `smartconnect-webcam --answer`: started on svc 3
//! cmd 0 `{isReply:0}` (Webcam tile tapped) when no webcam session holds its lock; the helper
//! replies to the phone and runs the session, showing the camera in a window (see `webcam/`).
//! Binary: `$SMARTCONNECT_WEBCAM_BIN`, else next to smartconnectd (the app bundle's
//! `Contents/MacOS`, or the workspace's target directory), else `$PATH`.
//! `SMARTCONNECT_HELPERS=0` disables this.
//!
//! This module keeps the same surface as the Linux supervisor so `main.rs` stays shared.

use std::os::fd::AsRawFd;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::Value;
use tokio::process::{Child, Command};
use tokio::sync::broadcast::error::RecvError;
use tracing::{info, warn};

use crate::server::Daemon;
use crate::webcam;

pub const WEBCAM: &str = "smartconnect-webcam";

/// PIDs of the children we started, signalled on daemon shutdown.
#[derive(Default)]
pub struct Helpers {
    pids: Mutex<Vec<u32>>,
}

impl Helpers {
    pub fn enabled() -> bool {
        std::env::var("SMARTCONNECT_HELPERS").map_or(true, |v| v != "0")
    }

    pub fn start(self: &Arc<Self>, daemon: Arc<Daemon>) {
        if !Self::enabled() {
            info!("helpers: disabled by SMARTCONNECT_HELPERS=0");
            return;
        }
        info!("helpers: macOS backend (webcam helper on demand; streams are hosted by the app)");
        tokio::spawn(self.clone().answer_webcam(daemon));
    }

    /// SIGTERM every child we started and give them a moment to tell the phone (cmd 2).
    pub async fn shutdown(&self) {
        let pids = std::mem::take(&mut *self.pids.lock().unwrap());
        for &pid in &pids {
            signal(pid, libc::SIGTERM);
        }
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline && pids.iter().any(|&p| alive(p)) {
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }

    fn spawn(&self, name: &str, args: &[&str]) -> std::io::Result<Child> {
        let bin = binary(name);
        let log_path = crate::platform::log_dir().join(format!("{name}.log"));
        let _ = std::fs::create_dir_all(crate::platform::log_dir());
        let log = std::fs::OpenOptions::new().create(true).append(true).open(&log_path)?;
        let mut cmd = Command::new(&bin);
        // macOS has no PR_SET_PDEATHSIG; the helper exits on its own when the control socket
        // closes, and kill_on_drop covers a normal daemon exit.
        cmd.args(args).stdin(Stdio::null()).stdout(log.try_clone()?).stderr(log).kill_on_drop(true);
        let child = cmd.spawn().map_err(|e| {
            let hint = if e.kind() == std::io::ErrorKind::NotFound {
                format!(" (not next to smartconnectd or on PATH; set {})", env_var(name))
            } else {
                String::new()
            };
            std::io::Error::new(e.kind(), format!("{}: {e}{hint}", bin.display()))
        })?;
        if let Some(pid) = child.id() {
            self.pids.lock().unwrap().push(pid);
            info!(pid, bin = %bin.display(), ?args, log = %log_path.display(), "helpers: started {name}");
        }
        Ok(child)
    }

    fn forget(&self, pid: Option<u32>) {
        if let Some(pid) = pid {
            self.pids.lock().unwrap().retain(|&p| p != pid);
        }
    }

    /// Phone svc 3 cmd 0 `{isReply:0}` (user tapped Webcam): make sure a webcam helper answers.
    async fn answer_webcam(self: Arc<Self>, daemon: Arc<Daemon>) {
        let mut frames = daemon.from_phone.subscribe();
        loop {
            let data: Value = match frames.recv().await {
                Ok((webcam::SERVICE_WEBCAM, d)) => d,
                Ok(_) | Err(RecvError::Lagged(_)) => continue,
                Err(RecvError::Closed) => return,
            };
            if !webcam::is_phone_request(&data) {
                continue;
            }
            if lock_held(&webcam_lock_path()) {
                info!("helpers: webcam requested by the phone; the running webcam session answers");
                continue;
            }
            match self.spawn(WEBCAM, &["--answer"]) {
                Ok(mut child) => {
                    let me = self.clone();
                    tokio::spawn(async move {
                        let status = child.wait().await;
                        me.forget(child.id());
                        info!(?status, "helpers: webcam session ended");
                    });
                }
                Err(e) => {
                    warn!("helpers: can't start the webcam helper for the phone's request: {e}");
                    // The phone then explains that the PC needs its webcam driver.
                    let _ = daemon.to_phone.send((webcam::SERVICE_WEBCAM, webcam::error_msg(webcam::ERR_NO_DRIVER)));
                }
            }
        }
    }
}

/// The helper's single-instance lock; it lives in the same runtime directory as the daemon's.
pub fn webcam_lock_path() -> PathBuf {
    crate::platform::runtime_dir().join("smartconnect-webcam.lock")
}

/// Where the helper `name` is: `$SMARTCONNECT_<NAME>_BIN`, else a file of that name next to
/// smartconnectd, else the bare name, which `Command` looks up on `$PATH`.
pub fn binary(name: &str) -> PathBuf {
    if let Some(p) = std::env::var_os(env_var(name)).filter(|p| !p.is_empty()) {
        return PathBuf::from(p);
    }
    std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(|dir| dir.join(name)))
        .filter(|p| p.is_file())
        .unwrap_or_else(|| PathBuf::from(name))
}

/// `smartconnect-webcam` → `SMARTCONNECT_WEBCAM_BIN`.
fn env_var(name: &str) -> String {
    format!("{}_BIN", name.to_uppercase().replace('-', "_"))
}

fn lock_held(path: &std::path::Path) -> bool {
    let Ok(f) = std::fs::File::open(path) else { return false };
    // SAFETY: flock on an fd we own; a shared lock fails while the helper holds its exclusive one.
    let free = unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_SH | libc::LOCK_NB) } == 0;
    !free
}

fn signal(pid: u32, sig: libc::c_int) {
    if let Ok(pid) = libc::pid_t::try_from(pid) {
        // SAFETY: kill(2) on a child we spawned.
        unsafe { libc::kill(pid, sig) };
    }
}

fn alive(pid: u32) -> bool {
    // SAFETY: signal 0 only checks that the pid exists.
    libc::pid_t::try_from(pid).is_ok_and(|p| unsafe { libc::kill(p, 0) } == 0)
}
