import Foundation
import SQLite3

struct Activity: Identifiable, Hashable {
    var id: Int64
    var start: Date
    var end: Date
    var bundleID: String
    var appName: String
    var title: String
    var path: String

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    func clipped(to range: ClosedRange<Date>) -> Activity? {
        let s = max(start, range.lowerBound)
        let e = min(end, range.upperBound)
        guard e > s else { return nil }
        var copy = self
        copy.start = s
        copy.end = e
        return copy
    }

    var key: String { "\(bundleID)\u{1}\(title)\u{1}\(path)" }
}

extension Notification.Name {
    static let storeDidChange = Notification.Name("AutotimeStoreDidChange")
}

extension NotificationCenter {
    /// Deletions and imports can change any day, so they ask every view to reload, not just ones showing today.
    func postStoreEdited() {
        DispatchQueue.main.async { self.post(name: .storeDidChange, object: nil, userInfo: ["edited": true]) }
    }
}

final class Store {
    static let shared = Store()

    private var db: OpaquePointer?
    private let lock = NSLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    /// The longest any activity has lasted, so a day's query can search the start index from just before the day
    /// instead of from the beginning of history. Only ever grows, so it stays a safe bound after deletions.
    private var longest: TimeInterval = 0

    /// System helper processes that can become frontmost but aren't apps people work in (based on Timing's skip list).
    /// They are never recorded, and rows already stored or imported are dropped on read, so they never reach lists or totals.
    /// Matched case-insensitively against bundle IDs and the executable names stored for bundle-less processes.
    static let hiddenBundleIDs: Set<String> = Set([
        "com.apple.loginwindow",
        "com.apple.ScreenSaver.Engine",
        "com.apple.UserNotificationCenter",
        "com.apple.coreservices.uiagent",
        "com.apple.SecurityAgent",
        "SecurityAgent",
        "com.apple.systemuiserver",
        "com.apple.dock",
        "com.apple.UnmountAssistantAgent",
        "com.apple.frameworks.diskimages.uiagent",
        "com.apple.NetAuthAgent",
        "com.apple.FollowUpUI",
        "com.apple.WebKit.PluginHost",
        "com.apple.AutomatorRunner",
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.WindowManager",
        "com.apple.accessibility.universalAccessAuthWarn",
    ].map { $0.lowercased() })

    static func isHidden(_ bundleID: String) -> Bool {
        hiddenBundleIDs.contains(bundleID.lowercased())
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Autotime", isDirectory: true)
    }

    private init() {
        try? FileManager.default.createDirectory(at: Store.directory, withIntermediateDirectories: true)
        let url = Store.directory.appendingPathComponent("autotime.sqlite")
        sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        // Deleted history is overwritten rather than left in free pages.
        exec("PRAGMA secure_delete=ON")
        exec("""
        CREATE TABLE IF NOT EXISTS activity(
            id INTEGER PRIMARY KEY,
            start REAL NOT NULL,
            end REAL NOT NULL,
            bundle TEXT NOT NULL,
            app TEXT NOT NULL,
            title TEXT NOT NULL,
            path TEXT NOT NULL)
        """)
        exec("CREATE INDEX IF NOT EXISTS activity_start ON activity(start)")
        exec("CREATE INDEX IF NOT EXISTS activity_end ON activity(end)")
        refreshLongest()
    }

    private func refreshLongest() {
        guard let stmt = prepare("SELECT MAX(end - start) FROM activity") else { return }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW { longest = max(longest, sqlite3_column_double(stmt, 0)) }
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        return stmt
    }

    func insert(start: Date, end: Date, bundleID: String, appName: String, title: String, path: String) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = prepare("INSERT INTO activity(start,end,bundle,app,title,path) VALUES(?,?,?,?,?,?)") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 2, end.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 3, bundleID, -1, transient)
        sqlite3_bind_text(stmt, 4, appName, -1, transient)
        sqlite3_bind_text(stmt, 5, title, -1, transient)
        sqlite3_bind_text(stmt, 6, path, -1, transient)
        sqlite3_step(stmt)
        longest = max(longest, end.timeIntervalSince(start))
        return sqlite3_last_insert_rowid(db)
    }

    func updateEnd(id: Int64, end: Date) {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = prepare("UPDATE activity SET end=? WHERE id=? RETURNING end - start") else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, end.timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 2, id)
        if sqlite3_step(stmt) == SQLITE_ROW { longest = max(longest, sqlite3_column_double(stmt, 0)) }
    }

    func updatePath(id: Int64, path: String) {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = prepare("UPDATE activity SET path=? WHERE id=?") else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, path, -1, transient)
        sqlite3_bind_int64(stmt, 2, id)
        sqlite3_step(stmt)
    }

    func activities(in range: ClosedRange<Date>) -> [Activity] {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = prepare("SELECT id,start,end,bundle,app,title,path FROM activity WHERE start>=? AND start<? AND end>? ORDER BY start") else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, range.lowerBound.timeIntervalSince1970 - longest)
        sqlite3_bind_double(stmt, 2, range.upperBound.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 3, range.lowerBound.timeIntervalSince1970)
        var result: [Activity] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if Store.isHidden(text(stmt, 3)) { continue }
            let a = Activity(
                id: sqlite3_column_int64(stmt, 0),
                start: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                end: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                bundleID: text(stmt, 3),
                appName: text(stmt, 4),
                title: text(stmt, 5),
                path: text(stmt, 6)
            )
            if let c = a.clipped(to: range) { result.append(c) }
        }
        return result
    }

    func delete(in range: ClosedRange<Date>) {
        lock.lock()
        if let stmt = prepare("DELETE FROM activity WHERE start>=? AND start<?") {
            sqlite3_bind_double(stmt, 1, range.lowerBound.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, range.upperBound.timeIntervalSince1970)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        lock.unlock()
        NotificationCenter.default.postStoreEdited()
    }

    func delete(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        lock.lock()
        if let stmt = prepare("DELETE FROM activity WHERE id=?") {
            exec("BEGIN")
            for id in ids {
                sqlite3_reset(stmt)
                sqlite3_bind_int64(stmt, 1, id)
                sqlite3_step(stmt)
            }
            exec("COMMIT")
            sqlite3_finalize(stmt)
        }
        exec("PRAGMA wal_checkpoint(TRUNCATE)")
        lock.unlock()
        NotificationCenter.default.postStoreEdited()
    }

    /// Apps recorded in the last `days` days, most used first, for pickers.
    func recentApps(days: Int = 30) async -> [(bundleID: String, name: String)] {
        await Task.detached(priority: .userInitiated) { self.recentAppsNow(days: days) }.value
    }

    private func recentAppsNow(days: Int) -> [(bundleID: String, name: String)] {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = prepare("SELECT bundle, app FROM activity WHERE start>? GROUP BY bundle ORDER BY SUM(end - start) DESC") else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970)
        var result: [(bundleID: String, name: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let bundle = text(stmt, 0)
            if !Store.isHidden(bundle) { result.append((bundle, text(stmt, 1))) }
        }
        return result
    }

    func deleteAll() {
        lock.lock()
        exec("DELETE FROM activity")
        exec("VACUUM")
        lock.unlock()
        NotificationCenter.default.postStoreEdited()
    }

    func importIntervals(_ intervals: [ImportedInterval], name: (String) -> String) -> (count: Int, duration: TimeInterval) {
        guard let first = intervals.map(\.start).min(), let last = intervals.map(\.end).max() else { return (0, 0) }
        let existing = activities(in: first...last).map { ($0.start, $0.end) }.sorted { $0.0 < $1.0 }
        var covered: [(Date, Date)] = []
        for e in existing {
            if let l = covered.last, e.0 <= l.1 { covered[covered.count - 1].1 = max(l.1, e.1) } else { covered.append(e) }
        }

        var names: [String: String] = [:]
        lock.lock(); defer { lock.unlock() }
        guard let insert = prepare("INSERT INTO activity(start,end,bundle,app,title,path) VALUES(?,?,?,?,?,?)") else { return (0, 0) }
        defer { sqlite3_finalize(insert) }
        exec("BEGIN")
        var count = 0
        var total: TimeInterval = 0
        var cursor = 0
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            while cursor < covered.count && covered[cursor].1 <= interval.start { cursor += 1 }
            var pieces: [(Date, Date)] = []
            var start = interval.start
            var j = cursor
            while j < covered.count && covered[j].0 < interval.end {
                if covered[j].0 > start { pieces.append((start, covered[j].0)) }
                start = max(start, covered[j].1)
                j += 1
            }
            if start < interval.end { pieces.append((start, interval.end)) }
            let app = names[interval.bundleID] ?? name(interval.bundleID)
            names[interval.bundleID] = app
            for (s, e) in pieces where e.timeIntervalSince(s) >= 1 {
                sqlite3_reset(insert)
                sqlite3_bind_double(insert, 1, s.timeIntervalSince1970)
                sqlite3_bind_double(insert, 2, e.timeIntervalSince1970)
                sqlite3_bind_text(insert, 3, interval.bundleID, -1, transient)
                sqlite3_bind_text(insert, 4, app, -1, transient)
                sqlite3_bind_text(insert, 5, "", -1, transient)
                sqlite3_bind_text(insert, 6, "", -1, transient)
                if sqlite3_step(insert) == SQLITE_DONE {
                    count += 1
                    total += e.timeIntervalSince(s)
                }
            }
        }
        exec("COMMIT")
        refreshLongest()
        NotificationCenter.default.postStoreEdited()
        return (count, total)
    }

    static var timingDatabase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("info.eurocomp.Timing2/SQLite.db")
    }

    func importFromTiming() -> Int {
        var source: OpaquePointer?
        guard sqlite3_open_v2(Store.timingDatabase.path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_close(source) }

        lock.lock(); defer { lock.unlock() }
        var earliest = Double.greatestFiniteMagnitude
        if let stmt = prepare("SELECT MIN(start) FROM activity") {
            if sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL { earliest = sqlite3_column_double(stmt, 0) }
            sqlite3_finalize(stmt)
        }

        var read: OpaquePointer?
        let sql = """
        SELECT x.startDate, x.endDate, COALESCE(a.bundleIdentifier, a.executable, ''), COALESCE(a.title, ''), COALESCE(t.stringValue, ''), COALESCE(p.stringValue, '')
        FROM AppActivity x JOIN Application a ON a.id = x.applicationID
        LEFT JOIN Title t ON t.id = x.titleID LEFT JOIN Path p ON p.id = x.pathID
        WHERE x.isDeleted = 0 AND x.endDate <= ? ORDER BY x.startDate
        """
        guard sqlite3_prepare_v2(source, sql, -1, &read, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(read) }
        sqlite3_bind_double(read, 1, earliest)

        guard let insert = prepare("INSERT INTO activity(start,end,bundle,app,title,path) VALUES(?,?,?,?,?,?)") else { return 0 }
        defer { sqlite3_finalize(insert) }
        exec("BEGIN")
        var count = 0
        while sqlite3_step(read) == SQLITE_ROW {
            var bundle = text(read, 2)
            var app = text(read, 3)
            if bundle.hasPrefix("/") {
                app = app.isEmpty ? (bundle as NSString).lastPathComponent : app
                bundle = (bundle as NSString).lastPathComponent
            }
            if bundle.isEmpty { bundle = app.isEmpty ? "unknown" : app }
            if app.isEmpty { app = bundle }
            if Store.isHidden(bundle) { continue }
            let title = Extractor.cleanTitle(text(read, 4), appName: app)
            sqlite3_reset(insert)
            sqlite3_bind_double(insert, 1, sqlite3_column_double(read, 0))
            sqlite3_bind_double(insert, 2, sqlite3_column_double(read, 1))
            sqlite3_bind_text(insert, 3, bundle, -1, transient)
            sqlite3_bind_text(insert, 4, app, -1, transient)
            sqlite3_bind_text(insert, 5, title, -1, transient)
            sqlite3_bind_text(insert, 6, text(read, 5), -1, transient)
            if sqlite3_step(insert) == SQLITE_DONE { count += 1 }
        }
        exec("COMMIT")
        refreshLongest()
        NotificationCenter.default.postStoreEdited()
        return count
    }

    private func text(_ stmt: OpaquePointer?, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }
}
