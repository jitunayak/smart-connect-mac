// SmartConnect.app: a native menu-bar app for the macOS Smart Connect port.
//
// It is deliberately thin: `smartconnectd` owns pairing, the phone session, notifications and the
// control socket. The app subscribes to the daemon's status stream, shows notifications through
// UNUserNotificationCenter, renders the pairing QR, and forwards replies/clicks back over the
// control socket.

import AppKit
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ServiceManagement
import SwiftUI
import UserNotifications
import WebKit

// MARK: - Shared paths (must match src/platform.rs)

enum Paths {
    static let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SmartConnect", isDirectory: true)
    static let controlSocket = appSupport.appendingPathComponent("control.sock").path
    static let iconCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SmartConnect", isDirectory: true)
        .appendingPathComponent("app-icons", isDirectory: true)
    static let notificationsSocket = FileManager.default.temporaryDirectory
        .appendingPathComponent("smartconnect", isDirectory: true)
        .appendingPathComponent("notifications.sock").path
    static let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SmartConnect", isDirectory: true)
    static let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/SmartConnect", isDirectory: true)
    static let daemonLog = logs.appendingPathComponent("smartconnectd.log")
    /// Cached phone app list (service 17 `cmd 1`), so the Streams surfaces open instantly even
    /// before the phone answers the fresh request.
    static let appsCache = cache.appendingPathComponent("apps-cache.json")
}

// MARK: - UNIX socket line I/O

enum UnixSocket {
    static func connect(path: String, timeout: TimeInterval = 4) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        // A closed daemon end would otherwise raise SIGPIPE from the write loop.
        var val: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &val, socklen_t(MemoryLayout<Int32>.size))
        if timeout > 0 {
            var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return nil
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        if ok != 0 {
            close(fd)
            return nil
        }
        return fd
    }

    /// Writes one whole `\n`-terminated line and reports failure. The old version dropped
    /// partial writes and every error sign — a full `SO_SNDTIMEO` read buffer (the daemon
    /// stopped draining us) made each send vanish silently and permanently. (Wire report:
    /// `cmd 9` beats and the `svc 1` accept never reached the daemon after a link stall.)
    @discardableResult
    static func writeLine(_ line: String, to fd: Int32) -> Bool {
        var data = Data(line.utf8)
        data.append(0x0A)
        var off = 0
        var ok = true
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                if n > 0 {
                    off += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    ok = false // buffer full past the send timeout, EPIPE, or the peer is gone
                    return
                }
            }
        }
        return ok
    }

    /// Reads one `\n`-terminated line. `tolerateTimeout` keeps waiting across `SO_RCVTIMEO`
    /// expirations instead of reporting EOF (the reply drain shares the control socket, where
    /// a 2 s data gap is normal — the drain used to die on the first quiet gap and never return).
    static func readLine(from fd: Int32, tolerateTimeout: Bool = false) -> String? {
        var buffer = [UInt8]()
        var byte: UInt8 = 0
        while true {
            let n = Darwin.read(fd, &byte, 1)
            if n < 0 {
                if errno == EINTR { continue }
                if tolerateTimeout && (errno == EAGAIN || errno == EWOULDBLOCK) { continue }
                return nil
            }
            if n <= 0 { return nil }
            if byte == 0x0A {
                return String(decoding: buffer, as: UTF8.self)
            }
            buffer.append(byte)
        }
    }
}

// MARK: - Daemon client

struct PhoneNotification: Codable, Identifiable, Hashable {
    var key: String
    var service: Int
    var app: String
    var pkg: String
    var title: String
    var body: String
    var replyable: Bool
    var id: String { key }
}

/// Phone apps that also exist as Mac apps: clicking such a notification opens the local app
/// instead of streaming the phone's copy (WhatsApp being the one that matters most).
enum MacAppCounterpart {
    /// Phone package → macOS bundle identifier, for the pairs where guessing the bundle id
    /// from the name is unreliable (Telegram, Slack, Teams all have past/present variants).
    private static let pkgToMacBundleID: [String: String] = [
        "com.whatsapp": "net.whatsapp.WhatsApp",
        "org.telegram.messenger": "ru.keepcoder.Telegram",
        "org.telegram.messenger.web": "ru.keepcoder.Telegram",
        "com.discord": "com.hnc.Discord",
        "com.spotify.music": "com.spotify.client",
        "com.slack": "com.tinyspeck.slackmacgap",
        "com.microsoft.teams": "com.microsoft.teams2",
        "com.microsoft.office.outlook": "com.microsoft.Outlook",
        "us.zoom.videomeetings": "us.zoom.xos",
        "com.instagram.android": "com.burbn.instagram.mac",
    ]

    /// The installed Mac app that corresponds to this phone app, or nil when there is none.
    /// Known bundle ids are tried by package name; otherwise the app label from the phone
    /// ("WhatsApp") is matched against an installed `/Applications/<name>.app`.
    static func macAppURL(app: String?, pkg: String?) -> URL? {
        if let bid = pkg.flatMap({ pkgToMacBundleID[$0] }),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            return url
        }
        guard let name = app?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        for dir in ["/Applications", ("~/Applications" as NSString).expandingTildeInPath] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).app")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url
            }
        }
        return nil
    }

    /// True when clicking this notification would open a local Mac app.
    static func hasCounterpart(app: String?, pkg: String?) -> Bool {
        macAppURL(app: app, pkg: pkg) != nil
    }

    /// True when the Mac counterpart is not merely installed but actually running — e.g. the
    /// user has WhatsApp desktop open. That is the signal to stop mirroring that app's phone
    /// notifications (quit the Mac app and the mirroring resumes).
    static func counterpartRunning(app: String?, pkg: String?) -> Bool {
        guard let url = macAppURL(app: app, pkg: pkg),
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return false }
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL == url || $0.bundleIdentifier == bundleID
        }
    }
}

struct PhoneStatus: Codable, DefaultConstructible {
    var connected = false
    var paired = false
    var name: String?
    var model: String?
    var battery: Int?
    var charging = false
    var wifi = false
    var wifiSignal: Int?
    var cellSignal: Int?
    var bluetooth = false
    var unread: Int?
    var wallpaper: String?
    var pairingQr: String?
    var pairingPayload: String?
    var pcAddress: String?
    var phoneAddress: String?
    var notifications: [PhoneNotification] = []

    init() {}
}

protocol DefaultConstructible { init() }

@MainActor
final class DaemonClient: ObservableObject {
    static let shared = DaemonClient()
    @Published var status: PhoneStatus?
    @Published var online = false
    @Published var busy = false
    @Published var lastMessage: String?
    /// Notifications received over the bridge. They are merged with `status.notifications`, so the
    /// tab still works if the daemon's snapshot lags or filters an entry.
    @Published var bridgeNotifications: [PhoneNotification] = []
    /// Keys the user acted on (opened, answered or used an action button) or that arrived with a
    /// remove event (dismissed on the phone). They stay listed under the "Earlier" section.
    @Published var handledKeys: Set<String> = []
    /// Keys hidden on purpose via the per-row clear button, whatever list they came from.
    private var hiddenKeys: Set<String> = []
    /// Bridge retention: enough for several days of typical notifications.
    private static let bridgeCapacity = 200

    private var started = false

    /// All known notifications, newest first, de-duplicated by key, with the hidden ones filtered.
    var recentNotifications: [PhoneNotification] {
        var seen = Set<String>()
        var out: [PhoneNotification] = []
        for note in bridgeNotifications + (status?.notifications ?? [])
        where seen.insert(note.key).inserted && !hiddenKeys.contains(note.key) {
            out.append(note)
        }
        return Array(out.prefix(300))
    }

    func note(_ note: PhoneNotification) {
        // A repeated key is an update of the same notification: replace it in place, and when the
        // content actually changed, consider it fresh again.
        let existing = bridgeNotifications.first { $0.key == note.key }
        if let existing, existing != note {
            handledKeys.remove(note.key)
        }
        if existing == nil {
            bridgeNotifications.insert(note, at: 0)
        } else {
            bridgeNotifications.removeAll { $0.key == note.key }
            bridgeNotifications.insert(note, at: 0)
        }
        if bridgeNotifications.count > Self.bridgeCapacity {
            bridgeNotifications.removeLast(bridgeNotifications.count - Self.bridgeCapacity)
        }
    }

    /// The notification no longer exists on the phone (dismissed there): keep it listed,
    /// but move it into the "Earlier" (already handled) section.
    func markHandled(key: String) {
        handledKeys.insert(key)
    }

    /// Per-row clear: forget the entry everywhere it is listed from.
    func removeNote(key: String) {
        bridgeNotifications.removeAll { $0.key == key }
        hiddenKeys.insert(key)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [key])
    }

    /// Drop everything in the "Earlier" section.
    func removeAllHandled() {
        for key in handledKeys {
            hiddenKeys.insert(key)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [key])
        }
        bridgeNotifications.removeAll { handledKeys.contains($0.key) }
        handledKeys.removeAll()
    }

    func start() {
        guard !started else { return }
        started = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.subscribeLoop()
        }
    }

    /// `subscribe` is a long-lived connection: the daemon prints the current status and then one
    /// JSON object per change. It also tells us when the daemon is not running.
    nonisolated private func subscribeLoop() {
        while true {
            // A subscription is intentionally long-lived and mostly idle, so it must not inherit
            // the one-shot request timeout.
            if let fd = UnixSocket.connect(path: Paths.controlSocket, timeout: 0) {
                UnixSocket.writeLine("subscribe", to: fd)
                while let line = UnixSocket.readLine(from: fd) {
                    if let data = line.data(using: .utf8),
                       let status = try? JSONDecoder().decode(PhoneStatus.self, from: data) {
                        Task { @MainActor in
                            self.status = status
                            self.online = true
                        }
                    }
                }
                close(fd)
            }
            Task { @MainActor in self.online = false }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    /// One-shot command, returns the daemon's JSON reply.
    nonisolated func request(_ command: String) async -> [String: Any] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let fd = UnixSocket.connect(path: Paths.controlSocket) else {
                    cont.resume(returning: ["ok": false, "message": "smartconnectd is not running"])
                    return
                }
                defer { close(fd) }
                UnixSocket.writeLine(command, to: fd)
                guard let line = UnixSocket.readLine(from: fd),
                      let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    cont.resume(returning: ["ok": false, "message": "no reply from smartconnectd"])
                    return
                }
                cont.resume(returning: obj)
            }
        }
    }

    func connect() {
        Task {
            busy = true
            let r = await request("connect")
            lastMessage = r["message"] as? String
            busy = false
        }
    }

    func disconnect() {
        Task {
            busy = true
            let r = await request("disconnect")
            lastMessage = r["message"] as? String
            busy = false
        }
    }

    func pair() {
        Task {
            let r = await request("pair")
            lastMessage = r["message"] as? String
        }
    }

    func reply(key: String, text: String) {
        Task {
            let obj: [String: Any] = ["cmd": "reply", "key": key, "text": text]
            if let data = try? JSONSerialization.data(withJSONObject: obj),
               let line = String(data: data, encoding: .utf8) {
                _ = await request(line)
            }
            markHandled(key: key)
        }
    }

    /// Opens a notification on the phone — unless the same app also lives on this Mac
    /// (WhatsApp and friends), in which case the local app is launched and the phone stays
    /// untouched.
    func openOnPhone(key: String, service: Int, app: String? = nil, pkg: String? = nil) {
        markHandled(key: key)
        if let url = MacAppCounterpart.macAppURL(app: app, pkg: pkg) {
            NSLog("SmartConnect: notifications: opening Mac app \(url.lastPathComponent) for \(pkg ?? app ?? key)")
            NSWorkspace.shared.open(url)
            return
        }
        send(service: service, data: ["cmd": 0, "event": 2, "key": key, "version": "1.0"])
    }

    func runAction(key: String, service: Int, actionID: Int) {
        markHandled(key: key)
        send(service: service, data: ["cmd": 0, "event": 1, "key": key, "version": "1.0", "data": ["action_id": actionID]])
    }

    private func send(service: Int, data: [String: Any]) {
        Task {
            let obj: [String: Any] = ["cmd": "send", "service": service, "data": data]
            if let d = try? JSONSerialization.data(withJSONObject: obj),
               let line = String(data: d, encoding: .utf8) {
                _ = await request(line)
            }
        }
    }
}

// MARK: - Notification bridge

struct NotificationAction: Codable, Hashable {
    var id: Int
    var name: String
    var reply: Bool
}

struct NotificationFrame: Codable {
    var type: String
    var key: String?
    var service: Int?
    var app: String?
    var pkg: String?
    var title: String?
    var body: String?
    var replyable: Bool?
    var icon: String?
    var picture: String?
    var actions: [NotificationAction]?
}

final class NotificationBridge: NSObject {
    static let shared = NotificationBridge()
    private var started = false
    private var categories = Set<UNNotificationCategory>()

    func start() {
        guard !started else { return }
        started = true
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            NSLog("SmartConnect: notification authorization granted=\(granted) error=\(String(describing: error))")
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            NSLog("SmartConnect: notification settings authorization=\(settings.authorizationStatus.rawValue) alert=\(settings.alertSetting.rawValue)")
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.listen() }
    }

    private func listen() {
        while true {
            // Like the status subscription, this connection is long-lived and mostly idle.
            if let fd = UnixSocket.connect(path: Paths.notificationsSocket, timeout: 0) {
                while let line = UnixSocket.readLine(from: fd) {
                    guard let data = line.data(using: .utf8),
                          let frame = try? JSONDecoder().decode(NotificationFrame.self, from: data) else { continue }
                    DispatchQueue.main.async { @MainActor in self.present(frame) }
                }
                close(fd)
            }
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    @MainActor private func present(_ frame: NotificationFrame) {
        guard frame.type == "notification", let key = frame.key else {
            if frame.type == "remove", let key = frame.key {
                // Dismissed on the phone: keep it listed in the app, but as already handled.
                DaemonClient.shared.markHandled(key: key)
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [key])
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [key])
            }
            return
        }
        let app = frame.app ?? "Phone"
        // The same app open on the Mac makes mirrored phone notifications redundant noise
        // (WhatsApp desktop already shows its own): drop these before any banner or list.
        if MacAppCounterpart.counterpartRunning(app: frame.app, pkg: frame.pkg) {
            NSLog("SmartConnect: notifications: suppressing \(app) notification \(key) — its Mac app is open")
            DaemonClient.shared.markHandled(key: key)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [key])
            return
        }
        let title = (frame.title?.isEmpty == false ? frame.title! : app)
        let body = frame.body ?? ""
        DaemonClient.shared.note(PhoneNotification(
            key: key,
            service: frame.service ?? 5,
            app: app,
            pkg: frame.pkg ?? "",
            title: title,
            body: body,
            replyable: frame.replyable == true
        ))
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = app
        content.body = body
        content.sound = .default
        content.threadIdentifier = key
        content.userInfo = ["key": key, "service": frame.service ?? 5, "app": app, "pkg": frame.pkg ?? ""]
        content.categoryIdentifier = registerCategory(for: frame)

        let attachmentPath = frame.picture ?? frame.icon
        if let path = attachmentPath, FileManager.default.fileExists(atPath: path) {
            if let attachment = try? UNNotificationAttachment(identifier: "attachment", url: URL(fileURLWithPath: path), options: nil) {
                content.attachments = [attachment]
            }
        }

        let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("SmartConnect: failed to deliver notification \(key): \(error)")
            }
        }
    }

    /// UN categories must exist before a notification is delivered. Build one per notification
    /// shape and register the union again; the set stays small because it is keyed by the action
    /// list, not by key.
    private func registerCategory(for frame: NotificationFrame) -> String {
        var actions: [UNNotificationAction] = []
        if frame.replyable == true {
            actions.append(UNTextInputNotificationAction(
                identifier: "reply",
                title: "Reply",
                options: [],
                textInputButtonTitle: "Send",
                textInputPlaceholder: "Reply…"
            ))
        } else {
            actions.append(UNNotificationAction(
                identifier: "open",
                title: MacAppCounterpart.hasCounterpart(app: frame.app, pkg: frame.pkg)
                    ? "Open on Mac" // the Mac app takes the click, not the streamed phone app
                    : "Open on phone",
                options: []
            ))
        }
        for a in frame.actions ?? [] where !a.reply {
            actions.append(UNNotificationAction(identifier: "a\(a.id)", title: a.name, options: []))
        }
        let signature = actions.map(\.identifier).joined(separator: ",")
        let identifier = "sc-" + signature.unicodeScalars.map { String(format: "%02x", $0.value) }.joined().prefix(60)
        let category = UNNotificationCategory(identifier: String(identifier), actions: actions, intentIdentifiers: [], options: [])
        if !categories.contains(category) {
            categories.insert(category)
            UNUserNotificationCenter.current().setNotificationCategories(categories)
        }
        return String(identifier)
    }
}

extension NotificationBridge: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let key = info["key"] as? String ?? ""
        let service = info["service"] as? Int ?? 5
        let app = info["app"] as? String
        let pkg = info["pkg"] as? String
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            if action == "reply", let text = (response as? UNTextInputNotificationResponse)?.userText, !text.isEmpty {
                DaemonClient.shared.reply(key: key, text: text)
                DaemonClient.shared.markHandled(key: key)
            } else if action == UNNotificationDefaultActionIdentifier || action == "open" {
                DaemonClient.shared.openOnPhone(key: key, service: service, app: app, pkg: pkg)
                DaemonClient.shared.markHandled(key: key)
            } else if action.hasPrefix("a"), let id = Int(action.dropFirst()) {
                DaemonClient.shared.runAction(key: key, service: service, actionID: id)
                DaemonClient.shared.markHandled(key: key)
            }
        }
        completionHandler()
    }
}

// MARK: - Window bridge

@MainActor
final class WindowActionBridge {
    static let shared = WindowActionBridge()

    func openMain() {
        AppDelegate.shared?.showMainWindow()
    }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    /// The daemon's log file is kept open for as long as the child lives.
    private static var daemonLogHandle: FileHandle?
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        if CommandLine.arguments.contains("--check-notifications") {
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let out: [String: Any] = [
                    "authorization": settings.authorizationStatus.rawValue,
                    "alert": settings.alertSetting.rawValue,
                    "sound": settings.soundSetting.rawValue,
                    "badge": settings.badgeSetting.rawValue,
                    "notificationCenter": settings.notificationCenterSetting.rawValue,
                ]
                try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted])
                    .write(to: URL(fileURLWithPath: "/tmp/smartconnect-notif-settings.json"))
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return
        }
        // Dock presence is a setting (Settings ✓ *Show SmartConnect in the Dock*): `.regular`
        // gives the tile, `.accessory` hides it again. Applied here so it also holds when macOS
        // re-launches the app at login.
        if UserDefaults.standard.bool(forKey: "showInDock") {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
        DaemonClient.shared.start()
        NotificationBridge.shared.start()
        StreamHost.shared.start()
        _ = ensureDaemonRunning()

        // A menu-bar-only app with no window is confusing on first launch. Show the main window
        // once, then stay out of the way.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "hasLaunchedBefore") || CommandLine.arguments.contains("--show-window") {
            NSLog("SmartConnect: scheduling first window (args=\(CommandLine.arguments))")
            defaults.set(true, forKey: "hasLaunchedBefore")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NSLog("SmartConnect: opening first window")
                WindowActionBridge.shared.openMain()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.scheme == "smartconnect" }) {
            showMainWindow()
        }
    }

    /// A normal AppKit window hosting the SwiftUI tabs. Using a scene would work too, but a menu
    /// bar app also wants a reliable programmatic entry point (first run, Dock reopen, URL).
    func showMainWindow() {
        NSLog("SmartConnect: showMainWindow called, existing=\(mainWindow != nil)")
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = MainWindow()
            .environmentObject(DaemonClient.shared)
            .frame(minWidth: 640, minHeight: 460)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "SmartConnect"
        // Glass look: the window is fully transparent and the SwiftUI content draws the
        // vibrancy material edge to edge, including under the title bar.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 920, height: 610))
        window.contentMinSize = NSSize(width: 640, height: 460)
        window.center()
        window.setFrameAutosaveName("main")
        mainWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSLog("SmartConnect: window visible=\(window.isVisible) frame=\(window.frame)")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// The daemon's launch arguments, derived from the app's settings.
    static func daemonArguments() -> [String] {
        var args = [String]()
        if UserDefaults.standard.bool(forKey: "allTiles") { args.append("--all-tiles") }
        if UserDefaults.standard.bool(forKey: "sessionLog") { args.append("--session-log") }
        return args
    }

    /// Stops the daemon and starts it again with the current settings. Used when a setting that
    /// only reaches the daemon through its command line changes; the phone reconnects on its own.
    func restartDaemon() {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            p.arguments = ["-x", "smartconnectd"]
            try? p.run()
            p.waitUntilExit()
            DispatchQueue.main.async {
                AppDelegate.shared?.ensureDaemonRunning()
            }
        }
    }

    @discardableResult
    private func ensureDaemonRunning() -> Bool {
        // Short timeout: this runs on the main thread during launch.
        if UnixSocket.connect(path: Paths.controlSocket, timeout: 0.5) != nil { return true }
        // Prefer the daemon inside our own bundle, then PATH.
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/smartconnectd").path
        let candidate = FileManager.default.isExecutableFile(atPath: bundled) ? bundled : "smartconnectd"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: candidate)
        p.arguments = AppDelegate.daemonArguments()

        // Keep stdout/stderr in ~/Library/Logs/SmartConnect so a failed connection can be
        // diagnosed without relaunching from a terminal.
        try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: Paths.daemonLog.path),
           let size = attrs[.size] as? NSNumber, size.intValue > 2_000_000 {
            let old = Paths.logs.appendingPathComponent("smartconnectd.log.1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: Paths.daemonLog, to: old)
        }
        if !FileManager.default.fileExists(atPath: Paths.daemonLog.path) {
            FileManager.default.createFile(atPath: Paths.daemonLog.path, contents: nil)
        }
        let log = try? FileHandle(forWritingTo: Paths.daemonLog)
        log?.seekToEndOfFile()
        Self.daemonLogHandle = log
        p.standardOutput = log ?? FileHandle.nullDevice
        p.standardError = log ?? FileHandle.nullDevice

        do {
            try p.run()
            Thread.sleep(forTimeInterval: 0.8)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - SwiftUI

@main
struct SmartConnectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // NOTE: Command Line Tools ship SwiftUI without its macro plugin, so the @State /
    // @EnvironmentObject / @Environment sugar cannot be expanded here. These declarations are
    // the equivalent manual expansion; they can be switched back to attributes when built
    // with a full Xcode toolchain.
    private var _daemon: StateObject<DaemonClient> = StateObject(wrappedValue: DaemonClient.shared)
    private var daemon: DaemonClient { _daemon.wrappedValue }

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(daemon)
        } label: {
            Image(systemName: daemon.status?.connected == true ? "iphone.radiowaves.left.and.right" : "iphone.slash")
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuContent: View {
    private var _daemon: EnvironmentObject<DaemonClient> = EnvironmentObject()
    private var daemon: DaemonClient { _daemon.wrappedValue }
    // The panel hosts the Streams and Notifications tabs directly (they used to be reachable
    // only through the main window); the full-sized tabs stay there too.
    private var _section: State<Int> = State(initialValue: 0)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header card: connection ring, device identity and battery as a small badge.
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(daemon.status?.connected == true ? Color.green.opacity(0.16) : Color.secondary.opacity(0.14))
                        .frame(width: 38, height: 38)
                    Image(systemName: daemon.status?.connected == true ? "iphone.radiowaves.left.and.right" : "iphone.slash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(daemon.status?.connected == true ? Color.green : Color.secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(daemon.status?.name ?? "Smart Connect")
                        .font(.system(.callout, design: .default, weight: .semibold))
                    Text(statusLine).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let s = daemon.status, s.connected, let battery = s.battery {
                    HStack(spacing: 4) {
                        Image(systemName: s.charging ? "bolt" : (battery > 50 ? "battery.75" : "battery.25"))
                            .font(.system(size: 11))
                        Text("\(battery)%").font(.caption2).fontWeight(.medium)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
            }

            Picker("Panel", selection: _section.projectedValue) {
                Image(systemName: "iphone").tag(0)
                Image(systemName: "play.rectangle").tag(1)
                Image(systemName: "ellipsis.message").tag(2)
                Image(systemName: "bell").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch _section.wrappedValue {
                case 0: MenuPhoneSection()
                case 1: MenuStreamsSection()
                case 2: MenuMessagesSection()
                default: MenuNotificationsSection()
                }
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))

            HStack(spacing: 8) {
                Button {
                    WindowActionBridge.shared.openMain()
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Open", systemImage: "macwindow")
                        .font(.caption)
                }
                .controlSize(.small)
                Spacer()
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                        .font(.caption)
                }
                .controlSize(.small)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 364)
    }

    private var statusLine: String {
        guard daemon.online else { return "smartconnectd is not running" }
        guard let s = daemon.status else { return "Connecting to smartconnectd…" }
        if s.connected { return s.model ?? "Connected" }
        if s.paired { return "Paired · not connected" }
        return "Not paired"
    }
}

/// The menu panel's Phone section: connection controls and the last action message.
struct MenuPhoneSection: View {
    private var _daemon: EnvironmentObject<DaemonClient> = EnvironmentObject()
    private var daemon: DaemonClient { _daemon.wrappedValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    daemon.status?.connected == true ? daemon.disconnect() : daemon.connect()
                } label: {
                    Label(daemon.status?.connected == true ? "Disconnect" : "Connect",
                          systemImage: daemon.status?.connected == true ? "iphone.slash" : "link")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(daemon.busy || daemon.online == false)

                Button {
                    daemon.pair()
                    WindowActionBridge.shared.openMain()
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Pair…", systemImage: "qrcode").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(daemon.online == false)
            }

            if let message = daemon.lastMessage, !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

/// The menu panel's Streams section: view tiles, running streams and the phone's app list.
struct MenuStreamsSection: View {
    private var _daemon: EnvironmentObject<DaemonClient> = EnvironmentObject()
    private var daemon: DaemonClient { _daemon.wrappedValue }
    private var _host: ObservedObject<StreamHost> = ObservedObject(wrappedValue: StreamHost.shared)
    private var host: StreamHost { _host.wrappedValue }
    private var _search: State<String> = State(initialValue: "")
    private var search: String { _search.wrappedValue }

    private var filtered: [StreamHost.StreamApp] {
        host.apps.filter {
            search.isEmpty
                || $0.name.localizedCaseInsensitiveContains(search)
                || $0.pkg.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    host.startView(1)
                } label: {
                    Label("Screen share", systemImage: "play.rectangle").frame(maxWidth: .infinity)
                }
                Button {
                    host.startView(2)
                } label: {
                    Label("Desktop", systemImage: "desktopcomputer").frame(maxWidth: .infinity)
                }
                Button {
                    host.requestApps()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(daemon.status?.connected != true)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(daemon.status?.connected != true)
            ForEach(host.streamList, id: \.sid) { s in
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.inset.bottomleft.filled").foregroundStyle(.secondary)
                    Text(s.title).lineLimit(1)
                    Spacer()
                    Button("Close") { host.closeStream(s.sid) }
                }
                .font(.callout)
            }

            if host.apps.isEmpty {
                Text(daemon.status?.connected == true
                     ? "No app list yet — the phone sends it shortly after connecting; Refresh asks again."
                     : "Connect the phone to load its apps.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                TextField("Search apps", text: _search.projectedValue)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filtered, id: \.key) { app in
                            Button {
                                host.startApp(app)
                            } label: {
                                HStack(spacing: 8) {
                                    if let img = StreamHost.iconImage(app.iconName) {
                                        Image(nsImage: img)
                                            .resizable()
                                            .frame(width: 22, height: 22)
                                            .clipShape(RoundedRectangle(cornerRadius: 5))
                                    } else {
                                        Image(systemName: "app")
                                            .foregroundStyle(.secondary)
                                            .frame(width: 22)
                                    }
                                    Text(app.work ? "\(app.name) · work" : app.name)
                                        .lineLimit(1)
                                        .font(.callout)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .onAppear { host.requestAppsIfStale() }
    }
}

/// The menu panel's Notifications section: the phone's notifications with inline reply and open.
/// The menu panel's Messages section: compact conversations; a selected thread becomes a
/// mini-conversation with a composer, mirroring the *Messages* page of the window.
struct MenuMessagesSection: View {
    private var _daemon: EnvironmentObject<DaemonClient> = EnvironmentObject()
    private var daemon: DaemonClient { _daemon.wrappedValue }

    private var _threads: State<[[String: Any]]> = State(initialValue: [])
    private var threads: [[String: Any]] { _threads.wrappedValue }
    private var _selected: State<String?> = State(initialValue: nil)
    private var selected: String? { _selected.wrappedValue }
    private var _messages: State<[SMSMsg]> = State(initialValue: [])
    private var messages: [SMSMsg] { _messages.wrappedValue }
    private var _draft: State<String> = State(initialValue: "")
    private var _copiedId: State<Int?> = State(initialValue: nil)
    private var copiedId: Int? { _copiedId.wrappedValue }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let key = selected {
                detail(key)
            } else {
                list
            }
        }
        .onAppear { Task { await refreshThreads() } }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            if daemon.status?.connected != true {
                Text("Connect the phone to load its SMS.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if threads.isEmpty {
                Text("No conversations yet — the first sync enables Messages for this PC (the phone may ask to allow it).")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(threads.prefix(8).indices, id: \.self) { i in
                    let t = threads[i]
                    Button {
                        _selected.wrappedValue = t["thread"] as? String
                        Task { await refreshThread() }
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(t["name"] as? String ?? t["address"] as? String ?? "")
                                        .font(.system(.callout, design: .default, weight: .medium))
                                        .lineLimit(1)
                                    if let unread = t["unread"] as? Int, unread > 0 {
                                        Text("\(unread)")
                                            .font(.caption2).fontWeight(.semibold)
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(Capsule().fill(Color.accentColor))
                                    }
                                }
                                Text(t["last_body"] as? String ?? "")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if i < min(7, threads.count - 1) {
                        Divider().padding(.leading, 4)
                    }
                }
                if threads.count > 8 {
                    Text("\(threads.count - 8) more on the window's Messages page.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func detail(_ key: String) -> some View {
        let t = threads.first { ($0["thread"] as? String) == key }
        return VStack(alignment: .leading, spacing: 6) {
            // One-tap copy for the newest code, above the thread itself.
            if let last = messages.last, !last.sent, let code = OTPFinder.otp(in: last.body) {
                HStack(spacing: 6) {
                    Image(systemName: "lock_shield").foregroundStyle(Color.accentColor)
                    Text(code).font(.caption).fontWeight(.semibold)
                    Button {
                        OTPFinder.copyToPasteboard(code)
                        _copiedId.wrappedValue = last.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            if _copiedId.wrappedValue == last.id { _copiedId.wrappedValue = nil }
                        }
                    } label: {
                        Label(copiedId == last.id ? "Copied" : "Copy",
                              systemImage: copiedId == last.id ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    Spacer()
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10)))
            }
            HStack(spacing: 6) {
                Button {
                    _selected.wrappedValue = nil
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                Text(t?["name"] as? String ?? t?["address"] as? String ?? key)
                    .font(.system(.callout, design: .default, weight: .medium))
                    .lineLimit(1)
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if messages.isEmpty {
                        Text("No cached messages yet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(messages, id: \.self) { m in
                        HStack {
                            if m.sent { Spacer(minLength: 36) }
                            Text(LinkText.body(m.body, sent: m.sent))
                                .font(.caption)
                                .environment(\.openURL, OpenURLAction { url in
                                    NSWorkspace.shared.open(url)
                                    return .handled
                                })
                                .textSelection(.enabled)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(m.sent ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.08)))
                                .foregroundStyle(m.sent ? Color.white : Color.primary)
                            if !m.sent { Spacer(minLength: 36) }
                        }
                    }
                }
            }
            .frame(maxHeight: 230)
            HStack(spacing: 6) {
                TextField("Text message…", text: _draft.projectedValue)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { Task { await sendDraft(key) } }
                Button {
                    Task { await sendDraft(key) }
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .controlSize(.small)
                .disabled(_draft.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: actions

    private func refreshThreads() async {
        let r = await requestJSON(["cmd": "sms_threads"])
        if r["ok"] as? Bool == true {
            _threads.wrappedValue = r["threads"] as? [[String: Any]] ?? []
        }
    }

    private func refreshThread() async {
        guard let key = selected else { return }
        let r = await requestJSON(["cmd": "sms_thread", "thread": key])
        guard r["ok"] as? Bool == true else { return }
        let loaded = (r["messages"] as? [[String: Any]] ?? []).compactMap(SMSMsg.init)
        _messages.wrappedValue = loaded
        let unreadIds = loaded.filter { !$0.read && !$0.sent }.map(\.id)
        for id in unreadIds {
            _ = await requestJSON(["cmd": "sms_mark_read", "id": id])
        }
        if !unreadIds.isEmpty {
            _messages.wrappedValue = loaded.map { m in
                var v = m
                if !v.read && !v.sent { v.read = true }
                return v
            }
        }
    }

    private func sendDraft(_ key: String) async {
        let text = _draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let r = await requestJSON(["cmd": "sms_send", "thread": key, "text": text])
        if r["ok"] as? Bool == true {
            _draft.wrappedValue = ""
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await refreshThread()
        }
    }

    private func requestJSON(_ obj: [String: Any]) async -> [String: Any] {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let line = String(data: data, encoding: .utf8) else {
            return ["ok": false, "message": "could not encode command"]
        }
        return await daemon.request(line)
    }
}

struct MenuNotificationsSection: View {
    private var _daemon: EnvironmentObject<DaemonClient> = EnvironmentObject()
    private var daemon: DaemonClient { _daemon.wrappedValue }
    private var _replying: State<PhoneNotification?> = State(initialValue: nil)
    private var replying: PhoneNotification? {
        get { _replying.wrappedValue }
        nonmutating set { _replying.wrappedValue = newValue }
    }
    private var _replyText: State<String> = State(initialValue: "")
    private var replyText: String {
        get { _replyText.wrappedValue }
        nonmutating set { _replyText.wrappedValue = newValue }
    }

    var body: some View {
        let all = daemon.recentNotifications
        let fresh = all.filter { !daemon.handledKeys.contains($0.key) }
        let handled = all.filter { daemon.handledKeys.contains($0.key) }
        return VStack(alignment: .leading, spacing: 8) {
            if all.isEmpty {
                Text(daemon.status?.connected == true
                     ? "No notifications yet."
                     : "Notifications from the phone appear here while it is connected.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("New").font(.caption).fontWeight(.semibold)
                    Spacer()
                    if !handled.isEmpty {
                        Button("Clear handled") { daemon.removeAllHandled() }
                            .font(.caption2)
                    }
                }
                ForEach(fresh) { note in
                    noteRow(note, isHandled: false)
                }
                if fresh.isEmpty {
                    Text("Nothing new.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !handled.isEmpty {
                    Divider().padding(.vertical, 2)
                    Text("Earlier (opened, replied to or dismissed)")
                        .font(.caption2).foregroundStyle(.secondary)
                    ForEach(handled) { note in
                        noteRow(note, isHandled: true)
                    }
                }
            }
        }
    }

    private func noteRow(_ note: PhoneNotification, isHandled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: isHandled ? "envelope.open" : "envelope")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(note.app).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if isHandled {
                    Button {
                        daemon.removeNote(key: note.key)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 8))
                    }
                    .buttonStyle(.plain)
                } else {
                    if note.replyable {
                        Button("Reply") {
                            replying = note
                            replyText = ""
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                    Button("Open") { daemon.openOnPhone(key: note.key, service: note.service, app: note.app, pkg: note.pkg) }
                        .buttonStyle(.link).font(.caption)
                }
            }
            Text(note.title).font(.callout).lineLimit(1)
            Text(note.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if replying?.key == note.key {
                HStack(spacing: 6) {
                    TextField("Reply…", text: _replyText.projectedValue)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    Button("Send") {
                        daemon.reply(key: note.key, text: replyText)
                        replying = nil
                    }
                    .controlSize(.small)
                    .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .opacity(isHandled ? 0.65 : 1)
        .padding(.top, 2)
    }
}

struct MainWindow: View {
    private var _daemon: EnvironmentObject<DaemonClient> = EnvironmentObject()
    private var daemon: DaemonClient { _daemon.wrappedValue }
    private var _section: State<Int> = State(initialValue: 0)

    var body: some View {
        // Phone-Link-style layout in a glass window: vibrancy draws under everything (including
        // the hidden title bar), the rail gets a slightly denser material, and the pages keep
        // comfortable padding.
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Edge70PhoneView()
                    .frame(maxWidth: .infinity) // center the phone in the rail like Phone Link
                    .padding(.top, 42) // clears the traffic lights (full-size content view)
                    .padding(.bottom, 18)
                navItem(0, icon: "iphone", label: "Phone")
                navItem(1, icon: "play.rectangle", label: "Streams")
                navItem(2, icon: "bell", label: "Notifications")
                navItem(3, icon: "ellipsis.message", label: "Messages")
                navItem(4, icon: "gearshape", label: "Settings")
                Spacer()
            }
            .frame(width: 232)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(.thinMaterial)
            .padding(.bottom, 4)

            Divider().opacity(0.25)

            Group {
                switch _section.wrappedValue {
                case 0: PhoneView()
                case 1: ScrollView { StreamsContent() }
                case 2: NotificationsView()
                case 3: MessagesView()
                default: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Only the rail keeps the glass vibrancy; the content pane is the normal,
            // opaque window background like before, with the pages' own paddings.
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    private func navItem(_ tag: Int, icon: String, label: String) -> some View {
        let selected = _section.wrappedValue == tag
        return Button {
            _section.wrappedValue = tag
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                Text(label)
                    .font(.system(.body, design: .default, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.03))
            )
            .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.8))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
    }
}

struct StreamsContent: View {
    private var _daemon: EnvironmentObject<DaemonClient> = EnvironmentObject()
    private var daemon: DaemonClient { _daemon.wrappedValue }
    private var _host: ObservedObject<StreamHost> = ObservedObject(wrappedValue: StreamHost.shared)
    private var host: StreamHost { _host.wrappedValue }
    private var _search: State<String> = State(initialValue: "")
    private var search: String { _search.wrappedValue }

    private var filtered: [StreamHost.StreamApp] {
        host.apps.filter {
            search.isEmpty
                || $0.name.localizedCaseInsensitiveContains(search)
                || $0.pkg.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Streams").font(.title2.bold())
                Spacer()
                if daemon.status?.connected != true {
                    Label("Phone not connected", systemImage: "iphone.slash")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Button("Mirror screen") { host.startView(1) }
                Button("Mobile desktop") { host.startView(2) }
                Spacer()
            }
            .disabled(daemon.status?.connected != true)

            Divider()
            HStack {
                Text("Apps from the phone").font(.headline)
                Spacer()
                Button {
                    host.requestApps()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .disabled(daemon.status?.connected != true)
            }
            if !host.apps.isEmpty {
                TextField("Search", text: _search.projectedValue)
                    .textFieldStyle(.roundedBorder)
            }
            // One shared scroll (the merged tab's outer ScrollView owns scrolling here; a nested
            // scroll pane with 100+ apps would trap the mouse wheel).
            LazyVStack(alignment: .leading, spacing: 6) {
                if !host.streamList.isEmpty {
                    Text("Running streams").font(.headline).padding(.top, 2)
                    ForEach(host.streamList, id: \.sid) { s in
                        HStack(spacing: 8) {
                            Image(systemName: "rectangle.inset.bottomleft.filled")
                                .foregroundStyle(.secondary)
                            Text(s.title).lineLimit(1)
                            Spacer()
                            Button("Close") { host.closeStream(s.sid) }
                        }
                        .font(.callout)
                    }
                    Divider().padding(.vertical, 8)
                }
                if host.apps.isEmpty {
                    Text(daemon.status?.connected == true
                         ? "No app list yet — the phone sends it shortly after connecting; Refresh asks again."
                         : "Connect the phone to load its apps.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(filtered, id: \.key) { app in
                        HStack(spacing: 10) {
                            if let img = StreamHost.iconImage(app.iconName) {
                                Image(nsImage: img)
                                    .resizable()
                                    .frame(width: 28, height: 28)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            } else {
                                Image(systemName: "app").frame(width: 16)
                                    .foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.work ? "\(app.name) · work profile" : app.name).lineLimit(1)
                                Text(app.pkg).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("Open") { host.startApp(app) }
                        }
                        .font(.callout)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 12)
        }
        .padding(8)
        .onAppear { host.requestAppsIfStale() }
    }
}

struct PhoneView: View {
    private var _daemon: EnvironmentObject<DaemonClient> = EnvironmentObject()
    private var daemon: DaemonClient { _daemon.wrappedValue }
    private var _showPairing: State<Bool> = State(initialValue: false)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: daemon.status?.connected == true ? "iphone.radiowaves.left.and.right" : "iphone.slash")
                    .font(.system(size: 28))
                    .foregroundStyle(daemon.status?.connected == true ? .green : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(daemon.status?.name ?? "No phone paired").font(.title2.bold())
                    Text(daemon.status?.connected == true ? (daemon.status?.model ?? "Connected") : "Not connected")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let s = daemon.status {
                HStack(spacing: 24) {
                    InfoTile(title: "Battery", value: s.battery.map { "\($0)%" } ?? "—", icon: "battery.75")
                    InfoTile(title: "Wi-Fi", value: s.wifi ? "On" : "Off", icon: "wifi")
                    InfoTile(title: "Bluetooth", value: s.bluetooth ? "On" : "Off", icon: "dot.radiowaves.left.and.right")
                    InfoTile(title: "Unread", value: s.unread.map(String.init) ?? "—", icon: "bell")
                }
            }

            HStack {
                Button(daemon.status?.connected == true ? "Disconnect" : "Connect") {
                    daemon.status?.connected == true ? daemon.disconnect() : daemon.connect()
                }
                .keyboardShortcut(.defaultAction)
                Button("Pair new phone…") {
                    _showPairing.wrappedValue = true
                    daemon.pair()
                }
                Spacer()
                if daemon.online {
                    Label("Daemon running", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("Daemon not running", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            if let message = daemon.lastMessage, !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }

            Divider()
            Text("PC address: \(daemon.status?.pcAddress ?? "—") · Phone: \(daemon.status?.phoneAddress ?? "—")")
                .font(.caption).foregroundStyle(.secondary)
            Text("Pairing QR is served on TCP 52020 and advertised over Bonjour as _readyformdns._tcp.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(8)
        .sheet(isPresented: _showPairing.projectedValue) {
            PairingView(payload: daemon.status?.pairingPayload)
                .frame(width: 460, height: 560)
        }
    }
}

/// A dummy Motorola Edge 70 for the Phone tab: the phone's body shape, its punch-hole camera and
/// home indicator, and inside it the phone's own wallpaper (service 25 `cmd 2`; the daemon saves
/// it under the runtime dir and publishes the path as `wallpaper` in the status), a live clock and
/// the battery/Wi-Fi/unread bits the daemon tracks. Replaces the plain phone logo.
struct Edge70PhoneView: View {
    private var _daemon: EnvironmentObject<DaemonClient> = EnvironmentObject()
    private var daemon: DaemonClient { _daemon.wrappedValue }

    /// The edge 70's screen is 1220 x 2712 px (the mirror's native capture); the card keeps that
    /// aspect so the phone looks like the phone.
    private static let screenAspect: CGFloat = 2712.0 / 1220.0
    private static let width: CGFloat = 200
    private static let bezel: CGFloat = 7
    static let timeText: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private var wallpaper: NSImage? {
        guard let raw = daemon.status?.wallpaper else { return nil }
        // The daemon appends `?md5` for its own QML cache busting; load the real path.
        let path = raw.split(separator: "?").first.map(String.init) ?? raw
        return NSImage(contentsOfFile: path)
    }

    var body: some View {
        VStack(spacing: 6) {
            TimelineView(.periodic(from: Date.now, by: 5)) { context in
                screen(context.date)
                    .id(daemon.status?.wallpaper) // the daemon busts the cache with `?md5`
            }
            Text("Motorola edge 70").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func screen(_ date: Date) -> some View {
        let inner = Self.width - Self.bezel * 2
        let h = inner * Self.screenAspect + Self.bezel * 2
        return ZStack {
            if let img = wallpaper {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                LinearGradient(stops: [
                    .init(color: Color(white: 0.3), location: 0),
                    .init(color: .black, location: 1),
                ], startPoint: .top, endPoint: .bottom)
                VStack(spacing: 4) {
                    Image(systemName: daemon.status?.connected == true ? "iphone" : "iphone.slash")
                        .font(.system(size: 30))
                        .foregroundStyle(.white.opacity(0.65))
                    Text(daemon.status?.connected == true
                         ? "Wallpaper arrives from the phone"
                         : "Connect the phone to see its wallpaper")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }

            if daemon.status?.connected == true || wallpaper != nil {
                // Lock-screen clock (a modern Android screen with the time over the wallpaper).
                VStack(spacing: 2) {
                    Text(Self.timeText.string(from: date))
                        .font(.system(size: 40, weight: .medium, design: .default))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
                    VStack(spacing: 0) {
                        if let s = daemon.status, let unread = s.unread, unread > 0 {
                            Text("\(unread) unread").font(.caption2).foregroundStyle(.white.opacity(0.85))
                                .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                        }
                    }.padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 46)

                // Status bar.
                HStack(spacing: 5) {
                    Text(String(Self.timeText.string(from: date).dropLast(3)))
                        .font(.system(size: 10, weight: .medium))
                    Spacer()
                    if daemon.status?.wifi == true {
                        Image(systemName: "wifi").font(.system(size: 9))
                    }
                    if let s = daemon.status, let b = s.battery {
                        Image(systemName: s.charging ? "bolt" : (b > 50 ? "battery.75" : "battery.25"))
                            .font(.system(size: 10))
                        Text("\(b)%").font(.system(size: 9, weight: .medium))
                    }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 14)

                // Home gesture bar.
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white.opacity(0.85))
                    .frame(width: 56, height: 4)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 8)
            }

            // Punch-hole camera, top center like the edge 70.
            Circle()
                .fill(Color(white: 0.05))
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .frame(width: 14, height: 14)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 33, style: .continuous)
                .fill(LinearGradient(stops: [
                    .init(color: Color(white: 0.24), location: 0),
                    .init(color: Color(white: 0.12), location: 1),
                ], startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                .padding(-Self.bezel)
        )
        .frame(width: Self.width, height: h)
        .overlay(
            RoundedRectangle(cornerRadius: 33, style: .continuous)
                .strokeBorder(.black.opacity(0.55), lineWidth: 1)
                .padding(-Self.bezel)
        )
    }
}

struct InfoTile: View {
    let title: String
    let value: String
    let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit())
        }
        .frame(minWidth: 90, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

struct PairingView: View {
    let payload: String?
    private var _dismiss = Environment(\.dismiss)

    var body: some View {
        VStack(spacing: 14) {
            Text("Pair with Smart Connect").font(.title2.bold())
            Text("On the phone, open Smart Connect, tap +, and scan this code.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let payload, let image = QRCode.image(for: payload) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 300, height: 300)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white))
            } else {
                ProgressView("Waiting for the daemon…").frame(width: 300, height: 300)
            }
            Text("The code refreshes every few minutes.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Copy payload") {
                    if let payload {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(payload, forType: .string)
                    }
                }
                Button("Done") { _dismiss.wrappedValue() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }
}

enum QRCode {
    static func image(for payload: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

struct NotificationsView: View {
    private var _daemon: EnvironmentObject<DaemonClient> = EnvironmentObject()
    private var daemon: DaemonClient { _daemon.wrappedValue }
    private var _replying: State<PhoneNotification?> = State(initialValue: nil)
    private var replying: PhoneNotification? {
        get { _replying.wrappedValue }
        nonmutating set { _replying.wrappedValue = newValue }
    }
    private var _replyText: State<String> = State(initialValue: "")
    private var replyText: String {
        get { _replyText.wrappedValue }
        nonmutating set { _replyText.wrappedValue = newValue }
    }

    var body: some View {
        let all = daemon.recentNotifications
        let fresh = all.filter { !daemon.handledKeys.contains($0.key) }
        let handled = all.filter { daemon.handledKeys.contains($0.key) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Phone notifications").font(.title2.bold())
                Spacer()
                if !handled.isEmpty {
                    Button("Clear handled") { daemon.removeAllHandled() }
                        .controlSize(.small)
                }
            }
            if all.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bell.slash").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text("No notifications").font(.headline)
                    Text("Notifications from the phone appear here while it is connected.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Untouched notifications stay on top; the opened/replied/dismissed ones move to
                // an "Earlier" section and stay listed until cleared.
                List {
                    if !fresh.isEmpty {
                        Section("New") {
                            ForEach(fresh) { note in
                                noteRow(note, isHandled: false)
                            }
                        }
                    }
                    if !handled.isEmpty {
                        Section("Earlier (opened, replied to or dismissed)") {
                            ForEach(handled) { note in
                                noteRow(note, isHandled: true)
                            }
                        }
                    }
                }
            }
        }
        .padding(8)
        .sheet(item: _replying.projectedValue) { note in
            VStack(alignment: .leading, spacing: 12) {
                Text(note.title).font(.headline)
                Text(note.body).font(.callout).foregroundStyle(.secondary).lineLimit(6)
                TextField("Reply…", text: _replyText.projectedValue, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)
                HStack {
                    Spacer()
                    Button("Cancel") { replying = nil }
                    Button("Send") {
                        daemon.reply(key: note.key, text: replyText)
                        replying = nil
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 420)
        }
    }

    private func noteRow(_ note: PhoneNotification, isHandled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(isHandled ? note.app + " · handled" : note.app)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isHandled {
                    Button {
                        daemon.removeNote(key: note.key)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                } else {
                    if note.replyable {
                        Button("Reply") {
                            replying = note
                            replyText = ""
                        }
                        .buttonStyle(.link)
                    }
                    Button("Open") {
                        daemon.openOnPhone(key: note.key, service: note.service, app: note.app, pkg: note.pkg)
                    }
                    .buttonStyle(.link)
                }
            }
            Text(note.title).font(isHandled ? .callout : .headline)
            Text(note.body).font(.callout).foregroundStyle(.secondary).lineLimit(4)
        }
        .opacity(isHandled ? 0.6 : 1)
        .padding(.vertical, 4)
    }
}

// NOTE: The manual State / EnvironmentObject wrappers below are required by the Command Line
// Tools toolchain, which has no SwiftUI attribute macros.

/// One-time-code extraction for Messages: the keyword (otp/passcode/password/pin/code) has to
/// appear within 40 characters before the first 4-8 digit group (spaces and single dashes inside
/// are tolerated), or the whole body is just the code. Transaction ids and dates don't match
/// because they lack the keyword. Verified patterns: "verification code is 123456", "OTP 9724",
/// a bare "123456", "123 456", "code expires in 10 min: 7-8-1-2", "otp: 482-913", "PIN 9911";
/// rejected: "txn 998877", "meet at 5 near gate 4", "555-77 is reserved for help".
enum OTPFinder {
    static func otp(in text: String) -> String? {
        guard text.count < 600 else { return nil }
        func normalize(_ raw: String) -> String? {
            let digits = raw.filter(\.isNumber)
            return (4...8).contains(digits.count) ? digits : nil
        }
        guard let keyword = try? NSRegularExpression(pattern: "(?i)(otp|passcode|password|pin|code)"),
              let group = try? NSRegularExpression(pattern: "[0-9][0-9 -]{2,9}[0-9]") else { return nil }
        let full = NSRange(text.startIndex..., in: text)
        var kwEnds: [Int] = []
        keyword.enumerateMatches(in: text, options: [], range: full) { m, _, _ in
            if let m { kwEnds.append(m.range.upperBound) }
        }
        var found: String?
        group.enumerateMatches(in: text, options: [], range: full) { m, _, stop in
            guard let m, let range = Range(m.range, in: text) else { return }
            let start = m.range.location
            guard kwEnds.contains(where: { start - $0 <= 40 && start >= $0 - 2 }) else { return }
            if let code = normalize(String(text[range])) {
                found = code
                stop.pointee = true
            }
        }
        if let found { return found }
        if let bare = try? NSRegularExpression(pattern: "^[0-9][0-9 -]{2,9}[0-9]$"),
           let m = bare.firstMatch(in: text, options: [], range: full),
           let range = Range(m.range, in: text),
           let code = normalize(String(text[range])) {
            return code
        }
        return nil
    }

    static func copyToPasteboard(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }
}

/// Renders a message body as an `AttributedString` with tappable links (blue + underlined, the
/// hyperlink convention). Sent bubbles keep white text on the accent background, so their links
/// stay white with an underline instead of blue-on-blue.
enum LinkText {
    static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func body(_ text: String, sent: Bool) -> AttributedString {
        let color = NSColor(sent ? Color.white : Color.blue)
        let attr = NSMutableAttributedString(string: text)
        if let detector,
           text.count < 2000 {
            let full = NSRange(text.startIndex..., in: text)
            for m in detector.matches(in: text, range: full) {
                guard let url = m.url,
                      url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" else { continue }
                attr.addAttribute(.link, value: url, range: m.range)
                attr.addAttribute(.foregroundColor, value: color, range: m.range)
                attr.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: m.range)
            }
        }
        return (try? AttributedString(attr, including: \.appKit)) ?? AttributedString(text)
    }
}

struct SMSThreadsReply: Codable {
    var ok: Bool?
    var enabled: Bool?
    var message: String?
}

/// One message in a conversation, as kept by the daemon (`Msg` in `src/sms.rs`).
struct SMSMsg: Hashable {
    var id: Int
    var kind: Int
    var sent: Bool
    var body: String
    var date: Int
    var read: Bool

    /// `messageType`: 1 = received, 2 = sent (the phone's own encoding).
    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? Int, let body = d["body"] as? String else { return nil }
        self.id = id
        self.kind = (d["kind"] as? Int) ?? 1
        self.sent = (d["message_type"] as? Int) == 2
        self.body = body
        self.date = (d["date"] as? Int) ?? Int((d["date"] as? Double) ?? 0)
        self.read = (d["read"] as? Int).map { $0 != 0 } ?? (d["read"] as? Bool) ?? true
    }
}

/// The Messages page (the Windows app's Messages): the phone's SMS grouped in conversations.
/// The daemon folds the flat wire beans into `sms_state`; the page talks to it through the
/// `sms_threads` / `sms_thread` / `sms_send` / `sms_mark_read` control commands. MMS bodies are
/// included; media parts are not shown yet.
struct MessagesView: View {
    private var _daemon: EnvironmentObject<DaemonClient> = EnvironmentObject()
    private var daemon: DaemonClient { _daemon.wrappedValue }

    private var _threads: State<[[String: Any]]> = State(initialValue: [])
    private var threads: [[String: Any]] { _threads.wrappedValue }
    private var _selected: State<String?> = State(initialValue: nil)
    private var selected: String? { _selected.wrappedValue }
    private var _messages: State<[SMSMsg]> = State(initialValue: [])
    private var messages: [SMSMsg] { _messages.wrappedValue }
    private var _draft: State<String> = State(initialValue: "")
    private var draft: String { _draft.wrappedValue }
    private var _error: State<String?> = State(initialValue: nil)
    private var error: String? {
        get { _error.wrappedValue }
        nonmutating set { _error.wrappedValue = newValue }
    }
    private var _copiedId: State<Int?> = State(initialValue: nil)
    private var copiedId: Int? { _copiedId.wrappedValue }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Messages").font(.title2.bold())
                Spacer()
                if let message = error, !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
                Button {
                    Task { await refreshThreads() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(daemon.status?.connected != true)
            }

            if daemon.status?.connected != true {
                Text("Connect the phone to load its SMS.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    threadList
                        .frame(width: 252)
                    Divider()
                    chatPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(minHeight: 340)
                .frame(maxHeight: .infinity)
            }
        }
        .padding(8)
        .onAppear { Task { await refreshThreads(); await refreshThread() } }
        .onChange(of: daemon.status?.connected == true) { connected in
            guard connected else { return }
            Task { await refreshThreads(); await refreshThread() }
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            guard daemon.status?.connected == true else { return }
            Task { await refreshThreads(); await refreshThread() }
        }
    }

    // MARK: conversations

    private var threadList: some View {
        ScrollView {
            if threads.isEmpty {
                Text(enabledText)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 12)
            } else {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(threads.indices, id: \.self) { i in
                        threadRow(threads[i])
                            .id(i)
                    }
                }
            }
        }
    }

    private var enabledText: String {
        // The daemon sends `cmd 18` (PC ready) on the first sync, which enables Messages for this
        // PC if the phone has the permission; then the beans flow in.
        "No conversations yet. Refresh asks the phone for its SMS the first time, which also enables Messages for this PC (the phone may show an allow prompt)."
    }

    private func threadRow(_ t: [String: Any]) -> some View {
        let key = (t["thread"] as? String) ?? ""
        let selectedRow = selected == key
        let unread = (t["unread"] as? Int) ?? 0
        return Button {
            _selected.wrappedValue = key
            Task { await refreshThread() }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(t["name"] as? String ?? t["address"] as? String ?? key)
                            .font(.system(.callout, design: .default, weight: .medium))
                            .lineLimit(1)
                        if unread > 0 {
                            Text("\(unread)")
                                .font(.caption2).fontWeight(.semibold)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor))
                        }
                        Spacer(minLength: 0)
                        Text(lastDate(t))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(t["last_body"] as? String ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selectedRow ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.03))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    private func lastDate(_ t: [String: Any]) -> String {
        if let d = t["last_date"] as? Int, d > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(d) / 1000)
            return Self.dateFmt.string(from: date)
        }
        return ""
    }

    // MARK: conversation

    private var chatPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let key = selected {
                chatHeader(key)
                Divider()
                bubbleList(key)
                Divider()
                composer(key)
            } else if threads.isEmpty {
                Text(pickFirstHint)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            } else {
                Text("Choose a conversation on the left or press New to text a number.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }

    private var pickFirstHint: String {
        "Waiting for the phone's SMS (the first sync may take a few seconds)."
    }

    private func chatHeader(_ key: String) -> some View {
        let t = threads.first { ($0["thread"] as? String) == key }
        return HStack(spacing: 10) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(t?["name"] as? String ?? (t?["address"] as? String) ?? key)
                    .font(.system(.callout, design: .default, weight: .medium))
                if t?["name"] == nil, let addr = t?["address"] as? String, !addr.isEmpty {
                    Text(addr).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func bubbleList(_ key: String) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                if messages.isEmpty {
                    Text("No cached messages for this conversation yet (Refresh re-syncs the phone).")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 12)
                } else {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        // Copy the newest code with one tap (it is usually what you came for).
                        if let last = messages.last, !last.sent, let code = OTPFinder.otp(in: last.body) {
                            HStack(spacing: 8) {
                                Image(systemName: "lock_shield")
                                    .foregroundStyle(Color.accentColor)
                                Text("Code from this number: \(code)")
                                    .font(.callout).fontWeight(.medium)
                                Spacer()
                                Button {
                                    OTPFinder.copyToPasteboard(code)
                                    _copiedId.wrappedValue = last.id
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        if _copiedId.wrappedValue == last.id { _copiedId.wrappedValue = nil }
                                    }
                                } label: {
                                    Label(copiedId == last.id ? "Copied" : "Copy code",
                                          systemImage: copiedId == last.id ? "checkmark" : "doc.on.doc")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.accentColor.opacity(0.10)))
                        }
                        ForEach(messages, id: \.self) { m in
                            bubble(m)
                                .id(m.id)
                        }
                    }
                    .padding(10)
                }
            }
            .onChange(of: messages.count) { _ in
                if let last = messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func bubble(_ m: SMSMsg) -> some View {
        HStack {
            if m.sent { Spacer(minLength: 60) }
            VStack(alignment: m.sent ? .trailing : .leading, spacing: 2) {
                Text(LinkText.body(m.body, sent: m.sent))
                    .font(.callout)
                    .environment(\.openURL, OpenURLAction { url in
                        NSWorkspace.shared.open(url)
                        return .handled
                    })
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(
                        m.sent ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.08)))
                    .foregroundStyle(m.sent ? Color.white : Color.primary)
                HStack(spacing: 6) {
                    Text(Self.dateFmt.string(from: Date(timeIntervalSince1970: TimeInterval(m.date) / 1000)))
                        .font(.caption2).foregroundStyle(.secondary)
                    if let code = OTPFinder.otp(in: m.body) {
                        Button {
                            OTPFinder.copyToPasteboard(code)
                            _copiedId.wrappedValue = m.id
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                if _copiedId.wrappedValue == m.id { _copiedId.wrappedValue = nil }
                            }
                        } label: {
                            Label(copiedId == m.id ? "Copied" : code,
                                  systemImage: copiedId == m.id ? "checkmark" : "doc.on.doc")
                                .font(.caption2).fontWeight(.medium)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(copiedId == m.id ? .green : .accentColor)
                    }
                }
            }
            if !m.sent { Spacer(minLength: 60) }
        }
    }

    private func composer(_ key: String) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Text message…", text: _draft.projectedValue, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .onSubmit { Task { await sendDraft(key) } }
            Button {
                Task { await sendDraft(key) }
            } label: {
                Image(systemName: "paperplane.fill")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(10)
    }

    // MARK: actions

    private func refreshThreads() async {
        let r = await requestJSON(["cmd": "sms_threads"])
        if r["ok"] as? Bool == true {
            _threads.wrappedValue = r["threads"] as? [[String: Any]] ?? []
        } else {
            error = r["message"] as? String
        }
    }

    private func refreshThread() async {
        guard let key = selected else { return }
        let r = await requestJSON(["cmd": "sms_thread", "thread": key])
        guard r["ok"] as? Bool == true else {
            error = r["message"] as? String
            return
        }
        _error.wrappedValue = nil
        let loaded = (r["messages"] as? [[String: Any]] ?? []).compactMap(SMSMsg.init)
        _messages.wrappedValue = loaded
        // Opening a conversation marks its received messages as read on the phone.
        let unreadIds = loaded.filter { !$0.read && !$0.sent }.map(\.id)
        if !unreadIds.isEmpty {
            for id in unreadIds {
                _ = await requestJSON(["cmd": "sms_mark_read", "id": id])
            }
            _messages.wrappedValue = loaded.map { m in
                var v = m
                if !v.read && !v.sent { v.read = true }
                return v
            }
        }
    }

    private func sendDraft(_ key: String) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let r = await requestJSON(["cmd": "sms_send", "thread": key, "text": text])
        if r["ok"] as? Bool == true {
            _draft.wrappedValue = ""
            // The phone acks (cmd 5), stores and sends; give it a moment, then re-read the thread.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await refreshThread()
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await refreshThread()
        } else {
            error = r["message"] as? String
        }
    }

    private func requestJSON(_ obj: [String: Any]) async -> [String: Any] {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let line = String(data: data, encoding: .utf8) else {
            return ["ok": false, "message": "could not encode command"]
        }
        return await daemon.request(line)
    }
}

struct SettingsView: View {
    private var _daemon: EnvironmentObject<DaemonClient> = EnvironmentObject()
    private var daemon: DaemonClient { _daemon.wrappedValue }
    private var _launchAtLogin: State<Bool> = State(initialValue: SMAppService.mainApp.status == .enabled)
    private var launchAtLogin: Bool {
        get { _launchAtLogin.wrappedValue }
        nonmutating set { _launchAtLogin.wrappedValue = newValue }
    }
    private var _showInDock: State<Bool> = State(initialValue: UserDefaults.standard.bool(forKey: "showInDock"))
    private var showInDock: Bool {
        get { _showInDock.wrappedValue }
        nonmutating set {
            _showInDock.wrappedValue = newValue
            UserDefaults.standard.set(newValue, forKey: "showInDock")
        }
    }
    private var _allTiles: State<Bool> = State(initialValue: UserDefaults.standard.bool(forKey: "allTiles"))
    private var allTiles: Bool {
        get { _allTiles.wrappedValue }
        nonmutating set { _allTiles.wrappedValue = newValue }
    }
    private var _error: State<String?> = State(initialValue: nil)
    private var error: String? {
        get { _error.wrappedValue }
        nonmutating set { _error.wrappedValue = newValue }
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Start SmartConnect at login", isOn: _launchAtLogin.projectedValue)
                    .onChange(of: launchAtLogin) { enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            self.error = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section("Appearance") {
                Toggle("Show SmartConnect in the Dock", isOn: _showInDock.projectedValue)
                    .onChange(of: showInDock) { on in
                        // Takes effect immediately; also saved for the next launch.
                        NSApp.setActivationPolicy(on ? .regular : .accessory)
                    }
                Text("When off, SmartConnect lives in the menu bar only (its current behaviour). When on, it also gets a Dock tile — closing the window then hides to the Dock instead of only the menu bar. The Dock icon also gives it a second way to reopen the window: clicking the tile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Experimental") {
                Toggle("Advertise every phone feature tile", isOn: _allTiles.projectedValue)
                    .onChange(of: allTiles) { on in
                        UserDefaults.standard.set(on, forKey: "allTiles")
                        // The tile map is fixed at daemon start, so the daemon has to restart
                        // for this to show up; the phone reconnects on its own.
                        AppDelegate.shared?.restartDaemon()
                    }
                Text("Shows every tile the phone can draw — Screen share, Mobile desktop, Webcam, App streaming, Clipboard sync, Cross Control, PC lock and Hotspot. Taps of features this port can't answer wait about 20 s on the phone and time out; the mobile-desktop tile may trigger a screen-capture consent prompt. Takes effect when the daemon restarts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Data") {
                LabeledContent("State folder") {
                    Button(Paths.appSupport.path) {
                        NSWorkspace.shared.open(Paths.appSupport)
                    }
                    .buttonStyle(.link)
                }
                LabeledContent("Daemon") {
                    Text(daemon.online ? "running" : "stopped")
                        .foregroundStyle(daemon.online ? .green : .orange)
                }
                LabeledContent("Logs") {
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([Paths.daemonLog])
                    }
                    .buttonStyle(.link)
                }
            }
            Section("This port") {
                Text("Pairing, connection, notifications, clipboard, SMS, PC lock and hotspot are implemented. The phone shows tiles for PC lock, Hotspot, Clipboard sync, App streaming and Screen share / Mobile desktop; the *Streams* tab can start and close streams from the PC. Cross Control, phone-as-display and the virtual webcam are not part of this release; show their tiles with the switch above (their taps time out). Screen share streams with video and input verified on a device through the *Screen share* tile.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Bluetooth: desktop-side wake works. macOS cannot put custom service data in a BLE advertisement, so first-time pairing may need the phone's app in the foreground.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(8)
    }
}

// MARK: - Stream host (App streaming + Screen share / Mobile desktop)

// Port of the `smartconnect-mirror --host` control plane (`upstream-linux/mirror`) into the
// menu-bar app: the phone offers H.264 over standard WebRTC, a WKWebView window answers it, and
// all signalling travels the daemon's control socket (`watch` in, `send` out; one JSON line per
// frame). Screen share / Mobile desktop first answers service 1 `cmd 0`, then both flows use
// service 15 for the stream and service 16 for input. References: docs/protocol/mirroring.md and
// docs/protocol/app-streaming.md. Status: implemented, **not yet verified on a device**.

/// The only candidates usable with the phone are UDP host candidates on our LAN. Same precedence
/// as upstream `mirror/src/ice.rs`: `SMARTCONNECT_ICE_ADDRESSES` overrides everything, then the
/// daemon's `pcAddress` (the address the phone reached us on), then private IPv4 addresses.
struct StreamIceFilter {
    private enum Mode {
        case any               // env "all" / "*" → every UDP candidate
        case list([String])    // exact IPv4s and CIDRs, e.g. "192.168.1.0/24,10.0.0.0/8"
        case address(String)
        case privateLan
    }
    private let mode: Mode

    static func current(pcAddress: String?) -> StreamIceFilter {
        let env = ProcessInfo.processInfo.environment["SMARTCONNECT_ICE_ADDRESSES"]?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !env.isEmpty {
            let entries = env.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
            if let first = entries.first, first.lowercased() == "all" || first == "*" {
                return StreamIceFilter(mode: .any)
            }
            return StreamIceFilter(mode: .list(entries.filter { !$0.isEmpty }))
        }
        let pc = (pcAddress ?? "").trimmingCharacters(in: .whitespaces)
        return StreamIceFilter(mode: pc.isEmpty ? .privateLan : .address(pc))
    }

    /// Candidate line: `candidate:<foundation> <component> <transport> <priority> <address> <port> typ …`
    func allows(_ candidate: String) -> Bool {
        let trimmed = candidate.hasPrefix("a=") ? String(candidate.dropFirst(2)) : candidate
        let fields = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 5, fields[0].hasPrefix("candidate:"),
              fields[2].lowercased() == "udp" else { return false }
        let address = fields[4]
        switch mode {
        case .any: return true
        case .address(let pc): return address == pc
        case .privateLan: return StreamIceFilter.isPrivateIPv4(address)
        case .list(let entries): return entries.contains { StreamIceFilter.entryMatches($0, address) }
        }
    }

    private static func entryMatches(_ entry: String, _ address: String) -> Bool {
        guard entry.contains("/") else { return entry == address }
        let bits = Int(entry.split(separator: "/").last ?? "") ?? 0
        guard bits >= 0, bits <= 32,
              let base = entry.split(separator: "/").first.map(String.init),
              let a = ipv4(base), let c = ipv4(address) else { return false }
        let mask: UInt32 = bits == 0 ? 0 : (~UInt32(0) << (32 - UInt32(bits)))
        return (c & mask) == (a & mask)
    }

    private static func ipv4(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var out: UInt32 = 0
        for p in parts {
            guard let o = UInt32(p), o <= 255 else { return nil }
            out = (out << 8) | o
        }
        return out
    }

    private static func isPrivateIPv4(_ s: String) -> Bool {
        guard let addr = ipv4(s) else { return false }
        let o1 = addr >> 24, o2 = (addr >> 16) & 0xFF
        return o1 == 10 || (o1 == 172 && (16...31).contains(o2)) || (o1 == 192 && o2 == 168)
    }

    var label: String {
        switch mode {
        case .any: return "all (env)"
        case .address: return "pcAddress"
        case .privateLan: return "private LAN"
        case .list: return "explicit list (env)"
        }
    }
}

/// One streamed view or app, keyed by its `sessionId`.
@MainActor
final class StreamSession {
    let sid: Int64
    let pkg: String
    /// Echoed back in `cmd 4`, `cmd 20` and the close; may be a JSON null as received.
    let userId: Any
    let cmp: Any?
    let shortcutId: Any?
    var name: String?
    let isView: Bool
    private(set) var mid = ""
    private(set) var answered = false
    private(set) var displayId: Int64?
    private(set) var capRequested: Set<Int> = []
    private(set) var stream: (Int, Int)?
    private(set) var closing = false
    /// Modifier keys the webview reports as held (with the flags they were pressed with);
    /// released before the closing `cmd 7` so the phone is not left with stuck keys.
    private(set) var heldMods: [(key: Int, flags: Int)] = []
    /// Local candidates that arrived before the answer went out; flushed right after `cmd 4`.
    private(set) var pendingLocal: [(mLine: Int, candidate: String)] = []
    /// Offer awaiting the page's ready signal.
    var pendingOffer: String?
    private(set) var window: StreamWindow?

    init(sid: Int64, pkg: String, userId: Any, cmp: Any?, shortcutId: Any?, name: String?, isView: Bool) {
        self.sid = sid
        self.pkg = pkg
        self.userId = userId
        self.cmp = cmp
        self.shortcutId = shortcutId
        self.name = name
        self.isView = isView
    }

    var windowTitle: String {
        if isView {
            return ["mirror": "Phone — Smart Connect", "desktop": "Mobile desktop — Smart Connect",
                    "mobile": "Virtual phone — Smart Connect"][pkg] ?? "\(pkg) — Phone"
        }
        return "\(name ?? pkg) — Phone"
    }

    /// Records the display id and asks the phone, once per display, for a virtual
    /// keyboard + mouse (svc 16 REQUEST_CAP, caps bit0 keyboard | bit1 mouse).
    func learnDisplay(_ body: [String: Any]) {
        guard let d = StreamValue.int(body["displayId"]), d >= 0 else { return }
        let first = !capRequested.contains(d)
        displayId = Int64(d)
        capRequested.insert(d)
        if first {
            NSLog("SmartConnect: stream \(sid) (\(pkg)): input: requesting keyboard+mouse on display \(d)")
            StreamHost.shared.input16(1, ["ver": 1, "displayId": d, "caps": 3])
        }
        StreamHost.shared.pushDisplay(self)
    }

    func learnStreamSize(_ body: [String: Any]) {
        if let w = StreamValue.int(body["width"]), let h = StreamValue.int(body["height"]),
           w > 0, h > 0 {
            stream = (w, h)
        }
    }

    func noteAnswer(mid: String) {
        self.mid = mid
        answered = true
    }

    func noteMods(_ held: [[String: Any]]) {
        heldMods = held.compactMap { entry in
            guard let key = StreamValue.int(entry["key"]) else { return nil }
            return (key, StreamValue.int(entry["flags"]) ?? 0)
        }
    }

    func noteLocalCandidate(mLine: Int, candidate: String) {
        pendingLocal.append((mLine, candidate))
    }

    /// Closes the window. When we initiated the close, release held phone keys and send cmd 7
    /// first (the phone releases the virtual display on cmd 7; a phone-initiated close must not
    /// be answered with one).
    func close(why: String, tellPhone: Bool) {
        guard !closing else { return }
        closing = true
        NSLog("SmartConnect: stream \(sid) (\(pkg)) closing: \(why)")
        if tellPhone {
            for mod in heldMods {
                StreamHost.shared.input16(3, ["displayId": Int(displayId ?? 0), "flags": mod.flags,
                                              "key": mod.key, "down": false, "metaState": 0])
            }
            heldMods = []
            StreamHost.shared.send15(7, ["sessionId": Int(sid), "error": 0])
        }
        window?.closeWindowOnly()
    }

    func attach(window: StreamWindow, offer: String) {
        self.window = window
        pendingOffer = offer
    }

    func raise() {
        window?.makeKeyAndOrderFront()
    }
}

enum StreamValue {
    static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }
}

@MainActor
final class StreamHost: NSObject, WKScriptMessageHandler, ObservableObject {
    static let shared = StreamHost()
    nonisolated let objectWillChange = ObservableObjectPublisher()

    /// One launchable app from the service 17 app list (docs/protocol/app-streaming.md#service-17).
    struct StreamApp {
        let pkg: String
        let name: String
        let userId: Int64
        let cmp: String
        let iconName: String
        let work: Bool
        var key: String { "\(userId)|\(pkg)" }
    }

    private var started = false
    /// The phone's apps, shown on the Streams tab.
    private(set) var apps: [StreamApp] = []
    /// Last time the PC asked the phone for the app list; the surfaces auto-request at most
    /// every 5 minutes so opening the panel is instant from the cache, not a refresh ritual.
    private(set) var lastAppsRequest: Date?
    private var sessions: [Int64: StreamSession] = [:]
    private var lastHb: Date?
    /// The phone's desktop resolution, sent in its Screen-share/Mobile-desktop cmd 0 (view 2).
    private var viewResolution: (Int, Int)?
    /// The phone keeps a single pending start per PC: one cmd 1 at a time, 20 s timeout.
    private var inflight: (pkg: String, cmp: Any?, userId: Any, shortcutId: Any?, at: Date)?
    private var instanceId: Int64 = 0
    private var senderRef: StreamSender?

    /// The newest phone offer, exposed to the WebRTC SDP harness (`/offer.sdp` on the page
    /// server). Temporary debugging aid; removed once the media path is verified.
    // nonisolated(unsafe): written on the main actor, read from the page-server thread; a torn
    // read of a String reference is worse-case benign (either nil or a whole SDP string).
    nonisolated(unsafe) static var lastOfferSDP: String?
    private var harnessView: WKWebView?

    func start() {
        guard !started else { return }
        started = true
        instanceId = StreamHost.loadInstanceId()
        // Show the cached app list immediately; the fresh list replaces it when the phone answers.
        apps = StreamHost.loadAppsCache()
        if !apps.isEmpty {
            NSLog("SmartConnect: stream: showing \(apps.count) cached apps before the fresh list arrives")
        }
        watchLoop()
        heartbeatLoop()
        if CommandLine.arguments.contains("--webrtc-sdp-harness") {
            loadWebRTCHarness()
        }
    }

    /// WebRTC SDP debugging tool (`--webrtc-sdp-harness`): opens a visible test page that
    /// runs every phone offer through SDP-plan variants (plain / transceiver / unfiltered /
    /// self-offer) and reports `m=video` lines, ICE states and candidate counts. It answers
    /// why a given offer produces rejected or healthy answers — built while fixing the
    /// black-stream window; see docs/protocol/app-streaming.md#debug-tools.
    private func loadWebRTCHarness() {
        NSLog("SmartConnect: stream: SDP harness launching, pageServer=\(StreamPage.server != nil)")
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "bridge")
        config.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 400),
                             configuration: config)
        // The page MUST live in a real on-screen window: with no window WebKit treats the
        // content as invisible and suspends the web process (timers stop mid-harness).
        let win = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 640, height: 400),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "SmartConnect WebRTC test"
        win.contentView = view
        win.makeKeyAndOrderFront(nil)
        harnessView = view
        if let url = StreamPage.server?.testURL {
            view.load(URLRequest(url: url))
        } else {
            // Same fallback as a stream window; the offer is injected from the host below
            // (no `fetch` on a non-HTTP page).
            view.loadHTMLString(StreamPage.testHtml(), baseURL: nil)
        }
    }

    /// Hands the newest phone offer to the harness page (JSON string literal is fully escaped).
    private func pushOfferToHarness(_ offer: String) {
        guard let view = harnessView else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: [offer]),
              let text = String(data: data, encoding: .utf8) else { return }
        view.evaluateJavaScript("window.__setOffer && window.__setOffer(\(text)[0])")
    }

    // MARK: control-socket side

    nonisolated private func watchLoop() {
        DispatchQueue.global(qos: .utility).async {
            while true {
                if let fd = UnixSocket.connect(path: Paths.controlSocket, timeout: 0) {
                    UnixSocket.writeLine("{\"cmd\":\"watch\",\"services\":[1,15,16,17]}", to: fd)
                    while let line = UnixSocket.readLine(from: fd) {
                        guard let d = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                              let svc = obj["service"] as? Int, obj["data"] != nil else { continue }
                        let data = obj["data"]!
                        DispatchQueue.main.async { @MainActor in
                            StreamHost.shared.onFrame(service: svc, data: data)
                        }
                    }
                    close(fd)
                }
                // The daemon dropped us (restart or exit): tear everything down and reconnect.
                DispatchQueue.main.async { @MainActor in
                    StreamHost.shared.daemonWentAway()
                }
                Thread.sleep(forTimeInterval: 2)
            }
        }
    }

    /// One heartbeat covers every session: send cmd 9 every 30 s while sessions exist
    /// (the phone releases all sessions 35 s after the first answer's cmd 9, then re-arms
    /// a 65 s watchdog on every cmd 9; docs/protocol/mirroring.md#important-bookkeeping).
    private var heartbeatTimer: DispatchSourceTimer?
    private func heartbeatLoop() {
        guard heartbeatTimer == nil else { return }
        // A DispatchSourceTimer on the main queue, not an actor-inherited `Task.sleep` loop:
        // in practice the task-loop only fired the first beat per session and then went silent
        // (wire: one cmd 9 per session, then the phone's watchdog dropped the stream and the
        // video froze). The timer ticks every second; only the state below decides to send.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.heartbeatTick() }
        timer.resume()
        heartbeatTimer = timer
    }

    @MainActor private func heartbeatTick() {
        guard started else { return }
        if !sessions.isEmpty, lastHb == nil
                || Date().timeIntervalSince(lastHb!) >= 30 {
            send15(9, nil)
            lastHb = Date()
        }
        if !sessions.isEmpty && DaemonClient.shared.status?.connected != true {
            // The phone left (daemon disconnected it): drop the windows like on Linux.
            for s in Array(sessions.values) {
                sessions[s.sid] = nil
                s.close(why: "phone disconnected", tellPhone: false)
            }
            notify()
        }
    }

    /// The phone releases all sessions whenever a cmd 1 carries a different instanceId, so the
    /// id is persisted across app restarts (upstream: `smartconnect-mirror.instance`).
    static func loadInstanceId() -> Int64 {
        let dir = Paths.appSupport
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("smartconnect-mirror.instance")
        if let s = try? String(contentsOf: path, encoding: .utf8),
           let id = Int64(s.trimmingCharacters(in: .whitespacesAndNewlines)), id > 0 {
            return id
        }
        let id = max(1, Int64(Date().timeIntervalSince1970 * 1000))
        try? id.description.write(to: path, atomically: true, encoding: .utf8)
        return id
    }

    private func daemonWentAway() {
        for s in Array(sessions.values) {
            sessions[s.sid] = nil
            s.close(why: "daemon went away", tellPhone: false)
        }
        sessions.removeAll()
        inflight = nil
        lastHb = nil
    }

    // MARK: outbound (long-lived `send` connection with its reply drain)

    private func sender() -> StreamSender {
        if let senderRef { return senderRef }
        let s = StreamSender()
        senderRef = s
        return s
    }

    func send15(_ cmd: Int, _ data: Any?) {
        var msg: [String: Any] = ["ver": "1", "cmd": cmd]
        if let data { msg["data"] = data }
        sender().send(service: 15, payload: ["cmd": "send", "service": 15, "data": msg])
    }

    func input16(_ cmd: Int, _ data: [String: Any]) {
        sender().send(service: 16, payload: [
            "cmd": "send", "service": 16,
            "data": ["cmd": cmd, "data": data, "messageId": 0, "instanceId": 0],
        ])
    }

    // MARK: inbound frames

    private func onFrame(service: Int, data: Any) {
        guard let body = data as? [String: Any] else { return }
        switch service {
        case 1: onService1(body)
        case 15: onService15(body)
        case 17: onService17(body)
        default: break // 16: capability replies and pointer images are informational
        }
    }

    // MARK: service 1 — session control (docs/protocol/mirroring.md)

    private func onService1(_ body: [String: Any]) {
        let cmd = StreamValue.int(body["cmd"]) ?? -1
        if cmd == 0 {
            // The user started a view on the phone (Screen share → 1 or 3, Mobile desktop → 2);
            // the phone waits 20 s for our cmd 1, then invites the stream on svc 15.
            guard let view = StreamValue.int(body["view"]), [1, 2, 3].contains(view) else { return }
            if view == 2, let res = body["resolution"] as? [String: Any],
               let w = StreamValue.int(res["width"]), let h = StreamValue.int(res["height"]),
               w > 0, h > 0 {
                viewResolution = (w, h)
            }
            NSLog("SmartConnect: phone asks to start view \(view): accepting")
            sender().send(service: 1, payload: [
                "cmd": "send", "service": 1,
                "data": ["ver": "1.0.0", "cmd": 1, "view": view, "reply": 1, "drawerMode": false],
            ])
            return
        }
        // 5 = stop/cancel, 11 = error: the phone ended (or refused) the view. Close the view
        // windows locally; the phone already knows.
        if cmd == 5 || cmd == 11 {
            for s in Array(sessions.values) where StreamHost.isViewPkg(s.pkg) {
                closeSession(s.sid, why: "phone ended the view", tellPhone: false)
            }
        }
    }

    static func isViewPkg(_ pkg: String) -> Bool { pkg == "mirror" || pkg == "desktop" || pkg == "mobile" }

    private func notify() {
        objectWillChange.send()
    }

    // MARK: PC-initiated streams (the Streams tab)

    private func onService17(_ body: [String: Any]) {
        let cmd = StreamValue.int(body["cmd"]) ?? -1
        guard cmd == 1 else { return }
        var out: [StreamApp] = []
        for (list, work) in [(body["apps"], true), (body["wpApps"], false)] {
            guard let apps = list as? [[String: Any]] else { continue }
            for a in apps {
                guard let pkg = a["pkg"] as? String, !pkg.isEmpty else { continue }
                out.append(StreamApp(pkg: pkg,
                                     name: a["name"] as? String ?? pkg,
                                     userId: Int64(StreamValue.int(a["userId"]) ?? 0),
                                     cmp: a["cmp"] as? String ?? "",
                                     iconName: a["iconName"] as? String ?? "",
                                     work: work))
            }
        }
        apps = out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        StreamHost.saveAppsCache(apps)
        notify()
    }

    /// The phone sends its app list on every connection; `cmd 2` asks for it again.
    func requestApps() {
        guard DaemonClient.shared.status?.connected == true else { return }
        lastAppsRequest = Date.now
        NSLog("SmartConnect: stream: asking the phone for its app list again (svc 17 cmd 2)")
        sender().send(service: 17, payload: ["cmd": "send", "service": 17, "data": ["ver": "1", "cmd": 2]])
    }

    /// Auto-request for the Streams page / panel: visible on open, but no more often than every
    /// 5 minutes (the cached list is displayed immediately in between).
    func requestAppsIfStale() {
        guard DaemonClient.shared.status?.connected == true else { return }
        if apps.isEmpty || Date.now.timeIntervalSince(lastAppsRequest ?? .distantPast) > 300 {
            requestApps()
        }
    }

    /// The apps cache lives in the user cache dir, keyed the same way the rows render
    /// (`pkg`, `name`, `userId`, `cmp`, `iconName`, `work`); icons resolve from the daemon's
    /// icon cache so nothing binary goes in here.
    private static func saveAppsCache(_ apps: [StreamApp]) {
        let entries: [[String: Any]] = apps.map {
            ["pkg": $0.pkg, "name": $0.name, "userId": $0.userId, "cmp": $0.cmp, "iconName": $0.iconName, "work": $0.work]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: entries) else { return }
        try? data.write(to: Paths.appsCache, options: .atomic)
    }

    private static func loadAppsCache() -> [StreamApp] {
        guard let data = try? Data(contentsOf: Paths.appsCache),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { entry in
            guard let pkg = entry["pkg"] as? String, !pkg.isEmpty else { return nil }
            return StreamApp(pkg: pkg,
                             name: entry["name"] as? String ?? pkg,
                             userId: Int64((entry["userId"] as? Int) ?? 0),
                             cmp: entry["cmp"] as? String ?? "",
                             iconName: entry["iconName"] as? String ?? "",
                             work: (entry["work"] as? Bool) ?? false)
        }
    }

    /// Starts a whole-phone view from the PC: both the svc 1 `cmd 1` (ping `reply: 0` — an idle
    /// phone would read `reply: 1` as "cancelled") and the svc 15 peer start data
    /// (`source: 0`; the phone then sends the cmd 3 offer like for any other start).
    func startView(_ view: Int) {
        guard view >= 1, view <= 3 else { return }
        let pkg = ["mirror", "desktop", "mobile"][view - 1]
        if let existing = sessions.values.first(where: { $0.pkg == pkg }) { existing.raise(); return }
        guard DaemonClient.shared.status?.connected == true else { return }
        NSLog("SmartConnect: stream: PC starts view \(view) (\(pkg))")
        sender().send(service: 1, payload: [
            "cmd": "send", "service": 1,
            "data": ["ver": "1.0.0", "cmd": 1, "view": view, "reply": 0, "drawerMode": false],
        ])
        requestStart(pkg: pkg, cmp: nil, userId: 0, shortcutId: nil, source: 0, name: nil)
    }

    /// Opens one of the phone's apps in its own window (svc 15 `cmd 1`, `source: 0`,
    /// `cmp` from the app list). A tap on an already-streamed app just raises the window.
    func startApp(_ app: StreamApp) {
        if let existing = sessions.values.first(where: {
            $0.pkg == app.pkg && ($0.userId as? NSNumber)?.int64Value == app.userId
        }) {
            existing.raise()
            return
        }
        guard DaemonClient.shared.status?.connected == true else { return }
        NSLog("SmartConnect: stream: PC starts app \(app.pkg) (userId \(app.userId))")
        requestStart(pkg: app.pkg, cmp: app.cmp, userId: app.userId, shortcutId: nil, source: 0, name: app.name)
    }

    /// Closed from the Streams tab; like a user-closed window this owes the phone a cmd 7.
    func closeStream(_ sid: Int64) {
        closeSession(sid, why: "closed from the Streams tab", tellPhone: true)
    }

    var streamList: [(sid: Int64, title: String)] {
        sessions.values.sorted { $0.sid < $1.sid }.map { ($0.sid, $0.windowTitle) }
    }

    /// The daemon's icon cache; icon names are `<pkg>_<cmp>.png` (fex default on macOS:
    /// `~/Library/Caches/SmartConnect/app-icons`).
    static func iconImage(_ iconName: String) -> NSImage? {
        guard !iconName.isEmpty else { return nil }
        return NSImage(contentsOfFile: Paths.iconCache.appendingPathComponent(iconName).path)
    }

    // MARK: service 15 — stream setup (docs/protocol/app-streaming.md#commands)

    private func onService15(_ raw: [String: Any]) {
        // The phone's svc 15 envelope is `{ver, cmd, data: {…}}`: `cmd` rides at the outer level
        // and every payload field sits one level deeper (docs/protocol/mirroring.md "Payload";
        // upstream reads `cmd` off the frame and unwraps `data` the same way). `cmd 20` may carry
        // its candidate JSON string in `data` directly — when `data` is not a dict, the flat
        // fields are used and `cmd` above still rules.
        let cmd = StreamValue.int(raw["cmd"]) ?? -1
        let body = (raw["data"] as? [String: Any]) ?? raw
        let pkg = body["pkg"] as? String ?? ""
        let sid = StreamValue.int(body["sessionId"]).map(Int64.init)
        let mine = sid.flatMap { sessions[$0] }
        switch cmd {
        case 2:
            // Phone invite (app picker, notification "Open", or a view's stream request).
            if !pkg.isEmpty && StreamHost.isViewPkg(pkg) && sessions.values.contains(where: { $0.pkg == pkg }) {
                NSLog("SmartConnect: stream: ignoring a new \(pkg) setup: already open")
                return
            }
            requestStart(pkg: pkg,
                         cmp: body["cmp"],
                         userId: body["userId"] ?? 0,
                         shortcutId: body["shortcutId"],
                         source: StreamValue.int(body["source"]) ?? 1,
                         name: body["pkgName"] as? String)
        case 3:
            if let sid { handleOffer(sid: sid, body: body, pkg: pkg) }
        case 7:
            if let sid { closeSession(sid, why: "phone closed the session", tellPhone: false) }
        case 8:
            let state = StreamValue.int(body["state"]) ?? -1
            let target = mine ?? {
                guard sid == nil, let d = StreamValue.int(body["displayId"]), d >= 0 else { return nil }
                return byDisplay(Int64(d))
            }()
            if state == 1, let t = target {
                NSLog("SmartConnect: stream \(t.sid) connected: display \(body["displayId"] ?? "-") supportTouch \(body["supportTouch"] ?? "-")")
                t.learnDisplay(body)
            } else if state == 0, let t = target {
                closeSession(t.sid, why: "phone stopped it (reason \(body["reason"] ?? "-"))",
                             tellPhone: false)
            } else if state == 0 {
                finishInflight(pkg, ok: false, why: "reason \(body["reason"] ?? "-")")
            }
        case 12:
            finishInflight(pkg, ok: true, why: "merged")
            if let d = StreamValue.int(body["displayId"]), let s = byDisplay(Int64(d)) { s.raise() }
        case 14:
            if let d = StreamValue.int(body["displayId"]), let s = byDisplay(Int64(d)) { s.raise() }
        case 13:
            if let d = StreamValue.int(body["displayId"]), let s = byDisplay(Int64(d)) {
                let appName = body["appName"] as? String ?? ""
                if !appName.isEmpty && !StreamHost.isViewPkg(s.pkg) {
                    s.name = appName
                    s.window?.setTitle(s.windowTitle)
                }
            }
        case 16, 23:
            mine?.learnDisplay(body)
        case 20:
            if let mine { cmd20FromPhone(session: mine, body: body) }
        case 9, 10, 21, 26:
            break // heartbeat, audio app list, resize result: informational
        default:
            break // 5/6 pause/resume and 17/26 resize are not part of this port yet
        }
    }

    func byDisplay(_ d: Int64) -> StreamSession? {
        sessions.values.first { $0.displayId == d }
    }

    /// Sends the svc 15 `cmd 1` peer start data for one invite (docs/protocol/mirroring.md, exact
    /// field set). Repeats of the same pkg while one is out are dropped: the phone re-sends
    /// unanswered invites, and one cmd 1 is enough.
    private func requestStart(pkg: String, cmp: Any?, userId: Any, shortcutId: Any?, source: Int, name: String?) {
        if let current = inflight, current.pkg == pkg, Date().timeIntervalSince(current.at) < 20 {
            NSLog("SmartConnect: stream: already starting \(pkg); ignoring the repeated invitation")
            return
        }
        if let current = inflight, !current.pkg.isEmpty, Date().timeIntervalSince(current.at) >= 20 {
            NSLog("SmartConnect: stream: start of \(current.pkg) timed out")
        }
        // The bound the phone fits the stream into; "desktop" uses the phone's own desktop
        // resolution when the cmd 0 carried one, 1920x1080 otherwise (the phone's default).
        let (w, h) = pkg == "desktop" ? (viewResolution ?? (1920, 1080)) : (1920, 1080)
        let mm: (Int) -> Int = { Int((Double($0) * 344.0 / 1920.0).rounded()) }
        var data: [String: Any] = [
            "pkg": pkg, "userId": userId,
            "width": w, "height": h, "phyWidth": mm(w), "phyHeight": mm(h),
            "displayWidth": w, "displayHeight": h, "displayDensity": 160, "displayScale": 1.0,
            "align": 0, "instanceId": instanceId, "port": 0, "source": source,
            "supportedMediaFormat": 1, "supportWebRTC": 1,
            // JSON booleans, never 0/1: the phone's Gson would throw and the start dies silently.
            "supportCustomDisplay": false, "vrSupportUnfolded": false,
        ]
        // `cmp` and `shortcutId` are echoed when the phone invited an app (docs: app streams
        // carry `cmp` when the PC's service 15 version is 10+; PC-initiated starts leave both out).
        if let cmp { data["cmp"] = cmp }
        if let shortcutId { data["shortcutId"] = shortcutId }
        send15(1, data)
        inflight = (pkg, cmp, userId, shortcutId, Date())
        _ = name // app titles come from svc 15 cmd 13 once the display is up
    }

    private func finishInflight(_ pkg: String, ok: Bool, why: String) {
        guard let current = inflight, current.pkg == pkg else { return }
        inflight = nil
        NSLog("SmartConnect: stream: start of \(pkg) \(ok ? "done" : "failed") (\(why))")
    }

    private func handleOffer(sid: Int64, body: [String: Any], pkg: String) {
        if let existing = sessions[sid] {
            // Second and later cmd 3 (rotation, resize): only display id / capture size refresh.
            existing.learnDisplay(body)
            existing.learnStreamSize(body)
            return
        }
        // `webRTCData` is a JSON string that itself wraps the offer: `{"sdp":"v=0…
        // (double-encoded); parse it and hand the inner SDP to the page (upstream parses the
        // string and reads the `sdp` field too).
        guard let wrapped = body["webRTCData"] as? String,
              let raw = wrapped.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let offer = parsed["sdp"] as? String else {
            NSLog("SmartConnect: stream: a \(pkg) offer arrived without a parsable webRTCData")
            return
        }
        // The WebRTC SDP harness (`/test.html`) experiments on the newest real offer.
        StreamHost.lastOfferSDP = offer
        pushOfferToHarness(offer)
        let s = StreamSession(sid: sid, pkg: pkg,
                              userId: body["userId"] ?? inflight?.userId ?? 0,
                              cmp: body["cmp"] ?? inflight?.cmp,
                              shortcutId: body["shortcutId"] ?? inflight?.shortcutId,
                              name: body["pkgName"] as? String,
                              isView: StreamHost.isViewPkg(pkg))
        sessions[sid] = s
        notify()
        finishInflight(pkg, ok: true, why: "offer")
        s.learnDisplay(body)
        s.learnStreamSize(body)
        // The ICE filter prefers the daemon's pcAddress, so resolve it before the window opens.
        StreamHost.pcAddress { [weak self] addr in
            guard let self, self.sessions[sid] === s else { return }
            self.openSession(s, offer: offer, filter: StreamIceFilter.current(pcAddress: addr))
        }
    }

    nonisolated static func pcAddress(then: @escaping @MainActor (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var addr: String?
            if let fd = UnixSocket.connect(path: Paths.controlSocket, timeout: 2) {
                UnixSocket.writeLine("status", to: fd)
                if let line = UnixSocket.readLine(from: fd),
                   let d = line.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let a = obj["pcAddress"] as? String, !a.isEmpty {
                    addr = a
                }
                close(fd)
            }
            DispatchQueue.main.async { @MainActor in then(addr) }
        }
    }

    // MARK: window + webview

    private func openSession(_ s: StreamSession, offer: String, filter: StreamIceFilter) {
        guard s.window == nil else { return }
        iceFilter = filter
        let (frameW, frameH) = s.stream ?? (1920, 1080)
        let aspect = Double(frameH) / Double(max(1, frameW))
        let screen = NSScreen.screens.count > 1 ? NSScreen.screens[1] : (NSScreen.main ?? NSScreen.screens.first)
        let avail = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        var width = min(1280.0, avail.width - 40)
        var height = width * aspect
        let maxHeight = avail.height - 90 // title bar and a margin; portrait app streams are tall
        if height > maxHeight {
            height = maxHeight
            width = height / max(aspect, 0.05)
        }
        let frame = NSRect(x: avail.midX - width / 2, y: avail.midY - height / 2,
                           width: width, height: height)
        let window = StreamWindow(session: s, frame: frame)
        s.attach(window: window, offer: offer)
        window.makeKeyAndOrderFront()
        NSLog("SmartConnect: stream \(s.sid) (\(s.pkg)): new session, ICE filter \(filter.label)")
    }

    func pushDisplay(_ s: StreamSession) {
        if let d = s.displayId { windowJs(s, ["kind": "display", "displayId": Int(d)]) }
    }

    private func windowJs(_ s: StreamSession, _ payload: [String: Any]) {
        guard let view = s.window?.webView,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        view.evaluateJavaScript("window.fromHost && window.fromHost(\(text))")
    }

    /// The phone's candidates are relayed untouched: `data` holds a JSON string
    /// `{"type":"candidate","label":<m-line int>,"id":"<mid>","candidate":"candidate:…"}`.
    private func cmd20FromPhone(session: StreamSession, body: [String: Any]) {
        guard let dataStr = body["data"] as? String,
              let d = dataStr.data(using: .utf8),
              let inner = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let candidate = inner["candidate"] as? String else { return }
        let label = StreamValue.int(inner["label"]) ?? 0
        windowJs(session, ["kind": "candidate", "label": label, "candidate": candidate])
    }

    // MARK: page → host

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        // The SDP harness page posts with a `test` marker (it has no session object).
        if body["test"] as? Bool == true {
            NSLog("SmartConnect: stream: SDP harness: \(body["msg"] ?? "-")")
            return
        }
        guard let session = currentSession(message) else { return }
        switch kind {
        case "ready":
            // The page has its machinery: hand over the offer now.
            if let offer = session.pendingOffer {
                session.pendingOffer = nil
                windowJs(session, ["kind": "offer", "sdp": offer])
            }
            pushDisplay(session)
        case "answer":
            if let sdp = body["sdp"] as? String { sendAnswer(session, sdp: sdp) }
        case "dbg":
            NSLog("SmartConnect: stream \(session.sid): page debug: \(body["msg"] ?? "-")")
        case "candidate":
            if let candidate = body["candidate"] as? String {
                let label = StreamValue.int(body["sdpMLineIndex"]) ?? 0
                relayLocalCandidate(session, mLine: label, candidate: candidate)
            }
        case "input":
            if let payload = body["data"] as? [String: Any] { forwardInput(payload, session: session) }
        case "videosize":
            // The page reports the real decoded frame size; fit the window's aspect to it.
            if let w = StreamValue.int(body["w"]), let h = StreamValue.int(body["h"]) {
                session.window?.applyVideoSize(w: w, h: h)
            }
        case "mods":
            if let held = body["held"] as? [[String: Any]] { session.noteMods(held) }
        case "gone":
            // ICE failed or the page could not answer the offer: end the session with the phone.
            NSLog("SmartConnect: stream \(session.sid): page reported failure: \(body["err"] ?? "-")")
            closeSession(session.sid, why: "page reported the link is dead", tellPhone: true)
        default:
            break
        }
    }

    private var iceFilter = StreamIceFilter.current(pcAddress: nil)

    /// Relays a page local candidate to the phone after rewriting any mDNS `.local` host.
    /// On this WebKit build the page gathers exactly one SDP blob with `.local` host
    /// candidates (verified by the SDP harness); the phone cannot resolve mDNS names, so
    /// the host resolves them here (macOS routes `.local` through Bonjour/mDNSResponder)
    /// and rewrites the candidate to the real LAN address. Resolution runs off the main
    /// thread because a first-time Bonjour lookup can take several seconds.
    nonisolated private func relayLocalCandidate(_ session: StreamSession, mLine: Int, candidate: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let resolved = StreamHost.resolveMDNSCandidate(candidate)
            DispatchQueue.main.async { @MainActor in
                guard !session.closing else { return }
                guard let final = resolved else {
                    NSLog("SmartConnect: stream \(session.sid): local candidate unresolvable \(candidate.prefix(70))")
                    return
                }
                let allowed = self.iceFilter.allows(final)
                NSLog("SmartConnect: stream \(session.sid): local candidate \(allowed ? "relayed" : "filtered") \(final.prefix(80))")
                guard allowed else { return }
                if session.answered {
                    self.sendCandidate(session, mLine: mLine, candidate: final)
                } else {
                    session.noteLocalCandidate(mLine: mLine, candidate: final)
                }
            }
        }
    }

    /// Rewrites the address field of an mDNS `.local` candidate to its real IP. Returns the
    /// input unchanged without a `.local` host, and nil when the name cannot be resolved.
    nonisolated static func resolveMDNSCandidate(_ candidate: String) -> String? {
        var parts = candidate.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 6, parts[4].hasSuffix(".local") else { return candidate }
        let name = parts[4]
        guard let ip = resolveIPv4(name) else { return nil }
        NSLog("SmartConnect: stream: mdns \(name.prefix(20)) resolved to \(ip)")
        parts[4] = ip
        return parts.joined(separator: " ")
    }

    /// Blocking IPv4 `getaddrinfo` for one name (Bonjour answers `.local` system-wide).
    nonisolated private static func resolveIPv4(_ name: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(first.pointee.ai_addr, socklen_t(first.pointee.ai_addrlen),
                          &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: host)
    }

    private func currentSession(_ message: WKScriptMessage) -> StreamSession? {
        sessions.values.first { $0.window?.webView === message.webView }
    }

    private func forwardInput(_ payload: [String: Any], session: StreamSession) {
        guard let d = session.displayId, d >= 0, !session.closing else { return }
        let displayId = Int(d)
        switch payload["op"] as? String ?? "" {
        case "move":
            if let x = StreamValue.int(payload["x"]), let y = StreamValue.int(payload["y"]) {
                input16(4, ["displayId": displayId, "x": x, "y": y])
            }
        case "button":
            let key = StreamValue.int(payload["key"]) ?? 1
            let down = payload["down"] as? Bool ?? false
            input16(5, ["displayId": displayId, "key": key,
                        "x": StreamValue.int(payload["x"]) ?? 0, "y": StreamValue.int(payload["y"]) ?? 0,
                        "down": down])
        case "wheel":
            // key 4 is the wheel; `down: true` scrolls the content up top-down the phone shows.
            let down = payload["down"] as? Bool ?? true
            let x = StreamValue.int(payload["x"]) ?? 0
            let y = StreamValue.int(payload["y"]) ?? 0
            input16(5, ["displayId": displayId, "key": 4, "x": x, "y": y, "down": down])
        case "key":
            if let flags = StreamValue.int(payload["flags"]),
               let key = StreamValue.int(payload["key"]),
               let down = payload["down"] as? Bool {
                input16(3, ["displayId": displayId, "flags": flags, "key": key,
                            "down": down, "metaState": 0])
            }
        case "text":
            if let text = payload["text"] as? String, !text.isEmpty {
                input16(7, ["displayId": displayId, "text": text])
            }
        case "android":
            if let key = StreamValue.int(payload["keycode"]) {
                for down in [true, false] {
                    input16(3, ["displayId": displayId, "flags": 0x1000, "key": key,
                                "down": down, "metaState": 0])
                }
            }
        default:
            break
        }
    }

    // MARK: answer + candidates

    private func sendAnswer(_ s: StreamSession, sdp: String) {
        guard !s.answered else { return }
        var mid = ""
        for line in sdp.split(separator: "\n") where line.hasPrefix("a=mid:") {
            mid = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            break
        }
        s.noteAnswer(mid: mid)
        // `webRTCData` is a JSON *string* (double-encoded), not a nested object.
        let answerPayload: [String: Any] = ["type": "answer", "sdp": sdp]
        let answerData = try? JSONSerialization.data(withJSONObject: answerPayload)
        let data: [String: Any] = [
            "sessionId": Int(s.sid), "error": 0, "isWebRTC": 1, "resize": 0, "userId": s.userId,
            "webRTCData": String(decoding: answerData ?? Data("{}".utf8), as: UTF8.self),
        ]
        send15(4, data)
        // One heartbeat right away; the 30 s cadence keeps every later session alive.
        send15(9, nil)
        lastHb = Date()
        for (mLine, candidate) in s.pendingLocalFlush() {
            sendCandidate(s, mLine: mLine, candidate: candidate)
        }
    }

    private func sendCandidate(_ s: StreamSession, mLine: Int, candidate: String) {
        let inner: [String: Any] = ["type": "candidate", "label": mLine, "id": s.mid,
                                    "candidate": candidate]
        let innerData = try? JSONSerialization.data(withJSONObject: inner)
        let data: [String: Any] = [
            "sessionId": Int(s.sid), "type": "candidate", "userId": s.userId, "pkg": s.pkg,
            "data": String(decoding: innerData ?? Data("{}".utf8), as: UTF8.self),
        ]
        send15(20, data)
    }

    // MARK: closing

    private func closeSession(_ sid: Int64, why: String, tellPhone: Bool) {
        guard let s = sessions[sid] else { return }
        sessions[sid] = nil
        notify()
        s.close(why: why, tellPhone: tellPhone)
    }

    /// The user closed the window: the phone must hear a cmd 7.
    func userClosedStream(_ session: StreamSession) {
        closeSession(session.sid, why: "window closed by user", tellPhone: true)
    }
}

extension StreamSession {
    /// Consumes the held-back local candidates once the answer was sent.
    func pendingLocalFlush() -> [(mLine: Int, candidate: String)] {
        let out = pendingLocal
        pendingLocal = []
        return out
    }
}

/// A long-lived `send` connection with its reply drain, like upstream's `Daemon`. The daemon
/// replies `{"ok":bool,…}` to each send on the same connection.
final class StreamSender {
    private var fd: Int32?
    private let queue = DispatchQueue(label: "stream-send", qos: .userInitiated)

    private func channel() -> Int32? {
        if let fd, fd > 0 { return fd }
        guard let opened = UnixSocket.connect(path: Paths.controlSocket, timeout: 2) else { return nil }
        fd = opened
        let drain = dup(opened)
        DispatchQueue.global(qos: .utility).async {
            while let line = UnixSocket.readLine(from: drain, tolerateTimeout: true) {
                if line.contains("\"ok\":false") {
                    NSLog("SmartConnect: stream send: daemon: \(line)")
                }
            }
        }
        return opened
    }

    func send(service: Int, payload: [String: Any]) {
        queue.async { [weak self] in
            guard let self, let fd = self.channel() else { return }
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  var line = String(data: data, encoding: .utf8) else { return }
            line.append("\n")
            if !UnixSocket.writeLine(line, to: fd) {
                // The daemon stopped draining this socket (a wedged phone read stalls it).
                // Drop the fd so the next send reconnects instead of failing forever.
                NSLog("SmartConnect: stream send: write to the daemon stalled (errno \(errno)); reconnecting")
                if let old = self.fd { close(old) }
                self.fd = nil
            }
        }
    }
}

/// The window wrapper: owns the NSWindow + webview, receives the page's messages and the
/// window-close notification. One StreamWindow per session; the host matches by webview pointer.
@MainActor
final class StreamWindow: NSObject, NSWindowDelegate, WKScriptMessageHandler {
    let session: StreamSession
    private(set) var window: NSWindow?
    private(set) var webView: WKWebView?
    var title: String {
        didSet { window?.title = title }
    }

    /// Fits the window to the video's real aspect (docs/protocol/app-streaming.md): app streams
    /// deliver the app's own portrait surface (610x1356 OBSERVED) no matter what 1920x1080 bound
    /// `cmd 1` advertised, so the default window shape and the video disagree. Also re-fits when
    /// the phone rotates or resizes an app mid-session. 2 % slack avoids churn on rounding.
    func applyVideoSize(w: Int, h: Int) {
        guard let window, w > 0, h > 0 else { return }
        let aspect = Double(h) / Double(w)
        let content = window.contentView?.bounds.size ?? window.frame.size
        let currentAspect = content.height / Double(max(content.width, 1))
        guard abs(currentAspect - aspect) > 0.02 else { return }
        let screen = window.screen ?? NSScreen.main
        let avail = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        var width = max(content.width, 480)
        var height = width * aspect
        let maxHeight = avail.height - 90 // title bar and a margin so the window stays on screen
        if height > maxHeight {
            height = maxHeight
            width = height / aspect
        }
        let top = window.frame.maxY
        let originY = max(avail.minY, top - height)
        let originX = max(avail.minX,
                          min(avail.maxX - width, window.frame.midX - width / 2))
        window.setFrame(NSRect(x: originX, y: originY, width: width, height: height), display: true)
        NSLog("SmartConnect: stream \(session.sid) (\(session.pkg)): window refit to video \(w)x\(h)")
    }

    init(session: StreamSession, frame: NSRect) {
        self.session = session
        self.title = session.windowTitle
        super.init()
        let window = NSWindow(contentRect: frame,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "bridge")
        // The stream is video-only; autoplay must work without a user gesture to answer at all.
        config.mediaTypesRequiringUserActionForPlayback = []
        // NOTE: WebKit hides local ICE candidates behind mDNS `.local` names on some macOS
        // builds. The KVC toggle for it (`WebRTCMDNSICECandidatesEnabled`) does not exist in
        // this WebKit and crashes on setValue — candidate flow is logged in the host instead.
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height),
                             configuration: config)
        view.allowsMagnification = false
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        self.window = window
        self.webView = view
        // WebRTC needs a secure context: load the page over loopback HTTP (WebKit treats
        // 127.0.0.1 as trustworthy); `loadHTMLString` pages cannot do RTCPeerConnection.
        if let url = StreamPage.server?.url {
            view.load(URLRequest(url: url))
        } else {
            view.loadHTMLString(StreamPage.html(), baseURL: nil)
        }
    }

    func makeKeyAndOrderFront() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setTitle(_ t: String) {
        title = t
    }

    /// Window-level teardown only (no phone traffic — the close decision lives in the session).
    func closeWindowOnly() {
        window?.close()
        window = nil
        webView = nil
    }

    // NSWindowDelegate — the user clicked the close button.

    func windowWillClose(_ notification: Notification) {
        let s = session
        Task { @MainActor in
            StreamHost.shared.userClosedStream(s)
        }
    }

    // WKScriptMessageHandler — the page posts here; forward to the host.

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        let host = StreamHost.shared
        let msg = message
        Task { @MainActor in
            host.userContentController(userContentController, didReceive: msg)
        }
    }
}

// MARK: - The answering page (embedded; RTCPeerConnection + input capture)

enum StreamPage {
    /// Serves [`StreamPage.html`](StreamPage.html()) on `http://127.0.0.1:<port>/`. WebKit only
    /// enables WebRTC in a **secure context**, which `loadHTMLString(baseURL: nil)` is not — the
    /// page must load over HTTP, and WebKit treats loopback as potentially trustworthy. One
    /// server for all stream windows; the OS picks a free port at startup. `nil` when the
    /// loopback bind failed (the window then falls back to `loadHTMLString`, no WebRTC).
    static let server: PageServer? = {
        if let s = PageServer() { return s }
        NSLog("SmartConnect: stream page server init FAILED (loopback page load will be non-secure)")
        return nil
    }()

    static func html() -> String {
        ##"""
        <!doctype html>
        <html><head><meta charset="utf-8">
        <style>
          html,body { margin:0; height:100%; background:#000; overflow:hidden;
                      user-select:none; -webkit-user-select:none; }
          video { width:100%; height:100%; object-fit:contain; display:block; }
          #status { position:absolute; inset:0; display:flex; align-items:center; justify-content:center;
                    color:#888; font:13px -apple-system, sans-serif; letter-spacing:.06em; }
        </style></head>
        <body>
          <video id="v" autoplay muted playsinline></video>
          <div id="status">Connecting to phone…</div>
          <script>
            'use strict';
            const video = document.getElementById('v');
            const status = document.getElementById('status');
            const post = (obj) => window.webkit.messageHandlers.bridge.postMessage(obj);
            let pc = null, displayId = null;
            let pendingRemote = [];
            const heldMods = [];

            async function startAnswer(rawSdp) {
              try {
                // Keep the offer as the phone built it. The h264-only filter made WebKit
                // reject the whole m-section (`m=video 0` — its codec-list rewrite seems to
                // invalidate the section) and the phone prefers H264 on its own anyway.
                const sdp = rawSdp;
                if (!sdp) { post({kind: 'gone', err: 'no offer'}); return; }
                pc = new RTCPeerConnection();
                pc.ontrack = (ev) => {
                  video.srcObject = ev.streams[0] || new MediaStream([ev.track]);
                  video.play().catch(() => {});
                  status.style.display = 'none';
                };
                pc.onicecandidate = (ev) => {
                  if (ev.candidate) post({kind: 'candidate',
                                          sdpMLineIndex: ev.candidate.sdpMLineIndex || 0,
                                          candidate: ev.candidate.candidate});
                };
                pc.oniceconnectionstatechange = () => {
                  if (pc && (pc.iceConnectionState === 'failed')) { post({kind: 'gone'}); }
                };
                for (const msg of pendingRemote.splice(0)) {
                  if (msg.kind === 'candidate') addRemoteCandidate(msg);
                }
                await pc.setRemoteDescription({type: 'offer', sdp: sdp});
                const ans = await pc.createAnswer();
                await pc.setLocalDescription(ans);
                post({kind: 'answer', sdp: pc.localDescription.sdp});
              } catch (err) {
                post({kind: 'gone', err: String((err && err.message) || err)});
              }
            }

            function addRemoteCandidate(msg) {
              if (!pc) { pendingRemote.push(msg); return; }
              pc.addIceCandidate({candidate: msg.candidate, sdpMLineIndex: msg.label}).catch(() => {});
            }

            window.fromHost = (msg) => {
              if (msg.kind === 'offer') startAnswer(msg.sdp);
              else if (msg.kind === 'candidate') addRemoteCandidate(msg);
              else if (msg.kind === 'display') displayId = msg.displayId;
            };

            post({kind: 'ready'});

            // Report the real decoded frame size so the host can fit the window's aspect to it:
            // app streams deliver the app's own portrait surface (610x1356 observed) whatever
            // the cmd 1 bound advertised, and `resize` fires again when the phone rotates/resizes.
            function reportVideoSize() {
              if (video.videoWidth && video.videoHeight)
                post({kind: 'videosize', w: video.videoWidth, h: video.videoHeight});
            }
            video.addEventListener('loadedmetadata', reportVideoSize);
            video.addEventListener('resize', reportVideoSize);

            // --- input: frame-pixel coordinates and PC/AT scancodes (port of mirror/src/keys.rs).
            function framed(e) {
              if (!video.videoWidth) return null;
              const r = video.getBoundingClientRect();
              const dw = Math.min(r.width, r.height * video.videoWidth / video.videoHeight);
              const dh = Math.min(r.height, r.width * video.videoHeight / video.videoWidth);
              const ox = (r.width - dw) / 2, oy = (r.height - dh) / 2;
              const x = Math.round((e.clientX - r.left - ox) * video.videoWidth / dw);
              const y = Math.round((e.clientY - r.top - oy) * video.videoHeight / dh);
              return {x: Math.max(0, Math.min(video.videoWidth - 1, x)),
                      y: Math.max(0, Math.min(video.videoHeight - 1, y))};
            }
            video.addEventListener('pointermove', (e) => {
              const p = framed(e);
              if (p) post({kind: 'input', data: {op: 'move', x: p.x, y: p.y}});
            });
            video.addEventListener('pointerdown', (e) => {
              video.setPointerCapture(e.pointerId);
              mouseButton(e, true);
            });
            video.addEventListener('pointerup', (e) => mouseButton(e, false));
            video.addEventListener('contextmenu', (e) => e.preventDefault());
            function mouseButton(e, down) {
              const key = [1, 2, 3][e.button] || 0; // 1 left, 2 middle, 3 right
              if (!key) return;
              const p = framed(e);
              if (p) post({kind: 'input', data: {op: 'button', key: key, x: p.x, y: p.y, down: down}});
            }
            let wheelAcc = 0;
            window.addEventListener('wheel', (e) => {
              wheelAcc += e.deltaY > 0 ? 1 : -1;   // DOM deltaY > 0 is "scroll down"
              while (Math.abs(wheelAcc) >= 1) {
                const down = wheelAcc > 0;
                wheelAcc += down ? -1 : 1;
                post({kind: 'input', data: {op: 'wheel', down: down}});
              }
            }, {passive: true});

            // Keyboard: event.code → PC/AT scancode; the 0x100 flag marks extended (E0) keys.
            const KEYS = {
              Escape: 1, Digit1: 2, Digit2: 3, Digit3: 4, Digit4: 5, Digit5: 6,
              Digit6: 7, Digit7: 8, Digit8: 9, Digit9: 10, Digit0: 11,
              Minus: 12, Equal: 13, Backspace: 14, Tab: 15,
              KeyQ: 16, KeyW: 17, KeyE: 18, KeyR: 19, KeyT: 20, KeyY: 21, KeyU: 22,
              KeyI: 23, KeyO: 24, KeyP: 25, BracketLeft: 26, BracketRight: 27,
              Enter: 28, ControlLeft: 29,
              KeyA: 30, KeyS: 31, KeyD: 32, KeyF: 33, KeyG: 34, KeyH: 35, KeyJ: 36,
              KeyK: 37, KeyL: 38, Semicolon: 39, Quote: 40, Backquote: 41,
              ShiftLeft: 42, Backslash: 43,
              KeyZ: 44, KeyX: 45, KeyC: 46, KeyV: 47, KeyB: 48, KeyN: 49, KeyM: 50,
              Comma: 51, Period: 52, Slash: 53, ShiftRight: 54, NumpadMultiply: 55,
              AltLeft: 56, Space: 57, CapsLock: 58,
              F1: 59, F2: 60, F3: 61, F4: 62, F5: 63, F6: 64, F7: 65, F8: 66, F9: 67, F10: 68,
              Numpad7: 71, Numpad8: 72, Numpad9: 73, NumpadSubtract: 74,
              Numpad4: 75, Numpad5: 76, Numpad6: 77, NumpadAdd: 78,
              Numpad1: 79, Numpad2: 80, Numpad3: 81, Numpad0: 82, NumpadDecimal: 83,
              F11: 87, F12: 88,
            };
            const KEYS_E0 = {
              ControlRight: 29, NumpadEnter: 28, NumpadDivide: 53, AltRight: 56,
              Home: 71, ArrowUp: 72, PageUp: 73, ArrowLeft: 75, ArrowRight: 77,
              End: 79, ArrowDown: 80, PageDown: 81, Insert: 82, Delete: 83,
              MetaLeft: 91, MetaRight: 92, ContextMenu: 93,
            };
            function lookup(code) {
              if (KEYS[code] !== undefined) return {key: KEYS[code], flags: 0};
              if (KEYS_E0[code] !== undefined) return {key: KEYS_E0[code], flags: 0x100};
              return null;
            }
            const MOD_CODES = new Set(['ControlLeft', 'ControlRight', 'ShiftLeft', 'ShiftRight',
                                       'AltLeft', 'AltRight', 'MetaLeft', 'MetaRight']);
            function postMods() {
              post({kind: 'mods',
                    held: heldMods.map(h => ({key: h.key, flags: h.flags}))});
            }
            window.addEventListener('keydown', (e) => {
              // Phone navigation: Escape → BACK (unless Shift); Ctrl+Alt+H/R/B → HOME/RECENTS/BACK.
              if (e.key === 'Escape' && !e.shiftKey) {
                post({kind: 'input', data: {op: 'android', keycode: 4}});
                e.preventDefault(); return;
              }
              if (e.ctrlKey && e.altKey && !e.metaKey) {
                if (e.code === 'KeyH') { post({kind: 'input', data: {op: 'android', keycode: 3}}); e.preventDefault(); return; }
                if (e.code === 'KeyR') { post({kind: 'input', data: {op: 'android', keycode: 187}}); e.preventDefault(); return; }
                if (e.code === 'KeyB') { post({kind: 'input', data: {op: 'android', keycode: 4}}); e.preventDefault(); return; }
              }
              const m = lookup(e.code);
              const plain = !e.ctrlKey && !e.altKey && !e.metaKey;
              if (m && plain && e.shiftKey) {
                // Plain scancodes carry no shift state; shifted text goes through the text channel.
                if (e.type && e.key && e.key.length === 1 && !e.repeat) {
                  post({kind: 'input', data: {op: 'text', text: e.key}});
                }
                e.preventDefault(); return;
              }
              if (m) {
                post({kind: 'input', data: {op: 'key', key: m.key, flags: m.flags, down: true}});
                if (MOD_CODES.has(e.code) && !e.repeat) {
                  heldMods.push({key: m.key, flags: m.flags});
                  postMods();
                }
                e.preventDefault(); return;
              }
              if (e.key && e.key.length === 1 && plain && !e.repeat) {
                post({kind: 'input', data: {op: 'text', text: e.key}});
                e.preventDefault();
              }
            });
            window.addEventListener('keyup', (e) => {
              const m = lookup(e.code);
              if (m) {
                post({kind: 'input', data: {op: 'key', key: m.key, flags: m.flags, down: false}});
                if (MOD_CODES.has(e.code)) {
                  const i = heldMods.findIndex(h => h.key === m.key && h.flags === m.flags);
                  if (i >= 0) { heldMods.splice(i, 1); postMods(); }
                }
                e.preventDefault();
              }
            });
          </script></body></html>
        """##
    }

    /// Temporary WebRTC diagnostic page (served at `/test.html`). It waits for a real phone
    /// offer on `/offer.sdp`, then runs the answer through SDP-plan variants, reporting the
    /// resulting `m=video` lines, ICE states and candidate counts to the host log.
    static func testHtml() -> String {
        ##"""
        <!doctype html>
        <html><head><meta charset="utf-8"></head>
        <body style="font:12px -apple-system, sans-serif">
          <pre id="out" style="white-space:pre-wrap"></pre>
          <script>
            'use strict';
            const post = (obj) => window.webkit.messageHandlers.bridge.postMessage(obj);
            const show = (m) => { document.getElementById('out').textContent += m + '\n'; };
            const lg = (m) => { show(m); post({kind: 'dbg', test: true, msg: m}); };
            const sleep = (ms) => new Promise(res => setTimeout(res, ms));
            lg('page up rtc=' + (typeof RTCPeerConnection) + ' origin=' + location.origin);

            // Same filter as the stream page (h264Only).
            function h264Only(sdp) {
              const lines = sdp.replace(/\r\n/g, '\n').split('\n');
              const codec = {}, apt = {};
              for (const l of lines) {
                let m = l.match(/^a=rtpmap:(\d+)\s+([^\/ ]+)/);
                if (m) codec[m[1]] = m[2].toUpperCase();
                m = l.match(/^a=fmtp:(\d+)\b.*\bapt=(\d+)/);
                if (m) apt[m[1]] = m[2];
              }
              const keep = new Set(Object.keys(codec).filter(pt => codec[pt] === 'H264'));
              for (const rtx of Object.keys(apt)) if (keep.has(apt[rtx])) keep.add(rtx);
              if (keep.size === 0) return null;
              const out = [];
              for (const l of lines) {
                let m = l.match(/^a=(rtpmap|fmtp|rtcp-fb):(\d+)\b/);
                if (m && !keep.has(m[2])) continue;
                if (l.startsWith('a=extmap:') && l.includes('urn:3gpp:video-orientation')) continue;
                if (l.startsWith('m=video')) {
                  const parts = l.split(' ');
                  out.push([parts[0], parts[1], parts[2]]
                    .concat(parts.slice(3).filter(f => keep.has(f))).join(' '));
                  continue;
                }
                if (l.startsWith('a=ssrc') || l.startsWith('a=msid')) continue;
                out.push(l);
              }
              return out.join('\r\n');
            }

            const mline = (pc) => {
              const m = /\nm=video[^\r\n]*/.exec('\n' + (pc ? pc.localDescription.sdp : ''));
              return m ? m[0].trim() : 'NO-m-line';
            };

            // Runs one variant; logs the answer m-line, then gathers candidates for 3 s.
            async function run(label, offerSdp, {transceiver = false, ownOffer = false}) {
              try {
                const p = new RTCPeerConnection({iceServers: []});
                const candidates = [];
                let iceState = '', gather = '';
                p.onicecandidate = (ev) => { if (ev.candidate) candidates.push(ev.candidate.candidate); };
                p.oniceconnectionstatechange = () => { iceState = p.iceConnectionState; };
                p.onicegatheringstatechange = () => {
                  gather = p.iceGatheringState;
                  lg(label + ': gathering=' + gather + ' candidates=' + candidates.length);
                };
                if (ownOffer) {
                  p.addTransceiver('video', {direction: 'recvonly'});
                  const off = await p.createOffer();
                  await p.setLocalDescription(off);
                  await p.setRemoteDescription(p.localDescription);
                  const ans = await p.createAnswer();
                  await p.setLocalDescription(ans);
                  lg(label + ': local roundtrip m-line: ' + mline(p));
                } else {
                  if (transceiver) p.addTransceiver('video', {direction: 'recvonly'});
                  await p.setRemoteDescription({type: 'offer', sdp: offerSdp});
                  const ans = await p.createAnswer();
                  await p.setLocalDescription(ans);
                  lg(label + ': answer m-line: ' + mline(p));
                }
                await sleep(3000);
                const c0 = candidates[0] || 'none';
                lg(label + ': after 3s ice=' + iceState + ' gather=' + gather +
                   ' candidates=' + candidates.length + ' first=' + c0.slice(0, 70));
                p.close();
              } catch (e) {
                lg(label + ' ERROR: ' + String((e && e.message) || e));
              }
            }

            (async () => {
              let offerResolve = null;
              window.__setOffer = (sdp) => {
                if (offerResolve) { offerResolve(sdp); offerResolve = null; }
              };
              const waitForOffer = () => new Promise(res => { offerResolve = res; });
              // Re-run the suite for every new offer; the page never times out.
              while (true) {
                show('waiting for an offer …');
                const raw = await waitForOffer();
                if (!raw) { lg('empty offer'); continue; }
                lg('offer captured: len=' + raw.length);
                const sdp = h264Only(raw) || raw;
                await run('A-plain (filtered, no transceiver)', sdp, {});
                await run('B-transceiver (filtered + recvonly)', sdp, {transceiver: true});
                await run('C-unfiltered (raw offer, no transceiver)', raw, {});
                await run('D-selftest (webkit own offer->answer)', sdp, {ownOffer: true});
                lg('done');
              }
            })();
          </script>
        </body></html>
        """##
    }
}

/// Tiny loopback HTTP/1.0 server that replies to every GET with the stream page. Blocking POSIX
/// sockets on one worker thread, in keeping with the `UnixSocket` helpers; the requests are tiny
/// (WKWebView loads the page and may probe `/favicon.ico`), so a sequential loop is plenty.
final class PageServer {
    private let listenFD: Int32
    private let boundPort: UInt16

    init?() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(0).bigEndian          // let the OS pick a free port
        // NOTE: `INADDR_LOOPBACK` as imported into Swift is byte-swapped; `bind` fails with
        // EINVAL-adjacent errno 49 when using it directly (verified outside the app).
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bindOK = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in Darwin.bind(fd, sp, size) }
        }
        guard bindOK == 0, listen(fd, 8) == 0 else {
            close(fd)
            return nil
        }
        var bound = sockaddr_in()
        var boundLen = size
        _ = withUnsafeMutablePointer(to: &bound) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                getsockname(fd, sp, &boundLen)
            }
        }
        listenFD = fd
        boundPort = bound.sin_port.bigEndian
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.stackSize = 1 << 18
        thread.start()
        NSLog("SmartConnect: stream page served at http://127.0.0.1:\(boundPort)/")
    }

    var url: URL? {
        guard boundPort != 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(boundPort)/stream.html")
    }

    var testURL: URL? {
        guard boundPort != 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(boundPort)/test.html")
    }

    private func acceptLoop() {
        while true {
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let fd = accept(listenFD, nil, &len)
            guard fd >= 0 else { return }
            handle(fd)
            close(fd)
        }
    }

    private func handle(_ fd: Int32) {
        // Read through the blank line, then answer; the body never arrives on a GET.
        var buffer = [UInt8](repeating: 0, count: 2048)
        var saw = ""
        while !saw.contains("\r\n\r\n") {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { return }
            saw.append(String(decoding: buffer[0..<n], as: UTF8.self))
        }
        // Route by path: `GET <path> HTTP/1.x` on the first line.
        let first = saw.components(separatedBy: "\r\n").first ?? ""
        let path = first.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        switch path {
        case "/offer.sdp":
            reply(fd, type: "text/plain", body: StreamHost.lastOfferSDP ?? "<no offer captured yet>")
        case "/test.html":
            reply(fd, type: "text/html; charset=utf-8", body: StreamPage.testHtml())
        default:
            reply(fd, type: "text/html; charset=utf-8", body: StreamPage.html())
        }
    }

    private func reply(_ fd: Int32, type: String, body: String) {
        let head = """
        HTTP/1.0 200 OK\r
        Content-Type: \(type)\r
        Cache-Control: no-store\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r

        """
        var out = Data(head.utf8)
        out.append(Data(body.utf8))
        out.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                if n <= 0 { return }
                off += n
            }
        }
    }
}
