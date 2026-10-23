//! Native helper supervision on macOS.
//!
//! The Linux peer supervises four GTK/GStreamer/Wayland helper processes. On macOS the menu-bar
//! app is started by the user (or at login) and the daemon exposes everything it needs over the
//! control socket. Mirroring, App streaming and Screen share / Mobile desktop are answered by the
//! menu-bar app's stream host (a WKWebView answerer, see `macapp/SmartConnectApp.swift`), so the
//! corresponding tiles (services 1 and 15) are advertised by default — the Screen share flow is
//! verified end-to-end on a device (video + input; the answer keeps the phone's offer untouched
//! and mDNS ICE candidates are rewritten to their real LAN address, see
//! docs/protocol/mirroring.md). Webcam (3), cross control (26) and phone-as-display helpers are
//! not part of this port yet, so those tiles stay hidden unless the user opts in with
//! --extra-tiles or --all-tiles.
//!
//! This module keeps the same surface as the Linux supervisor so `main.rs` stays shared.

use std::sync::Arc;

use tracing::info;

use crate::server::Daemon;

#[derive(Default)]
pub struct Helpers {
    _private: (),
}

impl Helpers {
    pub fn enabled() -> bool {
        true
    }

    pub fn start(self: &Arc<Self>, _daemon: Arc<Daemon>) {
        info!("helpers: macOS backend (no external stream/display helpers in this release)");
    }

    pub async fn shutdown(&self) {}
}
