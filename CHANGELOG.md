# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The README's
[feature matrix](README.md#feature-status) shows what is verified on a real phone.

## [Unreleased]

### Added

- macOS app: **update checks against the project's GitHub releases** — Settings ✓ *Updates* shows the copy you run, the latest release from GitHub's `releases/latest` (so drafts and pre-releases never count) and a **Check for Updates** button reporting "up to date" (with when it was checked), a newer tag (name, publication date, *View release* opens the release page in the browser) or why the check failed (offline, rate-limited, no release published yet). A silent launch check runs a few seconds after start and posts a one-time *"SmartConnect vX is available"* notification for a tag not announced before (remembered in defaults, so the same version never nags twice); its click opens the release page rather than anything on the phone. Version comparison is numeric per dot-part with missing parts 0 (`0.10.0` > `0.9.0`, `v0.1.0-beta` equals `0.1.0`).
- macOS app: **Download and Install** — the same Updates page updates in place. The release's disk image (first `.dmg` asset, byte count checked against what the release advertises) is downloaded with progress and a **Cancel**, then handed to `update.sh` in the state folder: it waits for the running copy to exit, mounts the image read-only, `ditto`s the new bundle beside the old one, swaps it, strips the download's quarantine and starts the new version, then logs `installed <ver>` to `update.log`. Where the folder the app lives in isn't writable by this user, the identical script runs through one administrator prompt (its uid argument puts the new copy back in the login session, not as root). Failures the window can no longer show are pushed as a notification, and the relaunch button is kept for a release without an image (`View release`). Settings and pairing state live in the state folder and survive; `--self-test-update` builds a disk image of the copy running and offers it, so the whole path can be exercised without publishing a release.
- macOS app: the **Streams app grid gets the phone-picker's sections** — Games, TV apps and Apps.
  The svc 17 app list carries no category (only `pkg, name, userId, cmp, iconName`), so apps are
  matched client-side: common game studios and game words (puzzle/quiz/brain/sudoku…) land in
  Games, the video-streaming set (Netflix, Prime Video, Google TV, JioHotstar, Stremio…) and
  anything with "tv" in the name land in TV apps, and the rest stay Apps — flat and header-free
  when no game or TV app is installed. The Menu Streams and Apps from the phone sections show
  the same sections, both places. A specific app you can't find is still one search away (the
  search covers the whole list); classification flags can be shared on request.
- macOS app: **tablet-sized app streams** — the stream host sends `cmd 1` with
  `supportCustomDisplay: true` and a landscape 1600×900 display at 160 dpi, so the phone launches
  each streamed app on a wide "tablet" virtual display instead of its own portrait screen shape
  (portrait apps used to stream as a tall 610×1356 phone window no matter what bound `cmd 1`
  advertised). The stream window follows the landscape video aspect; already-open streams keep
  their display, Screen share keeps its mirror geometry. Setting: *Settings → Experimental →
  Stream apps in* — **Landscape (tablet size)** (default) or **Portrait (phone shape)**, the
  old behaviour; portrait is there for apps that misrender on the wide display. The phone's use
  of the custom-display fields is documented
  (docs/protocol/app-streaming.md) from phone-app reading — not yet verified on a device.
- macOS app: **Copy OTP on notifications** — when a message (or any app) notification carries a
  one-time code (`OTPFinder`: keyword within 40 chars of a 4-8 digit group, or a bare code), the
  system banner gains a **Copy OTP** action as its first button; tapping it copies the code to the
  Mac's pasteboard locally (the notification is not opened on the phone or marked handled) and a
  short "OTP copied" banner confirms it. The notifications rows in the menu panel and the
  Notifications page show the same Copy OTP pill (code beside it, ✓ Copied feedback) next to
  Reply/Open, matching the existing Messages-page copy pill.
- macOS app: a **menu-bar call pill** while the phone is ringing or in a call — a status-bar item
  (red Incoming / green phone glyph with a live timer, iOS's in-call pill) whose popover carries
  the caller's avatar, name, the dialer's detail line (caller ID) and a running timer, plus
  Mute (mutes the Mac's default input — real mic mute for Bluetooth-HFP-routed calls), Speaker
  (pushes the Mac's default output volume to max while on, restoring the previous level), and
  End (Decline/Accept while ringing). The floating call card also **replaces the plain system
  banner for calls**: the ringing card (avatar, name, Silence link, red Decline + green Accept
  circles) shows as a floating always-on-top card that morphs into the ongoing bar (live timer,
  red End circle), and call notifications skip the UN banner entirely.
- macOS app: call notifications are presented **iPhone-calling style** — round caller photo
  avatar (from the daemon's saved `person_icon`; launcher icon / person glyph as fallback), caller
  name and an Incoming call / Ongoing call status line, the round red Decline + green Accept
  phone circles (with a Silence link), and a single red End circle once the call is picked up —
  in the Notifications rows, the menu panel header and the Phone page (ringing card switches to
  ongoing automatically from Android's notification reshape).
- macOS app: `svc 15 cmd 21 audioAppList` (the phone-audio feature: "apps playing audio") is logged
  as it arrives. Phone→PC audio cannot be implemented from this side yet: the requesting handshake
  and the audio channel were never captured (the mirror track is video-only), and Android blocks
  apps from grabbing telephony audio — call audio rides Bluetooth HFP (pair the phone with the Mac),
  the way Windows' own Phone Link does it. (docs/usage.md → Audio ⋅ Phone audio on the PC.)
- macOS app: **call notifications** show Accept / Decline / Silence pills in the notifications list
  and the same labelled buttons on the macOS banner; there is no Open for a call and banner taps do
  nothing, so the dialer is never streamed for a call. Once the call is picked up (Android reshapes
  the same notification: Answer gone, Hang-up only) the row switches to an ongoing-call indicator,
  and the menu panel header and the Phone page show a green ongoing tile with an **End** button;
  it clears when the call ends. Supporting this, notification action clicks are answered
  headlessly: the daemon announces each click on the watch stream (svc -1) before forwarding it, and
  the app answers the phone's app-stream invite with no window and releases the stream after the
  intent fires (Linux host parity, `.notes/notification-background-actions.md`). (🟡 built; the
  ringing/pill/headless flow is not yet verified on a device.)
- macOS app: the phone's apps show as a **grid of icons** instead of a row list — on the window's
  Streams page (40 pt launcher icons, two-line names, package in the hover tooltip) and in the
  menu-bar panel's Streams card (30 pt icons, one-line names). Clicking an icon starts the app on
  the phone directly via service 15 `cmd 1`; the old per-row *Open* button and package caption are
  gone. Search still filters the grid and work-profile entries keep their "· work" suffix.

- macOS app: clicking a notification whose app also lives on the Mac (WhatsApp, Telegram, Discord,
  Spotify, Slack, Teams, Outlook, Zoom, Instagram — or any app whose name matches an installed
  `/Applications/<name>.app`) opens the local Mac app instead of streaming the phone's copy; the
  banner's action button is relabelled *Open on Mac* for those. While the Mac app is running, the
  phone's mirrored notifications for it are suppressed entirely (no banner, nothing in the list —
  the desktop app already shows its own); quitting it resumes the mirroring. (OBSERVED: WhatsApp
  `net.whatsapp.WhatsApp` installed and resolved both via the package map and name lookup; full
  click flow pending a live notification.)
- macOS app: the phone's app list is cached (`~/Library/Caches/SmartConnect/apps-cache.json`,
  written on every fresh service 17 `cmd 1`) and is shown instantly at launch and whenever a
  Streams surface opens — the panel no longer needs a manual Refresh before anything shows. Each
  surface also auto-requests a fresh list at most every 5 minutes while the phone is connected
  (plus the manual Refresh button), and the fresh answer replaces the cache silently. Verified:
  193 apps pooled into the cache; a relaunch logs "showing 193 cached apps before the fresh list
  arrives" (OBSERVED).
- macOS app: the Notifications page (window and menu-bar panel) keeps older notifications instead
  of rotating them out — the bridge stores up to 200 and the merged list shows up to 300, still
  de-duplicated by key. Notifications the user acted on (Open on phone, a Reply, an action button
  or the macOS banner itself) and ones dismissed on the phone (their remove event arrives over the
  bridge) move into a separate **Earlier** section: dimmed, with an envelope-open marker and a
  per-row clear button; a **Clear handled** button drops the whole section. A repeated key with
  changed content counts as new again. (🟡 built and installed; on-device check of the flow pending.)
- macOS app: a **Messages** page (the Windows app's Messages) in the main window's rail, plus a
  compact Messages card in the menu-bar panel (icon picker now has four segments: Phone, Streams,
  Messages, Notifications). The daemon
  already folds the phone's flat SMS beans into `sms_state`; the page lists conversations (name from
  `cmd 2` contacts when known, last message, unread counts), shows one conversation with received/
  sent bubbles and timestamps, opens (and marks read) a conversation with a tap, re-syncs the phone
  every 5 s while connected, and composes SMS through `sms_send` (the phone acks with `cmd 5`,
  then `cmd 6`). The first sync sends `cmd 18` (PC ready), which enables Messages for this PC on the
  phone. MMS bodies are shown; media parts aren't yet. One-time codes in a message are detected
  (keyword `otp/passcode/password/pin/code` within 40 characters of the digits, or a bare
  4-8 digit body) and copyable: the newest received code shows a **Copy code** banner above the
  conversation (window and panel card), and the message row itself gets a small code chip that
  turns into a green "Copied" checkmark. URLs in a message body render as proper hyperlinks (blue,
  underlined) and open in the default browser on click — `mailto:` links included; sent bubbles
  keep white underlined links since their background is blue. (🟡 built and verified against the
  control socket; an on-device check of threads, sending and the "allow Messages" prompt is
  pending.)
- macOS app: the main window models the Windows app's layout: a dummy Motorola Edge 70 with the
  phone's real wallpaper (service 25 `cmd 2`, saved by the daemon under the runtime dir), a live
  clock, status bar (time, Wi-Fi, battery and charging bit), unread count, punch-hole camera and
  home bar sits at the top of a narrow left rail, and the feature pages (*Phone*, *Streams*,
  *Notifications*, *Settings*) list under it as in Phone Link, each filling the right side.
  Placeholder text fills the screen while the phone is disconnected. The menu-bar panel keeps its
  own Phone/Streams/Notifications sections.
  (🟡 built and installed; wallpaper rendering observed on the wire via the daemon's
  "phone wallpaper saved" log and the published status, full on-screen check still pending the
  phone being reachable.)
- macOS app: the menu-bar panel is redesigned — status header (connection ring, device name and
  model, battery capsule), a segmented Phone/Streams/Notifications picker with icons, each section
  in a rounded card (prominent Connect/Disconnect, bordered stream start buttons, the existing
  streams and notifications list), and a plain-text Open/Quit footer. Panel width 360.
- macOS app: the **Streams tab is merged into the Phone page** — the mirror tiles (Screen share /
  Mobile desktop), running streams and the phone's app grid now sit on the Phone page below the
  connection info, and the window's rail keeps *Phone, Notifications, Messages, Settings*; the
  menu-bar panel picks Phone as the streaming section too (its picker has three segments) and
  carries the Screen share / Desktop / Refresh row, running streams and the app grid. App icons
  and the search stay as on the old Streams page.
- macOS app: the Phone page's footer captions ("PC address…" and "Pairing QR is served…") are
  gone — the PC's IP is an info tile in the status row (next to Battery / Wi-Fi / Bluetooth),
  and *Mirror screen* / *Mobile desktop* carry the same icons as the panel's buttons.
- macOS app: the Phone page's Streams section drops its headings (*Streams*, *Apps from the
  phone*, *Running streams*) — the running-stream rows and the app grid follow the connection
  info directly, with Refresh on the same row as the search field.

### Fixed

- macOS app: **Settings ✓ *Show SmartConnect in the Dock*** now remembers the choice. The toggle bound `_showInDock.projectedValue`, which writes only the SwiftUI `State` — its own setter (the one that called `UserDefaults`) was never reached, so the Dock tile appeared until the next launch and every launch went back to menu-bar-only. The value is now saved as the toggle changes, and launch-time activation already reads it, so the Dock preference survives a restart.
- macOS: the phone's **PC lock** tile verifies end to end on this OS (`SACLockScreenImmediate`
  locks the screen). The daemon previously watched the unlock by polling the session dictionary,
  whose lock key no longer appears on current macOS — the phone's tile would have stayed "locked"
  forever. The helper gains a `session-locked-wait` mode streaming the
  `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` distributed notifications, and
  `pc_lock.rs` reports state 0 as soon as it sees an unlock (OBSERVED: lock event on
  `lock-screen`, unlock event on release).
- macOS stream host: the heartbeat no longer stalls the app. It ran as `Task { while true { try? await
  Task.sleep(30 s); send("cmd 9") } }`; `try?` swallowed a cancelled re-sleep so a missed beat
  never returned, and every status publish re-created Task rows, wedging send/receive. The beat is
  now a `DispatchSourceTimer` on the main queue, and the beats are visible on the wire in the
  `sessions/*.jsonl` dumps (~30 s apart, OBSERVED).
- daemon: every WebSocket write to the phone (data and ping) is bounded by a 5 s send timeout; a
  phone that stops reading no longer wedges the relay loop (warn + drop the link, the phone
  self-recovers by reconnecting).
- macOS app: socket writes to the daemon report failure (`UnixSocket.writeLine` returns `Bool`,
  EINTR-safe, `SO_NOSIGPIPE`), a stalled write is logged with its errno and triggers a stream-host
  reconnect instead of hanging the sender, and the drain read tolerates timeout.
- macOS app-stream windows keep the app's own aspect: the page posts `{kind:"videosize"}` on
  `loadedmetadata`/`resize` (apps deliver a portrait 610x1356 surface even though service 1 `cmd 1`
  still passes the 1920x1080 bound, OBSERVED), and the window refits with a 2% aspect slack and a
  height clamp (`avail.height - 90`, top edge fixed); the initial `openSession` frame is clamped
  the same way.
- macOS stream host: the phone's service 15 frames wrap their payload in a nested `data` object
  (`{"ver", "cmd", "data": {…}}`, the mirror of what the PC sends); the app now unwraps that
  envelope before reading `pkg`, `sessionId`, `webRTCData` and friends. Before, the WebRTC offers
  (`cmd 3`) were silently dropped — the phone never got the PC's `cmd 4` answer, stayed on
  "connecting", re-invited, and eventually ended pending starts with `cmd 8 state 0 reason 3859`
  ("unable to start activity, try closing some apps" = no encoder available). Verified on a device
  (motorola edge 70): Screen share streams video into the menu-bar app's window and mouse, wheel
  and keyboard control it.
- macOS stream host: the WebRTC answer now forwards the phone's offer untouched. The first port
  filtered the offer to H.264 like the Linux mirror does, which made WebKit answer with a rejected
  media section (`m=video 0 … 0`, empty codec list) — sessions "connected", created a display,
  but no video ever flowed and the window stayed black; the SDP harness in the app showed the
  unfiltered offer answering with a live `m=video 9` section. The phone still encodes H.264.
  WKWebView also gathers its local host candidates as mDNS `.local` names the phone cannot use;
  the host resolves the name through the system's Bonjour resolver (first lookups can take
  seconds) and relays the candidate with the real LAN address instead. With both fixes ICE reaches
  `connected` within ~200 ms of the answer.
- macOS stream host: the embedded stream page is served over `http://127.0.0.1` again. The page
  server's `bind()` used `INADDR_LOOPBACK` as imported into Swift, which is byte-swapped and fails
  with errno 49 (`Can't assign requested address`) — since then every window silently fell back to
  `loadHTMLString`, a non-HTTP origin. WebKit grants `RTCPeerConnection` on either origin on this
  macOS (verified outside the app), so both paths stream; the loopback origin is preferred again.
- Reconnect with Smart Connect in the background on the phone is reliable: Connect attempts no longer run concurrently (the GTK button during the auto-reconnect loop used to make BlueZ fail with "operation already in progress"); a Bluetooth LE connect that times out is cancelled and the phone rescanned (its address can go stale); scans last 30 s instead of 20 s; and a desktop Connect that fails keeps retrying in the background. Verified: CLI Connect in 5 to 6 s and daemon restart in about 16 s, app in the background.
- A session whose phone went silent (left Wi-Fi, or this PC slept) is dropped after 70 s and reconnected, instead of looking connected until the kernel gave up on the socket.
- Invites follow the PC's current LAN addresses after a network change instead of the ones read at startup (unless `--ip` is given).
- Phone files: a stale mount no longer looks mounted. When the `smartconnect-files mount` helper died (for example after a daemon restart, when the phone's per-session NFS ports changed), it left a FUSE mount behind ("Transport endpoint is not connected") that `mountpoint` still reported as mounted, so the Noctalia tile showed *Unmount files* and **Open** silently did nothing. Now:
  - `smartconnect-files mount` **survives a phone reconnect or a daemon restart**: on a lost connection files calls fail fast with an I/O error, and once the phone is back it redoes the handshake and carries on (file handles from the old session are re-resolved). It unmounts only after 10 minutes without the phone or when the phone is unpaired. SIGINT/SIGTERM/SIGHUP unmount cleanly (lazily if busy), and a stale mount at the folder is cleared before mounting.
  - The GTK *Files* page and the Noctalia *Phone files* tile check that the mount is alive (`statfs` and a listing, with timeouts), not just that the folder is a mount point. They clear a stale mount, remount it (on **Open**, or with auto-mount), and say when the phone is offline or the folder couldn't be opened instead of failing silently. The panel also adopts a live mount it didn't start.
- Notifications: WhatsApp (and other messaging-app) notifications no longer show your own profile picture. The phone's `person_icon` for a chat is the phone owner, not the sender; it is now used only when it is the headline person, and otherwise the app icon is shown (the phone's launcher icon from the app-icon cache when present, then a themed icon, then the phone's glyph).
- Webcam: switching between the front and back camera on the phone no longer stops the webcam. The phone re-sends its unchanged offer after a switch; the helper now keeps the running session instead of answering it again.
- Noctalia plugin: the panel reconnects after the daemon restarts instead of staying on "smartconnectd is not running" (a fresh Quickshell socket per attempt).
- Noctalia panel layout: compact phone header, 2×2 action tiles with readable option chips (Cross Control edge, display mode and scale), and a panel height that follows its content.

### Changed

- macOS app: **a notification that carries a one-time code copies it by itself** — its banner is now sensitive and never shows the code (the digits render as bullets), the code is read from the phone's *Messages* (the conversation behind the sender, else the one whose last message carries that very code, else the notification's own text) and put on the Mac's pasteboard as the notification arrives, and a short **OTP copied** notice confirms it without repeating the digits. The banner keeps **Copy OTP** as a fallback, which takes the code from `userInfo` rather than the screen and whose own confirmation no longer prints it either. `OTPFinder` grew `masked(_:)` for the bullets; the matching rules are unchanged.
- macOS app: SMS conversations in the sidebar previews show up to **two lines** of the latest message instead of one clipped line (`lineLimit(2)` on both thread lists), so a code or a sentence is readable at a glance.
- GTK app: the window was restructured to a shared design. A header **device menu** (left of the title) shows the connected device and holds *Pair new phone…*, *Preferences* (the *Start at login* switch) and *Connect/Disconnect* — moved out of the pages. The view switcher now has five pages: *Phone* (a compact phone card with wallpaper, name, an inline battery/Wi-Fi/mobile/Bluetooth row and **Mirror screen**, an unread-messages shortcut to Notifications, and the Cross Control switch), *Apps* (search + Recent chips + an icon grid), *Display* (a phone-as-display card over Layout / Experimental / Advanced groups), *Files* (a storage card with a *Read-only* badge, **Open in Files**, quick-folder shortcuts, and a *Mount automatically when connected* switch) and *Notifications* (grouped under *Today* with **Clear all** and a per-notification **⋯** menu for *Open on phone* / *Dismiss* / *Mute app*). Pairing is now a dialog opened from the device menu. All controls follow the system light/dark theme and accent colour. No change to the control-socket wiring, mirror/app-streaming, display sessions, mount lifecycle, tray or autostart behaviour.

### Added

- The phone's device page now also shows a **Clipboard sync** tile: on macOS the daemon lists service 9 in its service 25 `cap` map next to PC lock and Hotspot. Clipboard sync needs no tile tap — text sync is negotiated on every connection as before. Whether the phone draws a tile for service 9 this way is not verified on a device yet.
- The phone's device page now also shows the **App streaming** and **Screen share / Mobile desktop**
  tiles on macOS by default: the daemon advertises services 15 and 1 in the service 25 `cap` map,
  and the menu-bar app answers the invites (see the next bullet for the stream host) — the Screen
  share flow is verified on a device now.
- Stream host on macOS: the menu-bar app implements the `smartconnect-mirror --host` control plane
  (services 1 session control, 15 stream setup and 16 input) natively. An invite from the phone —
  App streaming tile, Screen share / Mobile desktop tiles — opens a window whose WKWebView answers
  the phone's WebRTC offer and plays the stream; mouse, wheel and keyboard input are forwarded as
  service 16 commands (virtual keyboard + mouse requested per display, Esc→BACK / Ctrl+Alt+H,R,B
  phone shortcuts included). Heartbeat `cmd 9` every 30 s, ICE candidates filtered to the daemon's
  `pcAddress` (or `SMARTCONNECT_ICE_ADDRESSES`), and a persisted `smartconnect-mirror.instance`
  keep the phone's session rules. Verified on a device with the Screen share tile (see the
  envelope/answer bullets above).
  A `--webrtc-sdp-harness` test window runs any new offer through SDP-plan variants (filtered /
  transceiver / unfiltered / self-offer) and reports answer `m=` sections, ICE states and
  candidates, for when the phone's offer shape changes again.
- macOS menu-bar app *Streams* tab: the same fronts the Linux GTK app has for streaming —
  **Mirror screen** and **Mobile desktop** buttons (service 1 `cmd 1` with `reply: 0` + peer start
  data, `source: 0`), the phone's app list (service 17, cached icons from
  `~/Library/Caches/SmartConnect/app-icons`, search, **Refresh**, **Open** → service 15 `cmd 1`
  with the app's `pkg`/`cmp`/`userId`), and the running streams with Close buttons (`cmd 7`, which
  releases each virtual display). Streams the phone started (tile taps) appear in the same list.
  Sessions are dropped automatically when the phone disconnects. Same-device verification is
  limited to Screen share so far; the app list and PC-side starts follow it.
- `smartconnectd --all-tiles` (and an *Advertise every phone feature tile* switch in the macOS app's Settings): advertise every feature tile the phone can draw — Screen share, Mobile desktop, Webcam, Clipboard sync, App streaming, Cross Control, PC lock and Hotspot — not only the ones this release implements. Taps of unimplemented features wait about 20 s on the phone and time out. Default on macOS is PC lock + Hotspot + Clipboard sync + App streaming + Screen share/Mobile desktop; on Linux, PC lock + Hotspot.
- Reconnect triggers: the daemon retries at once when the phone answers on Wi-Fi again (a TCP probe every 30 s, no Bluetooth), after a resume from suspend, when the PC gains a LAN address, and when the PC's Bluetooth is switched on. While the phone is on the LAN the retry interval stays at a minute. Clearer messages when a backgrounded phone can't be reached (`Bluetooth is off`, `--no-ble-wake`).
- `smartconnectd --no-ble-wake`: never use Bluetooth LE to wake the phone (the wake never changes the adapter's power either way).
- App icons from the phone: on every connection `smartconnectd` now downloads the icons the phone offers with its app list (service 17) over the phone's "fex" file-transfer server and writes them to `~/.cache/smartconnect-linux/app-icons/`, named as the phone's `iconName` (atomic writes; unchanged icons are not rewritten). Completing the download also makes the phone send its recent-apps list. Turn it off with `SMARTCONNECT_APP_ICONS=0`.
- `smartconnect-fex`, a new helper: `fetch-app-icons [--out DIR]` asks the phone for its app list and downloads the icons now; `pull --host --port --fingerprint` pulls any fex offer. The reusable client (`fex/`) is what clipboard images will use.
- Control socket: `status` now includes `phoneAddress`, the connected phone's IP address.
- GTK app: real phone app icons on the *Apps* page, Recent chips, running streams and notification rows, read from `~/.cache/smartconnect-linux/app-icons/` (the phone's `iconName`, then `<pkg>.png`). `smartconnect-mirror` now saves the icon the phone sends with a stream invite or focus change (svc 15 `cmd 2` / `cmd 13`) there, and `--list-apps --json` keeps each app's `iconName`/`userId`. Without a cached icon the app uses a desktop icon only on an exact match, else the app's initials — no more generic placeholder glyph or wrong look-alike icons. New icons appear without a restart.
- GTK app: the Phone page and device menu remember the last connected phone (name, model, wallpaper, last-known battery/signal, when it was last connected) in `~/.local/state/smartconnect-linux/last-device.json`, and show it while the phone is away, while the service is stopped, and after an app restart. Disconnected: a **Connect** button with a *Connecting…* spinner and a clear failure toast with the daemon's reason; no phone paired: **Pair a phone**; service not running: a *Smart Connect service isn't running* page with the last phone and **Start service** (also in the device menu).
- GTK app: a system-tray icon (StatusNotifierItem) that reflects the connection state, with a menu to show/hide the window, Connect, Disconnect and Quit. Closing the window now hides it to the tray instead of quitting.
- GTK app: opening it starts `smartconnectd` if it isn't running (the `systemctl --user` unit if installed, otherwise as a child process), showing a *Starting…* state until the control socket answers; Quit stops the daemon it manages.
- GTK app: a *Start at login* switch that adds or removes the XDG autostart entry, and a `smartconnect-gui --background` flag that starts the app hidden to the tray.
- GTK app: a *Files* page that mounts the phone's storage (via `smartconnect-files`) as a read-only folder — **Mount**, then **Open in Files** / **Unmount** — with a configurable mount folder (default `~/Phone`, saved in `gui.json`) and errors surfaced in a banner. The Mount button is disabled until the phone is connected; closing the window to the tray keeps the mount, and Quit unmounts it so no stale FUSE mount is left behind.
- Noctalia plugin: a *Phone files* action tile in the panel that mounts the phone's storage (via `smartconnect-files`) as a read-only folder — tap to **Mount** (default `~/Phone`), an option chip shows *Mounting…* then a clickable **Open** once mounted, and the tile becomes **Unmount**. Available only while the phone is connected (or a mount is live, so it can still be unmounted); a fast exit (phone not connected / handshake failed) falls back to unmounted and shows the helper's error in the status line. The mount folder and helper path are configurable in the plugin settings. The mount persists when the panel closes; a stale mount left by a shell exit is cleared the next time the panel opens.
- Webcam quality presets (`--quality low|medium|high|max`, or `quality` in `~/.config/smartconnect-linux/webcam.json`): the bitrate the phone may encode at.
- Protocol docs: [docs/protocol/file-exchange.md](docs/protocol/file-exchange.md) covers fex file transfer (service 2), File Station NFSv3 (service 168) and Share Hub (service 30); the clipboard protocol page adds the image/file clip control plane.
- Browse the phone's files: `smartconnect-files mount --mountpoint DIR` presents the phone's storage as a read-only FUSE filesystem, using the phone's own File Station protocol (NFSv3 over fingerprint-pinned mutual TLS, no root/adb). It handshakes with the phone through the daemon. Verified on a device. Needs `fuse3`.
- Share a PC folder to the phone: `smartconnect-files serve [--sharedir DIR]` exports a local folder (default `~/PhoneShare`) **read-only** as an NFSv3 server over the same fingerprint-pinned mutual TLS, so the connected phone can mount and browse it (the mirror of the mount above). It answers the phone's `cmd=1001` File Station handshake over the daemon control socket, forcing SSL transport (`dt2type:2`). The full server + mutual-TLS + NFS path is covered by loopback tests; **live-phone validation is pending** (see [file-exchange.md](docs/protocol/file-exchange.md)).
- Clipboard: the daemon now recognises an incoming image/file clip from the phone (and logs it) instead of treating it as unknown; the bytes are not fetched yet (the fex client is not wired to clipboard clips), and it never mistakenly PULLs.
- `smartconnectd` daemon: the unmodified Motorola Smart Connect app sees this Linux PC as a Windows PC.
- QR pairing (`smartconnectd pair`, the GTK app's pairing dialog, the Noctalia QR button), including the key exchange that lists the PC in the phone's device list.
- Reconnect without a QR over Wi-Fi (mDNS via avahi): the phone's Connect button, and the daemon dialing the phone back.
- Bluetooth LE wake: a desktop-side Connect reaches the phone even with Smart Connect in the background.
- Persistent auto-reconnect with backoff; a Disconnect from the phone or the desktop is respected.
- Clipboard text sync in both directions through wl-clipboard; password-manager copies are never sent.
- Phone notifications as desktop notifications, updated and closed together with the phone.
- Quick reply to phone notifications from a reply window, the GTK app or the Noctalia panel.
- Multi-line chat notifications showing recent messages and, in group chats, their senders.
- Notification dedupe and coalescing of rapid updates.
- Themed desktop icons for phone notifications.
- Notification action buttons run on the phone through a short, windowless app-streaming session (`SMARTCONNECT_BACKGROUND_ACTIONS=0` opens a window instead); clicking a notification opens the app in a window (not verified on a device).
- Per-app notification mute: a toggle on each notification and a *Muted apps* list in the GTK app and the Noctalia plugin, and the `notif_mute` control command.
- Phone status for front-ends: battery, charging, signal, Bluetooth, unread count and wallpaper.
- SMS backend with the `sms_threads`, `sms_thread`, `sms_send`, `sms_mark_read` and `sms_state` control commands (not verified on a device).
- Control socket `$XDG_RUNTIME_DIR/smartconnectd.sock` with `status`, `subscribe`, `connect`, `disconnect`, `pair`, `watch`, `send`, `reply` and `notif_mute`, plus the matching CLI subcommands.
- The status object carries `pcAddress` (the address the phone reached this PC on) and each notification's `pkg`.
- `watch` can stream the daemon's local events (service id `-1`); the first one is `notification_action`.
- Feature tiles for this PC on the phone: App streaming, Cross Control, PC lock, Hotspot and Webcam.
- `--extra-tiles` to advertise more tiles; `--extra-tiles 1` adds Screen share and Mobile desktop, answered by the stream host (experimental).
- PC lock tile, which locks the session through logind.
- Hotspot tile: the phone starts a hotspot with PC-chosen credentials and the PC joins it through NetworkManager (not verified on a device).
- `smartconnect-mirror`: phone screen mirroring over WebRTC (H.264, VA-API or software decoding) with mouse input.
- Keyboard input, phone keys (Esc = Back, Ctrl+Alt+H = Home, Ctrl+Alt+R = Recents) and scrolling in the mirror window.
- App streaming: phone apps in their own windows (`--host`, `--app`, `--list-apps`, `--sessions`, `--close`), including apps picked from the phone's App streaming tile.
- Opt-in app window resize: the phone resizes an app's virtual display to its window (`SMARTCONNECT_MIRROR_RESIZE=1` or `--host --resize`).
- `smartconnect-mirror --desktop` and the stream host's `desktop` command ask the phone for Ready For's Mobile desktop (experimental).
- The video helpers offer the phone WebRTC candidates only on the address it reached the daemon on (`pcAddress`), on any private network; `SMARTCONNECT_ICE_ADDRESSES` overrides it.
- `smartconnect-crosscontrol`: Cross Control on Wayland, moving the PC's mouse and keyboard onto the phone across a screen edge (`--edge`, `--output`, `--gain`, `--exit-px`; Ctrl+Alt+Esc returns).
- Cross Control can be started from the phone's tile; the daemon starts the client on demand.
- The daemon supervises the stream host, and starts Cross Control, the phone display and the webcam helper when the phone asks for them (`SMARTCONNECT_HELPERS`, `SMARTCONNECT_CROSS_EDGE`).
- Programs find each other through `SMARTCONNECT_<NAME>_BIN` (`SMARTCONNECT_MIRROR_BIN`, `SMARTCONNECT_CROSSCONTROL_BIN`, `SMARTCONNECT_DISPLAY_BIN`, `SMARTCONNECT_WEBCAM_BIN`, and for the GTK app also `SMARTCONNECT_FILES_BIN` and `SMARTCONNECT_SMARTCONNECTD_BIN`), then next to the running program, then on `PATH`.
- `smartconnect-gui`: GTK4/libadwaita app with Phone, Apps, Display, Files and Notifications pages, a pairing dialog, a mirror button and a Cross Control switch.
- Noctalia Shell plugin: bar pill, control-center button, panel, settings, and the IPC target `plugin:smart-connect` (`toggle`, `connect`, `disconnect`, `mirror`, `display …`).
- `smartconnect-display`: the phone as an external display, either extending the desktop onto a `vkms` virtual output (`--mode extend`, `--size native`, `--output`) or duplicating the focused screen.
- `--display-scale` for the phone's monitor in Extend, 200 % by default.
- Touch input from the phone display is injected on the PC: tap, drag, long-press for right click, two-finger scroll.
- The keyboard button on the phone display shows an on-screen keyboard on the shared screen (`wvkbd` or `SMARTCONNECT_OSK`), sized with `--osk-height`.
- Phone display controls in the GTK app (*Display* page) and the Noctalia plugin (panel button, settings, `display` IPC), sharing `~/.config/smartconnect-linux/display.json` with the helper (not yet verified with a phone).
- The phone display can be started from the phone; the daemon starts `smartconnect-display` and tells the phone to stop waiting if it fails (not verified on a device).
- One phone display session at a time, with `--replace` to take over.
- Opt-in `--follow-rotation`: the extended monitor turns portrait with the phone (not verified on a device).
- Opt-in `--audio`: the PC's sound plays on the phone display, muted from the phone's audio switch (not verified on a device).
- Webcam tile and the `smartconnect-webcam` helper: the phone camera as a Linux webcam through v4l2loopback or a PipeWire camera node (verified with a phone, including the front/back camera switch).
- One Cargo workspace for all eight programs, `packaging/install.sh` (installs everything, including the systemd user unit, the GTK app's launcher and icon and the Noctalia plugin; checks the build libraries with pkg-config first) and `packaging/uninstall.sh`, plus an Arch `PKGBUILD` for a local checkout (it turns off makepkg's `lto` option, which breaks the link).
- Documentation: README with feature matrix, *Notification actions* and *Known issues* (one phone at a time, no file/image clipboard yet), `docs/` (installation, usage, troubleshooting, architecture, control socket API, development, security), `docs/protocol/`, and a [TODO.md](TODO.md) backlog.

### Security

- Session logs are opt-in (`smartconnectd --session-log`) and redact keys, tokens, passwords, clipboard text, SMS and notification contents and the wallpaper.
- The state directory is created with mode 0700; `key.pem`, `paired.json`, `identity.json`, `phone-endpoints.json`, `pairing-qr.svg` and session logs are 0600.
- The Hotspot password is kept out of the daemon log and `nmcli` error messages.
