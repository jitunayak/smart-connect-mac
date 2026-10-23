//! BLE pairing peripheral on macOS.
//!
//! CoreBluetooth can advertise a service UUID but (unlike BlueZ) cannot put custom service data
//! in the advertisement. macOS therefore exposes the ReadyFor service 0x5246 and its GATT
//! characteristics, which is enough for a phone that connects by service UUID, but it cannot
//! reproduce the 20-byte service-data blob a Windows PC puts next to it. Because of that, the
//! QR's `bleAddress` is left empty on macOS and first-time pairing may need the phone's Smart
//! Connect app in the foreground (Wi-Fi path). Desktop-side Bluetooth *wake* works fully: the
//! phone's advert service data is readable by a macOS central (see `ble_connect_macos`).

use anyhow::{Context, Result};
use tokio::process::{Child, Command};
use tracing::{info, warn};

use crate::identity::Identity;

/// Keeps the `smartconnect-mac-helper ble-advertise` process alive for the daemon's lifetime.
pub struct BleHandles {
    _child: Child,
    /// No public adapter address on macOS; the QR carries an empty `bleAddress`.
    pub address: String,
}

pub async fn start(identity: &Identity) -> Result<BleHandles> {
    let helper = crate::platform::helper_binary("smartconnect-mac-helper");
    if !helper.is_file() {
        anyhow::bail!("smartconnect-mac-helper not found; BLE pairing disabled");
    }
    let mut child = Command::new(&helper)
        .args(["ble-advertise", "--device-id", &identity.device_id])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .with_context(|| format!("starting {}", helper.display()))?;
    // Give CoreBluetooth a moment to reject an unavailable adapter (it reports on stderr).
    tokio::time::sleep(std::time::Duration::from_millis(700)).await;
    if let Some(status) = child.try_wait()? {
        let mut err = String::new();
        if let Some(mut stderr) = child.stderr.take() {
            use tokio::io::AsyncReadExt;
            let _ = stderr.read_to_string(&mut err).await;
        }
        anyhow::bail!("BLE advertiser exited ({status}): {}", err.trim());
    }
    info!("advertising ReadyFor service 0x5246 over CoreBluetooth");
    Ok(BleHandles { _child: child, address: String::new() })
}

/// Kept for API parity with the Linux module; the macOS helper does not expose a MAC address.
pub fn warn_no_mac() {
    warn!("macOS does not expose the Bluetooth adapter address to apps; QR bleAddress is empty");
}
