//! Desktop-side Connect over Bluetooth LE on macOS.
//!
//! The phone always advertises service 0x5246 with 20 bytes of service data (4-byte header + its
//! 16-byte salted nonce id). A macOS central can read that service data, connect, discover
//! characteristics 0x0722/0x0726 and write the same AES-GCM-sealed `cmd:1` invite the Windows PC
//! writes. `smartconnect-mac-helper ble-wake` does the CoreBluetooth part; this module supplies
//! the sealed frame and watches the daemon for the phone dialing back over Wi-Fi.

use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use base64::Engine;
use base64::engine::general_purpose::STANDARD as B64;
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio::time::{Instant, timeout};
use tracing::{debug, info, warn};

use crate::discovery;
use crate::server::Daemon;

const HELP_TIMEOUT: Duration = Duration::from_secs(45);

/// Finds the paired phone by its BLE advert and writes our invite to it. Returns a status message.
pub async fn connect(daemon: &Daemon) -> Result<String> {
    let (key, ids) = {
        let pairing = daemon.pairing.lock().unwrap();
        let Some((_, phone)) = pairing.iter().next() else {
            bail!("no paired phone");
        };
        let ids: Vec<String> = pairing.iter().map(|(id, _)| id.clone()).collect();
        (phone.key.clone(), ids)
    };
    let frame = discovery::sealed_invite(daemon, &key)?;
    let helper = crate::platform::helper_binary("smartconnect-mac-helper");
    if !helper.is_file() {
        bail!("smartconnect-mac-helper not found; install the app bundle or set SMARTCONNECT_HELPER_BIN");
    }
    let mut child = Command::new(&helper)
        .args(["ble-wake", "--frame", &B64.encode(&frame), "--ids", &serde_json::to_string(&ids)?])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .with_context(|| format!("starting {}", helper.display()))?;
    let mut lines = BufReader::new(child.stdout.take().context("helper stdout")?).lines();
    let deadline = Instant::now() + HELP_TIMEOUT;
    let mut wrote = false;
    while let Ok(Ok(Some(line))) = timeout(deadline.saturating_duration_since(Instant::now()), lines.next_line()).await {
        let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
        match v.get("event").and_then(Value::as_str) {
            Some("found") => info!(name = ?v.get("name"), "ble: found the paired phone; connecting"),
            Some("written") => {
                wrote = true;
                break;
            }
            Some("error") => {
                let msg = v.get("message").and_then(Value::as_str).unwrap_or("Bluetooth error");
                bail!("{msg}");
            }
            _ => debug!(%line, "ble: helper"),
        }
    }
    if !wrote {
        let _ = child.kill().await;
        bail!("phone not found over Bluetooth (advertising, in range, and Bluetooth on?)");
    }
    // The helper drops the link; give the phone a moment to dial us over Wi-Fi.
    let until = Instant::now() + Duration::from_secs(8);
    while Instant::now() < until && !daemon.is_connected() {
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    Ok(if daemon.is_connected() {
        "connected (woke the phone over Bluetooth)".into()
    } else {
        "invite sent over Bluetooth; the phone should connect in a moment".into()
    })
}

/// CoreBluetooth reports power-on changes; the helper prints one JSON line per change. A wake is
/// only attempted when the adapter is on, so nudge the reconnect loop when the user turns it on.
pub async fn watch_adapter(daemon: Arc<Daemon>) -> Result<()> {
    let helper = crate::platform::helper_binary("smartconnect-mac-helper");
    if !helper.is_file() {
        bail!("smartconnect-mac-helper not found");
    }
    let mut child = Command::new(&helper)
        .arg("ble-watch-power")
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .with_context(|| format!("starting {}", helper.display()))?;
    let mut lines = BufReader::new(child.stdout.take().context("helper stdout")?).lines();
    while let Some(line) = lines.next_line().await? {
        let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
        if v.get("event").and_then(Value::as_str) == Some("poweredOn") {
            daemon.nudge_reconnect("Bluetooth was turned on");
        }
    }
    warn!("ble: power watcher exited");
    Ok(())
}
