//! Phone notifications → the native macOS menu-bar app (and an `osascript` fallback).
//!
//! The wire protocol is described in `docs/protocol/notifications.md`. The phone pushes every
//! notification on svc 5 (apps on its show-list) or svc 37 (others) with no handshake:
//! `{version, key, event: 0 posted | 1 updated | 2 removed, type, actions[], data{…}}`.
//!
//! On macOS the daemon does not implement the freedesktop notification bus. Instead it forwards
//! each notification as one JSON line over a Unix socket to `SmartConnect.app`
//! (`$TMPDIR/smartconnect/notifications.sock`), which shows it through
//! `UNUserNotificationCenter`. Clicking the banner, an action button, or replying from the inline
//! text field goes back through the daemon's control socket (`reply` / `send`).
//!
//! When the app is not running, a plain `osascript display notification` fallback is used so the
//! user still sees that something arrived. The fallback cannot offer actions or replies.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use anyhow::Result;
use base64::Engine;
use base64::engine::general_purpose::STANDARD as B64;
use serde_json::{Value, json};
use tokio::io::AsyncWriteExt;
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::broadcast;
use tracing::{debug, warn};

use crate::status::runtime_dir;

pub const SERVICE_NOTIFY: i64 = 5;
pub const SERVICE_NOTIFY_WIDGET: i64 = 37;
const TYPE_CUSTOM_VIEW: i64 = 7;
const BODY_MAX_CHARS: usize = 600;
/// At most one UI update per key in this window; the latest frame wins.
const UPDATE_MIN_INTERVAL: Duration = Duration::from_millis(1000);

/// A message for the phone: (serviceId, data).
pub type PhoneCommand = (i64, Value);

#[derive(Default)]
struct Shown {
    seen: HashSet<String>,
}

/// Forwards frames to the app and keeps the coalescing/mute logic from the Linux peer.
pub struct Notifier {
    shown: Mutex<Shown>,
    /// (title, body, app) per key, for the reply UI.
    shown_text: Mutex<HashMap<String, (String, String, String)>>,
    /// Kept for parity with the Linux notifier; the macOS bridge forwards straight to the app.
    #[allow(dead_code)]
    to_phone: broadcast::Sender<PhoneCommand>,
    #[allow(dead_code)]
    local_events: broadcast::Sender<PhoneCommand>,
    /// Per key: (content fingerprint, when shown) of the last notification.
    last: Mutex<HashMap<String, (u64, Instant)>>,
    /// Per key: the newest frame waiting for its coalescing window to pass.
    pending: Mutex<HashMap<String, (i64, Value)>>,
    clients: Arc<Clients>,
}

#[derive(Default)]
struct Clients {
    streams: tokio::sync::Mutex<Vec<UnixStream>>,
}

impl Clients {
    async fn broadcast(&self, line: &str) -> bool {
        let mut streams = self.streams.lock().await;
        let mut any = false;
        let mut i = 0;
        while i < streams.len() {
            let ok = streams[i].write_all(line.as_bytes()).await.is_ok() && streams[i].write_all(b"\n").await.is_ok();
            if ok {
                any = true;
                i += 1;
            } else {
                streams.swap_remove(i);
            }
        }
        any
    }
}

impl Notifier {
    /// Starts the notification bridge. Never fails because the menu-bar app may start later.
    pub async fn new(
        to_phone: broadcast::Sender<PhoneCommand>,
        local_events: broadcast::Sender<PhoneCommand>,
    ) -> Result<Arc<Self>> {
        let clients = Arc::new(Clients::default());
        let path = crate::platform::notifications_socket();
        let _ = std::fs::remove_file(&path);
        let listener = UnixListener::bind(&path)?;
        let cs = clients.clone();
        tokio::spawn(async move {
            loop {
                match listener.accept().await {
                    Ok((stream, _)) => {
                        debug!("notifications: SmartConnect.app connected");
                        cs.streams.lock().await.push(stream);
                    }
                    Err(e) => {
                        warn!("notifications: accept failed: {e}");
                        tokio::time::sleep(Duration::from_secs(1)).await;
                    }
                }
            }
        });
        let me = Arc::new(Self {
            shown: Mutex::default(),
            shown_text: Mutex::default(),
            to_phone,
            local_events,
            last: Mutex::default(),
            pending: Mutex::default(),
            clients,
        });
        Ok(me)
    }

    /// Handles one svc 5/37 frame from the phone.
    pub async fn handle(self: &Arc<Self>, service_id: i64, n: &Value) {
        let Some(key) = n.get("key").and_then(Value::as_str) else { return };
        match n.get("event").and_then(Value::as_i64) {
            Some(0 | 1) => {
                if n.get("type").and_then(Value::as_i64) == Some(TYPE_CUSTOM_VIEW) {
                    return; // custom RemoteViews: no usable text
                }
                let pkg = n.pointer("/data/package_name").and_then(Value::as_str).unwrap_or_default();
                if is_muted(pkg) {
                    debug!(%pkg, "notifications: muted app");
                    return;
                }
                let fp = fingerprint(n);
                let since = {
                    let last = self.last.lock().unwrap();
                    match last.get(key) {
                        Some((f, _)) if *f == fp => return, // identical re-post
                        Some((_, at)) => Some(at.elapsed()),
                        None => None,
                    }
                };
                match since {
                    Some(elapsed) if elapsed < UPDATE_MIN_INTERVAL => {
                        let first = self.pending.lock().unwrap().insert(key.to_owned(), (service_id, n.clone())).is_none();
                        if first {
                            let (me, key) = (self.clone(), key.to_owned());
                            tokio::spawn(async move {
                                tokio::time::sleep(UPDATE_MIN_INTERVAL - elapsed).await;
                                let next = me.pending.lock().unwrap().remove(&key);
                                if let Some((svc, frame)) = next {
                                    me.show_now(svc, &key, &frame).await;
                                }
                            });
                        }
                    }
                    _ => self.show_now(service_id, key, n).await,
                }
            }
            Some(2) => {
                self.pending.lock().unwrap().remove(key);
                self.last.lock().unwrap().remove(key);
                self.shown_text.lock().unwrap().remove(key);
                self.shown.lock().unwrap().seen.remove(key);
                let line = json!({ "type": "remove", "key": key }).to_string();
                if !self.clients.broadcast(&line).await {
                    // osascript notifications cannot be removed individually; nothing to do.
                }
            }
            _ => {}
        }
    }

    async fn show_now(&self, service_id: i64, key: &str, n: &Value) {
        self.last.lock().unwrap().insert(key.to_owned(), (fingerprint(n), Instant::now()));
        if let Err(e) = self.show(service_id, key, n).await {
            warn!("notifications: showing failed: {e:#}");
        }
    }

    async fn show(&self, service_id: i64, key: &str, n: &Value) -> Result<()> {
        let d = n.get("data").cloned().unwrap_or(Value::Null);
        let s = |k: &str| d.get(k).and_then(Value::as_str).unwrap_or_default().to_owned();
        let app = s("apk_name");
        let pkg = s("package_name");
        let title = first_non_empty(&[s("conversation_title"), s("title"), app.clone()]);
        let body = truncate(&body_text(&d), BODY_MAX_CHARS);

        let icon = cached_app_icon(&smartconnect_fex::icons::default_cache_dir(), &pkg)
            .or_else(|| save_image(&format!("app-{}", sanitize(&pkg)), d.get("apk_icon")));
        let picture = save_image(&format!("pic-{}", sanitize(key)), d.get("big_picture"))
            .or_else(|| save_image(&format!("person-{}", sanitize(key)), sender_avatar(n)));

        let replyable = n
            .get("actions")
            .and_then(Value::as_array)
            .is_some_and(|a| a.iter().any(|a| a.get("remote_input").and_then(Value::as_bool) == Some(true)));
        let mut actions = Vec::new();
        for a in n.get("actions").and_then(Value::as_array).into_iter().flatten() {
            let (Some(id), Some(name)) = (a.get("action_id").and_then(Value::as_i64), a.get("action_name").and_then(Value::as_str))
            else {
                continue;
            };
            let reply = a.get("remote_input").and_then(Value::as_bool) == Some(true);
            actions.push(json!({ "id": id, "name": name, "reply": reply }));
        }

        let frame = json!({
            "type": "notification",
            "key": key,
            "service": service_id,
            "app": app,
            "pkg": pkg,
            "title": title,
            "body": body,
            "replyable": replyable,
            "icon": icon,
            "picture": picture,
            "actions": actions,
        });
        self.shown.lock().unwrap().seen.insert(key.to_owned());
        self.shown_text.lock().unwrap().insert(key.to_owned(), (title.clone(), body.clone(), app.clone()));
        debug!(%pkg, "notifications: shown");

        if self.clients.broadcast(&frame.to_string()).await {
            debug!(%pkg, key, "notifications: forwarded to SmartConnect.app");
            return Ok(());
        }
        // No app: a best-effort banner. It cannot offer actions or replies.
        warn!(%pkg, key, "notifications: no app client; using osascript fallback");
        osascript_notification(&app, &title, &body).await;
        Ok(())
    }
}

async fn osascript_notification(app: &str, title: &str, body: &str) {
    let script = r#"on run argv
display notification (item 2 of argv) with title (item 1 of argv) subtitle (item 3 of argv)
end run"#;
    let status = tokio::process::Command::new("osascript")
        .arg("-e")
        .arg(script)
        .arg(title)
        .arg(body)
        .arg(app)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .await;
    if let Err(e) = status {
        warn!("notifications: osascript fallback failed: {e}");
    }
}

/// Daemon-local event for a notification click the phone will carry out through app streaming:
/// `{"event":"notification_action","kind":"action"|"open","pkg","key","actionId","service"}`.
pub fn click_event(service: i64, cmd: &Value) -> Option<Value> {
    if !matches!(service, SERVICE_NOTIFY | SERVICE_NOTIFY_WIDGET) || cmd.get("cmd").and_then(Value::as_i64) != Some(0) {
        return None;
    }
    let kind = match cmd.get("event").and_then(Value::as_i64) {
        Some(1) => "action",
        Some(2) => "open",
        _ => return None,
    };
    let key = cmd.get("key").and_then(Value::as_str)?;
    let action_id = cmd.pointer("/data/action_id").cloned().unwrap_or(Value::Null);
    Some(json!({
        "event": "notification_action", "kind": kind, "pkg": key_package(key)?, "key": key,
        "actionId": action_id, "service": service,
    }))
}

/// The package inside an Android notification key (`<user>|<package>|<id>|<tag>|<uid>`).
pub fn key_package(key: &str) -> Option<String> {
    let pkg = key.split('|').nth(1)?.trim();
    (!pkg.is_empty()).then(|| pkg.to_owned())
}

/// The phone fills the app's own RemoteInput reply action with this text and fires it.
pub fn reply_command(key: &str, text: &str) -> Value {
    json!({ "cmd": 0, "event": 0, "key": key, "version": "1.0",
            "data": { "reply_content": text, "smart_reply": false } })
}

/// Best readable body for each notification style.
pub fn body_text(d: &Value) -> String {
    let s = |k: &str| d.get(k).and_then(Value::as_str).unwrap_or_default().to_owned();
    let strings = |k: &str| -> Vec<String> {
        d.get(k).and_then(Value::as_array).into_iter().flatten().filter_map(|v| v.as_str().map(str::to_owned)).collect()
    };
    let messages = strings("messages");
    if !messages.is_empty() {
        let persons = strings("message_persons");
        let conversation = !s("conversation_title").is_empty();
        return messages
            .iter()
            .enumerate()
            .rev()
            .take(4)
            .rev()
            .map(|(i, m)| match persons.get(i) {
                Some(p) if conversation && !p.is_empty() => format!("{p}: {m}"),
                _ => m.clone(),
            })
            .collect::<Vec<_>>()
            .join("\n");
    }
    let lines = strings("line_text");
    if !lines.is_empty() {
        return lines.join("\n");
    }
    first_non_empty(&[s("big_text"), s("content"), s("expand_summary")])
}

/// Hash of everything that changes what the UI shows (not the base64 images).
fn fingerprint(n: &Value) -> u64 {
    use std::hash::{Hash, Hasher};
    let d = n.get("data").cloned().unwrap_or(Value::Null);
    let mut h = std::collections::hash_map::DefaultHasher::new();
    for k in ["title", "conversation_title", "content", "big_text", "expand_summary", "priority"] {
        d.get(k).map(Value::to_string).hash(&mut h);
    }
    for k in ["messages", "message_persons", "line_text", "progress"] {
        d.get(k).map(Value::to_string).hash(&mut h);
    }
    n.get("actions").map(Value::to_string).hash(&mut h);
    h.finish()
}

/// The avatar of the person a notification is about, if the phone sent one (base64 JPEG field).
pub fn sender_avatar(n: &Value) -> Option<&Value> {
    let d = n.get("data")?;
    let icon = d.get("person_icon").filter(|v| v.as_str().is_some_and(|s| !s.trim().is_empty()))?;
    let messaging = n.get("type").and_then(Value::as_i64) == Some(3) || d.get("messages").is_some();
    if !messaging {
        return Some(icon);
    }
    let text = |k: &str| d.get(k).and_then(Value::as_str).unwrap_or_default().trim();
    let person = text("person_name");
    (!person.is_empty() && person == text("title")).then_some(icon)
}

/// The phone's launcher icon for `pkg` in the app-icon cache (`<pkg>.png`, else an
/// `<iconName>` variant, preferring the main user's copy).
fn cached_app_icon(dir: &std::path::Path, pkg: &str) -> Option<String> {
    if pkg.is_empty() || !pkg.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-')) {
        return None;
    }
    let exact = dir.join(format!("{pkg}.png"));
    if exact.is_file() {
        return Some(exact.display().to_string());
    }
    let prefix = format!("{pkg}_");
    let mut found: Vec<(bool, String)> = std::fs::read_dir(dir)
        .ok()?
        .filter_map(|e| e.ok()?.file_name().into_string().ok())
        .filter_map(|name| {
            let stem = name.strip_suffix(".png")?;
            let (other_user, rest) = match stem.split_once('_') {
                Some((user, rest)) if !user.is_empty() && user.chars().all(|c| c.is_ascii_digit()) => (true, rest),
                _ => (false, stem),
            };
            let activity = rest.strip_prefix(&prefix)?;
            let first = activity.split('.').next().unwrap_or_default();
            (activity.contains('.') && !first.contains('_')).then_some((other_user, name))
        })
        .collect();
    found.sort();
    found.into_iter().next().map(|(_, name)| dir.join(name).display().to_string())
}

/// Per-app mute list (`<state dir>/notif-mute.json`, a JSON array of package names).
fn mute_file() -> PathBuf {
    crate::platform::state_dir().join("notif-mute.json")
}

fn muted() -> &'static Mutex<HashSet<String>> {
    static MUTED: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
    MUTED.get_or_init(|| {
        let set = std::fs::read(mute_file())
            .ok()
            .and_then(|b| serde_json::from_slice::<Vec<String>>(&b).ok())
            .unwrap_or_default();
        Mutex::new(set.into_iter().collect())
    })
}

pub fn is_muted(pkg: &str) -> bool {
    !pkg.is_empty() && muted().lock().unwrap().contains(pkg)
}

/// Control command `{"cmd":"notif_mute","pkg":"com.example","mute":true|false}`.
pub fn mute_command(v: &Value) -> Value {
    let pkg = v.get("pkg").and_then(Value::as_str).unwrap_or_default().trim();
    let mut set = muted().lock().unwrap();
    if !pkg.is_empty() {
        if v.get("mute").and_then(Value::as_bool).unwrap_or(true) {
            set.insert(pkg.to_owned());
        } else {
            set.remove(pkg);
        }
        let mut list: Vec<&String> = set.iter().collect();
        list.sort();
        let path = mute_file();
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Err(e) = std::fs::write(&path, serde_json::to_vec_pretty(&list).unwrap_or_default()) {
            return json!({ "ok": false, "message": format!("saving {}: {e}", path.display()) });
        }
    }
    let mut list: Vec<&String> = set.iter().collect();
    list.sort();
    json!({ "ok": true, "muted": list })
}

fn first_non_empty(options: &[String]) -> String {
    options.iter().find(|s| !s.trim().is_empty()).cloned().unwrap_or_default()
}

fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max { s.to_owned() } else { s.chars().take(max).collect::<String>() + "…" }
}

fn sanitize(s: &str) -> String {
    s.chars().map(|c| if c.is_ascii_alphanumeric() || c == '.' || c == '-' { c } else { '_' }).take(120).collect()
}

/// Decodes a base64 JPEG field into the runtime dir.
fn save_image(name: &str, field: Option<&Value>) -> Option<String> {
    let b64: String = field?.as_str()?.chars().filter(|c| !c.is_whitespace()).collect();
    if b64.is_empty() {
        return None;
    }
    let bytes = B64.decode(b64).ok()?;
    let dir = runtime_dir().join("icons");
    std::fs::create_dir_all(&dir).ok()?;
    let path = dir.join(format!("{name}.jpg"));
    std::fs::write(&path, bytes).ok()?;
    Some(path.display().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn messaging_body_shows_recent_messages_with_senders() {
        let d = json!({ "conversation_title": "Team", "messages": ["a", "b", "c", "d", "e"],
                        "message_persons": ["Ann", "Bob", "Ann", "Bob", "Cy"] });
        assert_eq!(body_text(&d), "Bob: b\nAnn: c\nBob: d\nCy: e");
    }

    #[test]
    fn key_package_and_click_events() {
        let key = "0|com.example.clock|7|null|10123";
        assert_eq!(key_package(key).as_deref(), Some("com.example.clock"));
        let action = json!({ "cmd": 0, "event": 1, "key": key, "version": "1.0", "data": { "action_id": 2 } });
        let ev = click_event(SERVICE_NOTIFY, &action).unwrap();
        assert_eq!(ev["event"], "notification_action");
        assert_eq!(ev["kind"], "action");
        assert_eq!(ev["pkg"], "com.example.clock");
    }

    #[test]
    fn own_images_do_not_affect_fingerprint() {
        let a = json!({ "key": "k", "data": { "title": "t", "content": "c", "apk_icon": "AAAA" } });
        let b = json!({ "key": "k", "data": { "title": "t", "content": "c", "apk_icon": "BBBB" } });
        assert_eq!(fingerprint(&a), fingerprint(&b));
    }
}
