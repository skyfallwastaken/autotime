import AppKit
import SQLite3

struct ImportedInterval {
    var start: Date
    var end: Date
    var bundleID: String
}

enum ScreenTimeImporter {
    enum Failure: Error {
        case noAccess
        case noData
    }

    static let maxSession: TimeInterval = 3 * 3600

    static var biomeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Biome/streams/restricted/App.InFocus/local")
    }

    static var knowledgeDatabase: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Knowledge/knowledgeC.db")
    }

    static func load() -> Result<[ImportedInterval], Failure> {
        let biome = biomeIntervals()
        let knowledge = knowledgeIntervals()
        if biome == nil && knowledge == nil { return .failure(.noAccess) }
        var intervals = knowledge ?? []
        let knowledgeStart = intervals.map(\.start).min() ?? .distantFuture
        if var biome {
            if let screenOn = backlitIntervals() { biome = clip(biome, to: screenOn) }
            intervals += biome.filter { $0.end <= knowledgeStart }.map { b in
                var b = b
                b.end = min(b.end, knowledgeStart)
                return b
            }
        }
        intervals.removeAll { Store.isHidden($0.bundleID) || $0.end <= $0.start }
        return intervals.isEmpty ? .failure(.noData) : .success(intervals.sorted { $0.start < $1.start })
    }

    private static func clip(_ intervals: [ImportedInterval], to on: [(Date, Date)]) -> [ImportedInterval] {
        var result: [ImportedInterval] = []
        var j = 0
        for i in intervals.sorted(by: { $0.start < $1.start }) {
            while j < on.count && on[j].1 <= i.start { j += 1 }
            var k = j
            while k < on.count && on[k].0 < i.end {
                let s = max(i.start, on[k].0)
                let e = min(i.end, on[k].1)
                if e > s { result.append(ImportedInterval(start: s, end: e, bundleID: i.bundleID)) }
                k += 1
            }
        }
        return result
    }

    private static func backlitIntervals() -> [(Date, Date)]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(knowledgeDatabase.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT ZSTARTDATE, ZENDDATE FROM ZOBJECT WHERE ZSTREAMNAME = '/display/isBacklit' AND ZVALUEINTEGER = 1 ORDER BY ZSTARTDATE"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var result: [(Date, Date)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let s = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 0))
            let e = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1))
            if e > s { result.append((s, e)) }
        }
        return result.isEmpty ? nil : result
    }

    static func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID), let bundle = Bundle(url: url) {
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            if let name, !name.isEmpty { return name }
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID.components(separatedBy: ".").last ?? bundleID
    }

    private struct Event {
        var date: Date
        var bundleID: String
        var starting: Bool
    }

    private static func biomeIntervals() -> [ImportedInterval]? {
        let fm = FileManager.default
        let dirs = [biomeDirectory, biomeDirectory.appendingPathComponent("tombstone")]
        var files: [URL] = []
        var readable = false
        for dir in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            readable = true
            files += names.map { dir.appendingPathComponent($0) }.filter { !$0.hasDirectoryPath && $0.lastPathComponent != "lock" }
        }
        guard readable else { return nil }

        var events: [Event] = []
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            events += parseSEGB(data)
        }
        if events.isEmpty && !files.isEmpty && files.allSatisfy({ (try? Data(contentsOf: $0)) == nil }) { return nil }
        return intervals(from: events)
    }

    private static func parseSEGB(_ data: Data) -> [Event] {
        let bytes = [UInt8](data)
        guard bytes.count > 32, bytes[0] == 0x53, bytes[1] == 0x45, bytes[2] == 0x47, bytes[3] == 0x42 else { return [] }
        let count = Int(readUInt32(bytes, 4))
        let dataStart = 32
        var events: [Event] = []
        var previousEnd = 0
        for i in 0..<count {
            let trailer = bytes.count - 16 * (i + 1)
            guard trailer > dataStart else { break }
            let end = Int(readUInt32(bytes, trailer))
            let state = readUInt32(bytes, trailer + 4)
            let recordStart = dataStart + (previousEnd + 7) / 8 * 8
            let recordEnd = dataStart + end
            previousEnd = end
            guard state == 1, recordEnd <= bytes.count, recordEnd - recordStart > 8 else { continue }
            let payload = Array(bytes[(recordStart + 8)..<recordEnd])
            if let event = parseInFocus(payload) { events.append(event) }
        }
        return events
    }

    private static func parseInFocus(_ p: [UInt8]) -> Event? {
        var i = 0
        var starting: Bool?
        var time: Double?
        var bundle: String?
        while i < p.count {
            guard let (key, next) = varint(p, i) else { break }
            i = next
            let field = key >> 3
            switch key & 7 {
            case 0:
                guard let (v, n) = varint(p, i) else { return nil }
                if field == 3 { starting = v == 1 }
                i = n
            case 1:
                guard i + 8 <= p.count else { return nil }
                if field == 4 { time = Double(bitPattern: readUInt64(p, i)) }
                i += 8
            case 2:
                guard let (len, n) = varint(p, i), n + Int(len) <= p.count else { return nil }
                if field == 6 { bundle = String(bytes: p[n..<(n + Int(len))], encoding: .utf8) }
                i = n + Int(len)
            case 5:
                i += 4
            default:
                return nil
            }
        }
        guard let starting, let time, let bundle, !bundle.isEmpty else { return nil }
        return Event(date: Date(timeIntervalSinceReferenceDate: time), bundleID: bundle, starting: starting)
    }

    private static func intervals(from events: [Event]) -> [ImportedInterval] {
        var result: [ImportedInterval] = []
        var open: (bundle: String, start: Date)?
        func close(_ date: Date) {
            guard let o = open else { return }
            let end = min(date, o.start.addingTimeInterval(maxSession))
            if end > o.start { result.append(ImportedInterval(start: o.start, end: end, bundleID: o.bundle)) }
            open = nil
        }
        for e in events.sorted(by: { $0.date == $1.date ? !$0.starting && $1.starting : $0.date < $1.date }) {
            if e.starting {
                close(e.date)
                open = (e.bundleID, e.date)
            } else if open?.bundle == e.bundleID {
                close(e.date)
            }
        }
        return result
    }

    private static func knowledgeIntervals() -> [ImportedInterval]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(knowledgeDatabase.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT ZSTARTDATE, ZENDDATE, ZVALUESTRING FROM ZOBJECT WHERE ZSTREAMNAME = '/app/usage' AND ZVALUESTRING IS NOT NULL ORDER BY ZSTARTDATE"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var result: [ImportedInterval] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 2) else { continue }
            let start = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 0))
            let end = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1))
            guard end > start, end.timeIntervalSince(start) <= maxSession else { continue }
            result.append(ImportedInterval(start: start, end: end, bundleID: String(cString: c)))
        }
        return result
    }

    private static func varint(_ p: [UInt8], _ start: Int) -> (UInt64, Int)? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var i = start
        while i < p.count && shift < 64 {
            let b = p[i]
            value |= UInt64(b & 0x7f) << shift
            i += 1
            if b & 0x80 == 0 { return (value, i) }
            shift += 7
        }
        return nil
    }

    private static func readUInt32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    private static func readUInt64(_ b: [UInt8], _ o: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[o + $1]) << (8 * UInt64($1)) }
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
