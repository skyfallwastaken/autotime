import AppKit
import IOKit.pwr_mgt
import Combine

final class Tracker: ObservableObject {
    static let shared = Tracker()

    @Published private(set) var currentApp = ""
    @Published private(set) var currentLabel = ""
    @Published private(set) var isIdle = false
    @Published var isPaused: Bool {
        didSet {
            UserDefaults.standard.set(isPaused, forKey: "paused")
            queue.async { self.closeSegment(at: Date()) }
        }
    }

    private let queue = DispatchQueue(label: "autotime.tracker", qos: .utility)
    private let extractor = Extractor()
    private var timer: DispatchSourceTimer?
    private var current: (id: Int64, key: String, start: Date, end: Date)?
    private var lastVideo = Date.distantPast
    private var locked = false
    private var asleep = false
    private var lastNotify = Date.distantPast
    private let interval: TimeInterval = 1

    var idleThreshold: TimeInterval {
        let minutes = UserDefaults.standard.double(forKey: "idleMinutes")
        return (minutes > 0 ? minutes : 3) * 60
    }

    private init() {
        isPaused = UserDefaults.standard.bool(forKey: "paused")
    }

    func start() {
        guard timer == nil else { return }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in self?.setFlag { $0.asleep = true } }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in self?.setFlag { $0.asleep = false } }
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: nil) { [weak self] _ in self?.setFlag { $0.asleep = true } }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil) { [weak self] _ in self?.setFlag { $0.asleep = false } }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: nil) { [weak self] _ in self?.setFlag { $0.locked = true } }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil) { [weak self] _ in self?.setFlag { $0.locked = false } }

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: interval, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        queue.sync { closeSegment(at: Date()) }
    }

    private func setFlag(_ change: @escaping (Tracker) -> Void) {
        queue.async {
            change(self)
            if self.locked || self.asleep { self.closeSegment(at: Date()) }
        }
    }

    private func closeSegment(at date: Date) {
        if let c = current {
            Store.shared.updateEnd(id: c.id, end: max(c.end, date))
            current = nil
            notify(force: true)
        }
    }

    var countsVideo: Bool {
        UserDefaults.standard.object(forKey: "countVideo") as? Bool ?? true
    }

    private func tick() {
        let now = Date()
        let app = NSWorkspace.shared.frontmostApplication
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if countsVideo, let app, Self.isPlayingVideo(app) { lastVideo = now }
        let lastActive = max(now.addingTimeInterval(-idle), lastVideo)
        let idleNow = now.timeIntervalSince(lastActive) >= idleThreshold

        if isPaused || locked || asleep || idleNow {
            if let c = current {
                let end = idleNow ? max(c.start, min(c.end, lastActive)) : now
                Store.shared.updateEnd(id: c.id, end: end)
                current = nil
                notify(force: true)
            }
            publish(app: "", label: "", idle: idleNow || locked || asleep)
            return
        }

        guard let app else { return }
        let bundleID = app.bundleIdentifier ?? app.executableURL?.lastPathComponent ?? "unknown"
        if bundleID == "com.apple.loginwindow" || bundleID == "com.apple.ScreenSaver.Engine" {
            closeSegment(at: now)
            return
        }

        let appName = app.localizedName ?? bundleID
        let info = AccessibilityPermission.isTrusted ? extractor.extract(app: app) : ExtractedInfo(title: "", path: "")
        let key = "\(bundleID)\u{1}\(info.title)\u{1}\(info.path)"

        let pathless = "\(bundleID)\u{1}\(info.title)\u{1}"
        if let c = current, c.key == key || (c.key == pathless && !info.title.isEmpty), now.timeIntervalSince(c.end) < interval * 4 {
            if c.key != key { Store.shared.updatePath(id: c.id, path: info.path) }
            Store.shared.updateEnd(id: c.id, end: now)
            current = (c.id, key, c.start, now)
        } else {
            if let c = current {
                Store.shared.updateEnd(id: c.id, end: now)
            }
            let id = Store.shared.insert(start: now, end: now, bundleID: bundleID, appName: appName, title: info.title, path: info.path)
            current = (id, key, now, now)
            notify(force: false)
        }

        let label = [info.path.isEmpty ? nil : ActivityPath.components(path: info.path, title: "").last, info.title.isEmpty ? nil : info.title]
            .compactMap { $0 }.first ?? ""
        publish(app: appName, label: label, idle: false)
        notify(force: false)
    }

    static func isPlayingVideo(_ app: NSRunningApplication) -> Bool {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byProcess = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }
        let appPath = app.bundleURL?.path
        for (pid, assertions) in byProcess {
            let holdsDisplay = assertions.contains {
                let type = $0[kIOPMAssertionTypeKey] as? String
                return type == kIOPMAssertionTypeNoDisplaySleep || type == kIOPMAssertionTypePreventUserIdleDisplaySleep
            }
            guard holdsDisplay else { continue }
            if pid.int32Value == app.processIdentifier { return true }
            if let appPath, let owner = NSRunningApplication(processIdentifier: pid.int32Value)?.bundleURL?.path,
               owner.hasPrefix(appPath + "/") {
                return true
            }
        }
        return false
    }

    private func publish(app: String, label: String, idle: Bool) {
        DispatchQueue.main.async {
            if self.currentApp != app { self.currentApp = app }
            if self.currentLabel != label { self.currentLabel = label }
            if self.isIdle != idle { self.isIdle = idle }
        }
    }

    private func notify(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastNotify) >= 5 else { return }
        lastNotify = now
        DispatchQueue.main.async { NotificationCenter.default.post(name: .storeDidChange, object: nil) }
    }
}
