//! Service 22 (PC lock): the phone's "Lock PC" tile.
//!
//! Protocol (phone `service/f.java` = ControlServiceHelper, bean `PcLockData`):
//! - phone -> PC: `{"ver":"1","cmd":1}` = lock now.
//! - PC -> phone: `{"ver":"1","cmd":2,"state":1}` once locked, `{"ver":"1","cmd":2,"state":0}`
//!   once unlocked again. The phone only registers the helper when our svc 22 version is >= 2.

#[cfg(target_os = "linux")]
use std::time::Duration;

use serde_json::{Value, json};
use tokio::process::Command;
use tokio::sync::broadcast::error::RecvError;
use tracing::{info, warn};

use crate::server::Daemon;

pub const SERVICE_PC_LOCK: i64 = 22;

/// True when the phone payload is the lock request (`cmd 1`).
pub fn is_lock_request(data: &Value) -> bool {
    data.get("cmd").and_then(Value::as_i64) == Some(1)
}

/// PC -> phone lock state report (`cmd 2`, state 1 = locked, 0 = unlocked).
pub fn state_msg(locked: bool) -> Value {
    json!({ "ver": "1", "cmd": 2, "state": i32::from(locked) })
}

#[cfg(target_os = "linux")]
async fn locked_hint() -> Option<bool> {
    let out = Command::new("loginctl")
        .args(["show-session", "auto", "-p", "LockedHint", "--value"])
        .output()
        .await
        .ok()?;
    match String::from_utf8_lossy(&out.stdout).trim() {
        "yes" => Some(true),
        "no" => Some(false),
        _ => None,
    }
}

#[cfg(target_os = "linux")]
async fn lock_session() -> std::io::Result<std::process::ExitStatus> {
    Command::new("loginctl").arg("lock-session").status().await
}

/// macOS: the helper uses the private `SACLockScreenImmediate` and falls back to the
/// Control-Command-Q System Events keystroke.
#[cfg(target_os = "macos")]
async fn lock_session() -> std::io::Result<std::process::ExitStatus> {
    Command::new(crate::platform::helper_binary("smartconnect-mac-helper"))
        .arg("lock-screen")
        .status()
        .await
}

/// Listens for svc 22 frames from the phone and locks the session via `loginctl lock-session`.
pub async fn run(daemon: std::sync::Arc<Daemon>) {
    let mut frames = daemon.from_phone.subscribe();
    loop {
        let (svc, data) = match frames.recv().await {
            Ok(f) => f,
            Err(RecvError::Lagged(_)) => continue,
            Err(RecvError::Closed) => return,
        };
        if svc != SERVICE_PC_LOCK || !is_lock_request(&data) {
            continue;
        }
        info!("pc-lock: phone asked to lock the session");
        match lock_session().await {
            Ok(s) if s.success() => {}
            Ok(s) => {
                warn!("pc-lock: the lock command exited with {s}");
                continue;
            }
            Err(e) => {
                warn!("pc-lock: cannot run the lock command: {e}");
                continue;
            }
        }
        let _ = daemon.to_phone.send((SERVICE_PC_LOCK, state_msg(true)));
        // Report the unlock so the phone's tile resets. Linux follows logind's LockedHint; macOS
        // listens to the helper's distributed-notification stream, because the session dictionary
        // no longer carries the locked key on this OS (polling it always reports unlocked).
        let to_phone = daemon.to_phone.clone();
        tokio::spawn(async move {
            #[cfg(target_os = "macos")]
            if let Err(e) = watch_unlock(to_phone).await {
                warn!("pc-lock: the unlock watcher failed: {e}");
            }
            #[cfg(target_os = "linux")]
            {
                // Give up after ~24 h, or if LockedHint is unavailable.
                tokio::time::sleep(Duration::from_secs(3)).await;
                for _ in 0..(24 * 3600 / 2) {
                    match locked_hint().await {
                        Some(true) => tokio::time::sleep(Duration::from_secs(2)).await,
                        Some(false) => {
                            info!("pc-lock: session unlocked");
                            let _ = to_phone.send((SERVICE_PC_LOCK, state_msg(false)));
                            return;
                        }
                        None => return,
                    }
                }
            }
            #[cfg(not(any(target_os = "macos", target_os = "linux")))]
            let _ = to_phone;
        });
    }
}

/// macOS: run the helper's `session-locked-wait` stream and report the first unlock (state 0).
#[cfg(target_os = "macos")]
async fn watch_unlock(
    to_phone: tokio::sync::broadcast::Sender<(i64, Value)>,
) -> anyhow::Result<()> {
    use tokio::io::{AsyncBufReadExt, BufReader};
    let mut child = tokio::process::Command::new(crate::platform::helper_binary("smartconnect-mac-helper"))
        .arg("session-locked-wait")
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| anyhow::anyhow!("helper produced no output"))?;
    let mut lines = BufReader::new(stdout).lines();
    while let Some(line) = lines.next_line().await? {
        if line.trim() == "0" {
            info!("pc-lock: session unlocked");
            let _ = to_phone.send((SERVICE_PC_LOCK, state_msg(false)));
            let _ = child.kill().await;
            return Ok(());
        }
    }
    anyhow::bail!("helper exited without reporting an unlock");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_lock_request() {
        assert!(is_lock_request(&json!({"ver":"1","cmd":1})));
        assert!(!is_lock_request(&json!({"ver":"1","cmd":2,"state":1})));
        assert!(!is_lock_request(&json!({})));
    }

    #[test]
    fn state_message_shape() {
        assert_eq!(state_msg(true), json!({"ver":"1","cmd":2,"state":1}));
        assert_eq!(state_msg(false), json!({"ver":"1","cmd":2,"state":0}));
    }
}
