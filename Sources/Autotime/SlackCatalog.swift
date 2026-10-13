import AppKit
import CryptoKit
import SwiftUI

/// What Slack's desktop app knows about channels and people, read from its own files so nothing touches the network.
/// Slack (and Taut, built on it) persists its Redux store in IndexedDB as Snappy-compressed, V8-serialised blobs:
/// channels carry `is_private`, members their avatar URLs. The avatars themselves come from the app's HTTP cache.
/// Members drop out of that store over time, so everything found is remembered on disk.
final class SlackCatalog {
    static let shared = SlackCatalog()
    static let bundleIDs: Set<String> = ["com.tinyspeck.slackmacgap", "app.jer.taut"]

    private struct Saved: Codable {
        var channels: [String: Bool] = [:]
        var avatars: [String: [String]] = [:]
    }

    private let lock = NSLock()
    /// Held for a whole scan, so lookups made while one runs wait for its results.
    private let scanLock = NSLock()
    private var saved: Saved
    private var scanned: [URL: Date] = [:]
    private var lastScan = Date.distantPast

    private static let savedURL = WebIcons.cacheDir.appendingPathComponent("slack-catalog.json")

    private static let profiles: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            "Library/Application Support/Slack",
            "Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Application Support/Slack",
            "Library/Application Support/Taut/profile",
        ].map { home.appendingPathComponent($0) }
    }()

    private init() {
        saved = (try? Data(contentsOf: Self.savedURL)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
    }

    private static func key(_ workspace: String, _ name: String) -> String { workspace + "\u{1}" + name }

    func isPrivate(workspace: String, channel: String) -> Bool? {
        refresh()
        lock.lock(); defer { lock.unlock() }
        return saved.channels[Self.key(workspace, channel)]
    }

    /// The avatar of the person a DM titled `name` is with, from whichever of their sizes Slack has cached.
    func avatar(workspace: String, name: String) -> Data? {
        refresh()
        lock.lock()
        let urls = saved.avatars[Self.key(workspace, name)] ?? []
        lock.unlock()
        for case let url? in urls.map(URL.init(string:)) {
            for profile in Self.profiles {
                if let data = Self.cachedBody(url, in: profile.appendingPathComponent("Cache/Cache_Data")), NSImage(data: data) != nil {
                    return data
                }
            }
        }
        return nil
    }

    /// Re-reads stores that changed since the last look, at most once a minute.
    private func refresh() {
        scanLock.lock(); defer { scanLock.unlock() }
        guard Date().timeIntervalSince(lastScan) > 60 else { return }
        lastScan = Date()

        var blobs: [(URL, Date)] = []
        for profile in Self.profiles {
            let dir = profile.appendingPathComponent("IndexedDB/https_app.slack.com_0.indexeddb.blob")
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for case let file as URL in e {
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let modified = values.contentModificationDate, (values.fileSize ?? 0) > 10_000, scanned[file] != modified else { continue }
                blobs.append((file, modified))
            }
        }
        guard !blobs.isEmpty else { return }
        // Oldest first, so the newest store's view of a channel or person wins.
        var found = Saved()
        var ranks = Ranks()
        for (file, _) in blobs.sorted(by: { ($0.1, $0.0.path) < ($1.1, $1.0.path) }) {
            guard let store = Self.store(file) else { continue }
            Self.index(store, into: &found, ranks: &ranks)
        }
        for (file, modified) in blobs { scanned[file] = modified }
        lock.lock()
        let changed = found.channels.contains { saved.channels[$0.key] != $0.value } || found.avatars.contains { saved.avatars[$0.key] != $0.value }
        saved.channels.merge(found.channels) { _, new in new }
        saved.avatars.merge(found.avatars) { _, new in new }
        let snapshot = saved
        lock.unlock()
        // Slack rewrites its store every few minutes, but what's kept here rarely changes.
        guard changed else { return }
        if let json = try? JSONEncoder().encode(snapshot) { try? json.write(to: Self.savedURL, options: .atomic) }
    }

    /// Where several channels or people share a name, how good a match each one found so far was; lower is better.
    private struct Ranks {
        var channels: [String: (Int, Double, String)] = [:]
        var avatars: [String: (Int, String)] = [:]
    }

    private static func index(_ store: [String: Any], into found: inout Saved, ranks: inout Ranks) {
        let teams = (store["teams"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? [String: Any])?["name"] as? String }
        let channels = (store["channels"] as? [String: Any] ?? [:]).values.compactMap { $0 as? [String: Any] }
        let dmPartners = Set(channels.filter { $0["is_im"] as? Bool == true }.compactMap { $0["user"] as? String })
        // A title can't tell same-named channels apart, so take one the user is in, then one still open, then the
        // most recently updated, then the lowest ID so every scan agrees.
        for c in channels {
            guard c["is_channel"] as? Bool == true, c["is_mpim"] as? Bool != true,
                  let team = (c["context_team_id"] as? String).flatMap({ teams[$0] }), let name = c["name"] as? String else { continue }
            let rank = ((c["is_member"] as? Bool == true ? 0 : 2) + (c["is_archived"] as? Bool == true ? 1 : 0),
                        -(c["updated"] as? Double ?? 0), c["id"] as? String ?? "")
            let k = key(team, name)
            if ranks.channels[k].map({ rank <= $0 }) ?? true { ranks.channels[k] = rank; found.channels[k] = c["is_private"] as? Bool ?? false }
        }
        // Slack titles a DM by display name, falling back to the full name. Where names clash, the person there's a DM
        // with wins, then a current member over a deactivated one, then the lowest ID so every scan agrees.
        for case let m as [String: Any] in (store["members"] as? [String: Any] ?? [:]).values {
            guard let team = (m["team_id"] as? String).flatMap({ teams[$0] }), let profile = m["profile"] as? [String: Any] else { continue }
            let urls = ["48", "72", "32"].compactMap { profile["image_" + $0] as? String }
            guard !urls.isEmpty else { continue }
            let names = [profile["display_name"], profile["real_name"], m["real_name"], m["name"]].compactMap { $0 as? String }.filter { !$0.isEmpty }
            for (rank, name) in names.enumerated() {
                let id = m["id"] as? String ?? ""
                let score = (rank + (m["deleted"] as? Bool == true ? 10 : 0) + (dmPartners.contains(id) ? 0 : 100), id)
                let k = key(team, name)
                if ranks.avatars[k].map({ score <= $0 }) ?? true { ranks.avatars[k] = score; found.avatars[k] = urls }
            }
        }
    }

    // MARK: Chromium's HTTP cache

    /// The "simple" cache names each entry after the first 8 bytes of the SHA-1 of its key, read as a little-endian integer.
    /// An entry is a header, the key, the body, an end-of-stream record, then the response headers and a final record.
    static func cachedBody(_ url: URL, in dir: URL) -> Data? {
        let key = "1/0/" + url.absoluteString
        let hash = Insecure.SHA1.hash(data: Data(key.utf8)).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        let file = dir.appendingPathComponent(String(format: "%016llx_0", UInt64(littleEndian: hash)))
        guard let data = try? Data(contentsOf: file), data.count > 48 else { return nil }
        func u32(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 | Int(data[at + 2]) << 16 | Int(data[at + 3]) << 24 }
        let eofMagic: [UInt8] = [0xd8, 0x41, 0x0d, 0x97, 0x45, 0x6f, 0xfa, 0xf4]
        let keyLength = u32(12)
        let last = data.count - 24
        guard data.count > 24 + keyLength, Array(data[last..<last + 8]) == eofMagic,
              data[24..<24 + keyLength].elementsEqual(key.utf8) else { return nil }
        let hasKeyHash = u32(last + 8) & 2 != 0
        let bodyEnd = last - (hasKeyHash ? 32 : 0) - u32(last + 16) - 24
        guard bodyEnd >= 24 + keyLength, Array(data[bodyEnd..<bodyEnd + 8]) == eofMagic else { return nil }
        return data.subdata(in: 24 + keyLength..<bodyEnd)
    }

    // MARK: IndexedDB values

    /// The parts of a stored Redux state `index` reads. The rest of the 40MB store is decoded and walked past, a byte at a time, without being kept.
    private static let wanted: V8Keep = .fields([
        "teams": .each(.fields(["name": .all])),
        "channels": .each(.fields([
            "id": .all, "name": .all, "context_team_id": .all, "is_channel": .all, "is_mpim": .all, "is_im": .all, "user": .all,
            "is_private": .all, "is_member": .all, "is_archived": .all, "updated": .all,
        ])),
        "members": .each(.fields([
            "id": .all, "name": .all, "real_name": .all, "deleted": .all, "team_id": .all,
            "profile": .fields(["display_name": .all, "real_name": .all, "image_48": .all, "image_72": .all, "image_32": .all]),
        ])),
    ])

    /// The parts of a stored Redux state this catalog uses, or nil if the blob isn't one.
    static func store(_ file: URL) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        // Blink's wrapper: 0xff 0x11 0x02 marks a Snappy-compressed value.
        let compressed = (try? handle.read(upToCount: 3)) == Data([0xff, 0x11, 0x02])
        if !compressed { try? handle.seek(toOffset: 0) }
        let input = ByteStream.file(handle)
        var reader = V8Reader(compressed ? .snappy(input) : input)
        return reader.read(wanted) as? [String: Any]
    }
}

/// Bytes made in batches by `produce`, which appends to `buffer`. Bytes already read are dropped as they pile up,
/// except the last `keep` made, which Snappy's copies refer back to.
struct ByteStream {
    private(set) var buffer: [UInt8] = []
    private(set) var pos = 0
    private let keep: Int
    private let produce: (inout [UInt8]) -> Bool

    init(keep: Int = 0, produce: @escaping (inout [UInt8]) -> Bool) {
        self.keep = keep
        self.produce = produce
    }

    var available: Int { buffer.count - pos }

    /// Makes at least `n` bytes available, or returns false at the end of the stream.
    @inline(__always) mutating func ensure(_ n: Int) -> Bool {
        available >= n || refill(n)
    }

    private mutating func refill(_ n: Int) -> Bool {
        while available < n {
            if pos >= 1 << 17 {
                let drop = min(pos, buffer.count - keep)
                if drop > 0 { buffer.removeSubrange(0..<drop); pos -= drop }
            }
            if !produce(&buffer) { return false }
        }
        return true
    }

    @inline(__always) mutating func byte() -> UInt8? {
        guard ensure(1) else { return nil }
        defer { pos += 1 }
        return buffer[pos]
    }

    @inline(__always) mutating func peek() -> UInt8? {
        ensure(1) ? buffer[pos] : nil
    }

    mutating func take(_ n: Int) -> ArraySlice<UInt8>? {
        guard ensure(n) else { return nil }
        defer { pos += n }
        return buffer[pos..<pos + n]
    }

    mutating func skip(_ n: Int) -> Bool {
        if n <= available { pos += n; return true }
        var n = n
        while n > 0 {
            guard ensure(1) else { return false }
            let k = min(n, available)
            pos += k
            n -= k
        }
        return true
    }

    /// A file, 64KB at a time.
    static func file(_ handle: FileHandle) -> ByteStream {
        ByteStream { buffer in
            // FileHandle autoreleases what it reads, which would otherwise pile up until the whole file is read.
            autoreleasepool {
                guard let data = try? handle.read(upToCount: 1 << 16), !data.isEmpty else { return false }
                buffer.append(contentsOf: data)
                return true
            }
        }
    }

    /// Raw Snappy, decompressed about 64KB at a time. Snappy compresses in 64KB blocks, so copies never reach
    /// further back than the last 64KB made.
    static func snappy(_ input: ByteStream) -> ByteStream {
        final class Box { var input: ByteStream; init(_ input: ByteStream) { self.input = input } }
        let box = Box(input)
        // The uncompressed length comes first; the reader finds the end on its own.
        while let b = box.input.byte(), b >= 0x80 {}
        return ByteStream(keep: 1 << 16) { out in
            // Work on a local copy: Swift checks every access to a captured variable at runtime.
            var input = ByteStream { _ in false }
            swap(&input, &box.input)
            defer { swap(&input, &box.input) }
            // Output goes straight into space grown ahead of it; whatever isn't used is trimmed at the end.
            var w = out.count
            let target = w + (1 << 16)
            defer { out.removeLast(out.count - w) }
            while w < target, let tag = input.byte() {
                func le(_ n: Int) -> Int? {
                    input.take(n).map { $0.reversed().reduce(0) { $0 << 8 | Int($1) } }
                }
                var length: Int, offset = 0
                switch tag & 3 {
                case 0:
                    length = Int(tag >> 2)
                    if length >= 60 { guard let long = le(length - 59) else { return false }; length = long }
                    length += 1
                case 1:
                    guard let low = input.byte() else { return false }
                    length = Int((tag >> 2) & 7) + 4
                    offset = Int(tag >> 5) << 8 | Int(low)
                default:
                    guard let o = le(tag & 3 == 2 ? 2 : 4) else { return false }
                    length = Int(tag >> 2) + 1
                    offset = o
                }
                if out.count < w + length { out.append(contentsOf: repeatElement(0, count: max(length, 1 << 17))) }
                if offset == 0 {
                    guard let bytes = input.take(length) else { return false }
                    out.withUnsafeMutableBufferPointer { p in
                        bytes.withUnsafeBufferPointer { p.baseAddress!.advanced(by: w).update(from: $0.baseAddress!, count: length) }
                    }
                } else {
                    guard offset <= w else { return false }
                    // A copy may overlap what it writes, so go byte by byte.
                    out.withUnsafeMutableBufferPointer { p in
                        for k in w..<w + length { p[k] = p[k - offset] }
                    }
                }
                w += length
            }
            return w > target - (1 << 16)
        }
    }
}

/// Which parts of a value `V8Reader` builds: all of it, some of an object's properties, or every property's value.
indirect enum V8Keep {
    case all
    case fields([String: V8Keep])
    case each(V8Keep)
}

/// Reads V8's structured-clone format (what IndexedDB stores) into Foundation values, building only what `V8Keep` asks for.
struct V8Reader {
    private struct Malformed: Error {}

    private var stream: ByteStream
    /// Objects are numbered in the order they appear, for back-references; skipped ones still take a number.
    private var objects: [Int: Any] = [:]
    private var nextID = 0

    init(_ stream: ByteStream) {
        self.stream = stream
    }

    /// Stops as soon as the top-level properties asked for are all read, leaving the rest of the stream untouched.
    mutating func read(_ keep: V8Keep) -> Any? {
        do {
            // Blink's version header and trailer offset record, then V8's version header.
            while try peek() == 0xff { _ = try byte(); _ = try varint() }
            if try peek() == 0xfe, !stream.skip(13) { throw Malformed() }
            while try peek() == 0xff { _ = try byte(); _ = try varint() }
            guard case .fields(let fields) = keep, try peek() == UInt8(ascii: "o") else { return try value(keep) }
            _ = try byte()
            _ = newObject()
            var o: [String: Any] = [:]
            while try peek() != UInt8(ascii: "{") {
                let k = try value(.all).map { $0 as? String ?? "\($0)" }
                let sub = k.flatMap { fields[$0] }
                let v = try value(sub)
                if sub != nil, let k { o[k] = v }
                if o.count == fields.count { break }
            }
            return o
        } catch {
            return nil
        }
    }

    @inline(__always) private mutating func byte() throws -> UInt8 {
        guard let b = stream.byte() else { throw Malformed() }
        return b
    }

    @inline(__always) private mutating func peek() throws -> UInt8 {
        guard let b = stream.peek() else { throw Malformed() }
        return b
    }

    private mutating func varint() throws -> Int {
        var result = 0, shift = 0
        while shift < 64 {
            let b = try byte()
            result |= Int(b & 0x7f) << shift
            if b < 0x80 { return result }
            shift += 7
        }
        throw Malformed()
    }

    private mutating func newObject() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    /// Moves past a value without building any of it, which is what happens to nearly all of a store.
    private mutating func skip() throws {
        let tag = try byte()
        switch tag {
        case 0x00:
            try skip()
        case 0xff:
            _ = try varint()
            try skip()
        case UInt8(ascii: "_"), UInt8(ascii: "0"), UInt8(ascii: "-"), UInt8(ascii: "T"), UInt8(ascii: "F"):
            return
        case UInt8(ascii: "I"), UInt8(ascii: "U"), UInt8(ascii: "^"):
            _ = try varint()
        case UInt8(ascii: "N"), UInt8(ascii: "D"):
            if tag == UInt8(ascii: "D") { nextID += 1 }
            guard stream.skip(8) else { throw Malformed() }
        case UInt8(ascii: "\""), UInt8(ascii: "S"), UInt8(ascii: "c"):
            guard stream.skip(try varint()) else { throw Malformed() }
        case UInt8(ascii: "o"):
            nextID += 1
            while try peek() != UInt8(ascii: "{") { try skip(); try skip() }
            _ = try byte(); _ = try varint()
        case UInt8(ascii: "A"), UInt8(ascii: "a"):
            nextID += 1
            let dense = tag == UInt8(ascii: "A")
            let count = try varint()
            if dense { for _ in 0..<count { try skip() } }
            let end = dense ? UInt8(ascii: "$") : UInt8(ascii: "@")
            while try peek() != end { try skip(); try skip() }
            _ = try byte(); _ = try varint(); _ = try varint()
        case UInt8(ascii: ";"), UInt8(ascii: "'"):
            nextID += 1
            let end = tag == UInt8(ascii: ";") ? UInt8(ascii: ":") : UInt8(ascii: ",")
            while try peek() != end { try skip() }
            _ = try byte(); _ = try varint()
        default:
            throw Malformed()
        }
    }

    private mutating func value(_ keep: V8Keep?) throws -> Any? {
        guard keep != nil else { try skip(); return nil }
        let tag = try byte()
        switch tag {
        case 0x00: // padding
            return try value(keep)
        case 0xff: // a version header
            _ = try varint()
            return try value(keep)
        case UInt8(ascii: "_"), UInt8(ascii: "0"), UInt8(ascii: "-"): return nil
        case UInt8(ascii: "T"): return true
        case UInt8(ascii: "F"): return false
        case UInt8(ascii: "I"):
            let v = try varint()
            return (v >> 1) ^ -(v & 1)
        case UInt8(ascii: "U"): return try varint()
        case UInt8(ascii: "N"), UInt8(ascii: "D"):
            guard let b = stream.take(8) else { throw Malformed() }
            if tag == UInt8(ascii: "D") { _ = newObject() }
            return b.withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
        case UInt8(ascii: "\""), UInt8(ascii: "S"), UInt8(ascii: "c"):
            let count = try varint()
            guard keep != nil else {
                guard stream.skip(count) else { throw Malformed() }
                return nil
            }
            guard let b = stream.take(count) else { throw Malformed() }
            // Nearly every string (and every key) is ASCII, which Swift decodes far faster than Foundation.
            if tag == UInt8(ascii: "S") || (tag == UInt8(ascii: "\"") && !b.contains { $0 >= 0x80 }) {
                return String(decoding: b, as: UTF8.self)
            }
            return String(bytes: b, encoding: tag == UInt8(ascii: "c") ? .utf16LittleEndian : .isoLatin1)
        case UInt8(ascii: "^"):
            return objects[try varint()]
        case UInt8(ascii: "o"):
            let id = newObject()
            var o: [String: Any] = [:]
            while try peek() != UInt8(ascii: "{") {
                let k = try value(keep == nil ? nil : .all).map { $0 as? String ?? "\($0)" }
                let sub: V8Keep? = switch keep {
                case .all: .all
                case .fields(let f): k.flatMap { f[$0] }
                case .each(let e): e
                case nil: nil
                }
                let v = try value(sub)
                if sub != nil, let k { o[k] = v }
            }
            _ = try byte(); _ = try varint()
            guard keep != nil else { return nil }
            objects[id] = o
            return o
        case UInt8(ascii: "A"), UInt8(ascii: "a"):
            let id = newObject()
            let dense = tag == UInt8(ascii: "A")
            let build = if case .all = keep { true } else { false }
            let count = try varint()
            var a: [Any] = []
            if dense {
                for _ in 0..<count { let v = try value(build ? .all : nil); if build { a.append(v ?? NSNull()) } }
            }
            // Sparse elements and extra properties come as key/value pairs.
            let end = dense ? UInt8(ascii: "$") : UInt8(ascii: "@")
            while try peek() != end { _ = try value(nil); _ = try value(nil) }
            _ = try byte(); _ = try varint(); _ = try varint()
            guard build else { return nil }
            objects[id] = a
            return a
        case UInt8(ascii: ";"), UInt8(ascii: "'"):
            _ = newObject()
            let end = tag == UInt8(ascii: ";") ? UInt8(ascii: ":") : UInt8(ascii: ",")
            while try peek() != end { _ = try value(nil) }
            _ = try byte(); _ = try varint()
            return nil
        default:
            throw Malformed()
        }
    }
}

/// `#` for a public channel, a padlock for a private one, as Slack's sidebar draws them.
struct SlackChannelIcon: View {
    var workspace: String
    var name: String

    @State private var isPrivate: Bool?

    var body: some View {
        Image(systemName: isPrivate == true ? "lock" : "number")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 16, height: 16)
            .task(id: workspace + "\u{1}" + name) {
                let (w, n) = (workspace, name)
                isPrivate = await Task.detached(priority: .utility) { SlackCatalog.shared.isPrivate(workspace: w, channel: n) }.value
            }
    }
}

/// The other person's avatar for a DM, or the member count for a group DM, as Slack shows them.
struct SlackDMIcon: View {
    var workspace: String
    var name: String

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else if name.contains(", ") {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.quaternary)
                    .overlay(Text("\(name.components(separatedBy: ", ").count)").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary))
            } else {
                Image(systemName: "person.crop.square.fill").resizable().foregroundStyle(.tertiary)
            }
        }
        .frame(width: 16, height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .task(id: workspace + "\u{1}" + name) {
            image = await WebIcons.shared.slackAvatar(workspace: workspace, name: name)
        }
    }
}
