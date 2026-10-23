//! Platform paths and small OS helpers.
//!
//! macOS uses the standard Library locations:
//! - state:   `~/Library/Application Support/SmartConnect`
//! - cache:   `~/Library/Caches/SmartConnect`
//! - runtime: `$TMPDIR/smartconnect`
//! - logs:    `~/Library/Logs/SmartConnect`
//!
//! Linux keeps the XDG layout the upstream project uses. The helpers that need a graphical
//! session (`smartconnect-mac-helper`) are bundled next to `smartconnectd` or in `PATH`.

use std::path::PathBuf;

pub const APP_DIR_NAME: &str = "SmartConnect";

#[cfg(target_os = "macos")]
pub fn state_dir() -> PathBuf {
    home().join("Library/Application Support").join(APP_DIR_NAME)
}

#[cfg(target_os = "linux")]
pub fn state_dir() -> PathBuf {
    std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share")))
        .unwrap_or_else(|| PathBuf::from("."))
        .join("smartconnect-linux")
}

#[cfg(target_os = "macos")]
pub fn cache_dir() -> PathBuf {
    home().join("Library/Caches").join(APP_DIR_NAME)
}

#[cfg(target_os = "linux")]
pub fn cache_dir() -> PathBuf {
    std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".cache")))
        .unwrap_or_else(|| std::env::temp_dir())
        .join("smartconnect-linux")
}

#[cfg(target_os = "macos")]
pub fn runtime_dir() -> PathBuf {
    // `$TMPDIR` is already private to the user on macOS. Keep our own subdirectory so a stale
    // socket from a crashed daemon is easy to identify and remove.
    let base = std::env::var_os("TMPDIR").map(PathBuf::from).unwrap_or_else(std::env::temp_dir);
    let dir = base.join("smartconnect");
    let _ = std::fs::create_dir_all(&dir);
    dir
}

#[cfg(target_os = "linux")]
pub fn runtime_dir() -> PathBuf {
    std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(std::env::temp_dir)
}

#[cfg(target_os = "macos")]
pub fn log_dir() -> PathBuf {
    home().join("Library/Logs").join(APP_DIR_NAME)
}

#[cfg(target_os = "linux")]
pub fn log_dir() -> PathBuf {
    state_dir().join("logs")
}

/// The daemon's local control socket (newline-delimited JSON commands).
pub fn control_socket() -> PathBuf {
    #[cfg(target_os = "macos")]
    {
        state_dir().join("control.sock")
    }
    #[cfg(target_os = "linux")]
    {
        runtime_dir().join("smartconnectd.sock")
    }
}

/// Where the menu-bar app listens for notification frames from the daemon.
pub fn notifications_socket() -> PathBuf {
    runtime_dir().join("notifications.sock")
}

/// Where a Swift helper binary is: next to `smartconnectd` first (a bundle or a Cargo build
/// directory), then `PATH`.
pub fn helper_binary(name: &str) -> PathBuf {
    if let Some(p) = std::env::var_os("SMARTCONNECT_HELPER_BIN").filter(|p| !p.is_empty()) {
        return PathBuf::from(p);
    }
    std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(|dir| dir.join(name)))
        .filter(|p| p.is_file())
        .unwrap_or_else(|| PathBuf::from(name))
}

/// Marketing-ish model name for the phone's device page.
pub fn product_model() -> String {
    #[cfg(target_os = "macos")]
    {
        if let Ok(out) = std::process::Command::new("sysctl").args(["-n", "hw.model"]).output() {
            let s = String::from_utf8_lossy(&out.stdout).trim().to_owned();
            if !s.is_empty() {
                return s;
            }
        }
        "Mac".to_owned()
    }
    #[cfg(target_os = "linux")]
    {
        std::fs::read_to_string("/sys/class/dmi/id/product_name").map(|s| s.trim().to_owned()).unwrap_or_else(|_| "Linux PC".to_owned())
    }
}

/// Current PC battery percentage (0-100), or -1 when this machine has no battery.
pub fn battery_percent() -> i64 {
    #[cfg(target_os = "macos")]
    {
        let out = std::process::Command::new("pmset").args(["-g", "batt"]).output();
        if let Ok(out) = out {
            let text = String::from_utf8_lossy(&out.stdout);
            // "InternalBattery-0 (id=...)\t87%; charging; ..."
            for part in text.split('\t') {
                if let Some(pct) = part.strip_suffix("%; discharging;") {
                    return pct.trim().parse().unwrap_or(-1);
                }
                if let Some((pct, _)) = part.split_once("%;") {
                    if let Ok(v) = pct.trim().parse::<i64>() {
                        return v;
                    }
                }
            }
        }
        -1
    }
    #[cfg(target_os = "linux")]
    {
        let mut best = -1;
        if let Ok(entries) = std::fs::read_dir("/sys/class/power_supply") {
            for e in entries.flatten() {
                let p = e.path();
                if std::fs::read_to_string(p.join("type")).ok().is_some_and(|t| t.trim() == "Battery")
                    && let Ok(c) = std::fs::read_to_string(p.join("capacity"))
                    && let Ok(v) = c.trim().parse::<i64>()
                {
                    best = best.max(v);
                }
            }
        }
        best
    }
}

fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."))
}

/// Whether this build runs on macOS.
pub const IS_MACOS: bool = cfg!(target_os = "macos");
