import AppKit
import SwiftUI

enum NodeKind: Hashable {
    case category(String)
    case project(UUID)
    case app(String)
    case domain(String)
    case url(String)
    case xUser(String)
    case githubRepo(String)
    case ampProject(String)
    case ampThread(project: String, title: String)
    case ampPuck
    case slackChannel(workspace: String, name: String)
    case slackDM(workspace: String, name: String)
    case file(String)
    /// Siblings too short to show on their own, grouped so a parent's children still add up to it.
    case others
    case segment
    case title
    case none
}

struct PathComponent: Hashable {
    var label: String
    var kind: NodeKind
}

enum ActivityPath {
    static let noInfo = "(No additional information available)"

    static func components(path: String, title: String) -> [String] {
        parts(path: path, title: title).map(\.label)
    }

    static func parts(path: String, title: String, sharedSegments: [String: Set<String>] = [:]) -> [PathComponent] {
        var result: [PathComponent] = []
        if !path.isEmpty {
            if let url = URL(string: path), let scheme = url.scheme, scheme == "http" || scheme == "https", let host = url.host {
                // Web pages: domain › (account or repo) › page, labelled by its cleaned-up title rather than the raw URL.
                result.append(PathComponent(label: host, kind: .domain(host)))
                var group: String?
                if let handle = xHandle(url) {
                    group = "@" + handle
                    result.append(PathComponent(label: "@" + handle, kind: .xUser(handle)))
                } else if let repo = githubRepo(url) {
                    group = repo
                    result.append(PathComponent(label: repo, kind: .githubRepo(repo)))
                }
                var page = cleanTitle(title, host: host, group: group, shared: sharedSegments[host] ?? [])
                if group?.hasPrefix("@") == true, let media = xMediaLabel(url), xGenericTitles.contains(page) { page = media }
                result.append(PathComponent(label: page.isEmpty ? displayURL(url) : page, kind: .url(path)))
                return result
            } else if let url = URL(string: path), url.isFileURL {
                result.append(PathComponent(label: abbreviate(url.path, directory: url.hasDirectoryPath), kind: .file(url.path)))
            } else if path.contains(Extractor.separator) {
                result += path.components(separatedBy: Extractor.separator).map { PathComponent(label: $0, kind: .segment) }
            } else {
                result.append(PathComponent(label: path, kind: .segment))
            }
        }
        if !title.isEmpty, result.last?.label != title {
            result.append(PathComponent(label: title, kind: .title))
        }
        if result.isEmpty {
            result.append(PathComponent(label: noInfo, kind: .none))
        }
        return result
    }

    // MARK: Page titles

    private static let titleSeparators = [" | ", " - ", " — ", " – ", " · ", " • ", " / ", " // ", " :: "]
    private static let titleSeparatorBytes = titleSeparators.map { Array($0.utf8) }

    /// The UTF-8 offsets of the first (or last) title separator in `bytes`. Compares bytes rather than using
    /// `range(of:)`, which steps through grapheme clusters and was most of the cost of building a day's list.
    private static func separatorRange(in bytes: [UInt8], backwards: Bool) -> (Int, Int)? {
        var best: (Int, Int)?
        for sep in titleSeparatorBytes where sep.count <= bytes.count {
            var i = backwards ? bytes.count - sep.count : 0
            while i >= 0 && i <= bytes.count - sep.count {
                if bytes[i] == sep[0], bytes[i..<i + sep.count].elementsEqual(sep) {
                    if best.map({ backwards ? i > $0.0 : i < $0.0 }) ?? true { best = (i, i + sep.count) }
                    break
                }
                i += backwards ? -1 : 1
            }
        }
        return best
    }

    static func segments(_ title: String) -> [String] {
        var parts = [title]
        for sep in titleSeparators { parts = parts.flatMap { $0.components(separatedBy: sep) } }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Strips what browsers' window titles repeat on every page: unread counts like "(3)", the site's name
    /// ("| Proton Mail", "· GitHub", "/ X"), the account or repo the page is already grouped under,
    /// and segments most of the host's titles share (such as the signed-in email address).
    static func cleanTitle(_ title: String, host: String, group: String?, shared: Set<String>) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "^\\(\\d+\\+?\\)\\s*", with: "", options: .regularExpression)
        func redundant(_ segment: Substring) -> Bool {
            let s = segment.trimmingCharacters(in: .whitespaces)
            return isSiteName(s, host: host) || shared.contains(s.lowercased()) || s.caseInsensitiveCompare(group ?? "") == .orderedSame
        }
        func split(_ t: String, backwards: Bool) -> (head: Substring, tail: Substring)? {
            guard let (lower, upper) = separatorRange(in: Array(t.utf8), backwards: backwards) else { return nil }
            let u = t.utf8
            return (t[..<u.index(u.startIndex, offsetBy: lower)], t[u.index(u.startIndex, offsetBy: upper)...])
        }
        for _ in 0..<4 {
            guard let (head, tail) = split(t, backwards: true), !head.trimmingCharacters(in: .whitespaces).isEmpty, redundant(tail) else { break }
            t = String(head)
        }
        if let (head, tail) = split(t, backwards: false), !tail.trimmingCharacters(in: .whitespaces).isEmpty, redundant(head) {
            t = String(tail)
        }
        if let group, group.hasPrefix("@") {
            // Tweets: `Name on X: "text"` → the text; profiles: `Name (@handle)` → Profile.
            if t.range(of: "^.+? on (X|Twitter): \".*\"$", options: .regularExpression) != nil {
                t = t.replacingOccurrences(of: "(?s)^.+? on (?:X|Twitter): \"(.*)\"$", with: "$1", options: .regularExpression)
            } else if t.lowercased().hasSuffix("(\(group.lowercased()))") {
                t = "Profile"
            }
        } else if let group, let name = group.split(separator: "/").last {
            // GitHub: `owner/repo: description` → description; `repo/path/file.swift at main` → path/file.swift
            if t.lowercased().hasPrefix(group.lowercased() + ": ") { t.removeFirst(group.count + 2) }
            if t.lowercased().hasPrefix(name.lowercased() + "/") { t.removeFirst(name.count + 1) }
            t = t.replacingOccurrences(of: " at [^ ]+$", with: "", options: .regularExpression)
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Whether a title segment is just the site's name: "GitHub" on github.com, "Proton Mail" on mail.proton.me, "X" on x.com.
    private static func isSiteName(_ segment: String, host: String) -> Bool {
        let key = segment.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !key.isEmpty, segment.count <= 30 else { return false }
        let labels = host.lowercased().split(separator: ".").map(String.init).filter { $0 != "www" }
        if labels.contains(key) || labels.joined().contains(key) && key.count >= 4 { return true }
        return labels.dropLast().contains { $0.count >= 4 && key.contains($0) }
    }

    /// Title segments that most pages on a host share, which say nothing about the page itself.
    static func sharedTitleSegments(_ activities: [Activity], labels: LabelCache = LabelCache()) -> [String: Set<String>] {
        var titles: [String: Set<String>] = [:]
        for a in activities where !a.title.isEmpty {
            guard let host = labels.webHost(a.path) else { continue }
            titles[host, default: []].insert(a.title)
        }
        var result: [String: Set<String>] = [:]
        for (host, set) in titles where set.count >= 2 {
            var counts: [String: Int] = [:]
            for t in set { for seg in labels.trailingSegments(t) { counts[seg, default: 0] += 1 } }
            let common = counts.filter { $0.value >= 2 && $0.value * 2 >= set.count }.keys
            if !common.isEmpty { result[host] = Set(common) }
        }
        return result
    }

    // MARK: Sites

    private static let githubReserved: Set<String> = [
        "settings", "notifications", "orgs", "organizations", "marketplace", "explore", "topics", "sponsors", "features",
        "pulls", "issues", "login", "logout", "signup", "join", "new", "codespaces", "search", "apps", "enterprise", "pricing",
        "about", "collections", "trending", "account", "dashboard", "users", "stars", "watching", "security", "readme", "site",
        "contact", "team", "events", "resources", "solutions", "copilot", "models", "github-copilot", "customer-stories", "sessions",
    ]

    /// "owner/repo" for github.com/<owner>/<repo>/…
    static func githubRepo(_ url: URL) -> String? {
        guard let host = url.host?.lowercased(), host == "github.com" || host == "www.github.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, !githubReserved.contains(parts[0].lowercased()) else { return nil }
        let valid = { (s: String) in s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }
        guard valid(parts[0]), valid(parts[1]) else { return nil }
        return parts[0] + "/" + parts[1]
    }

    static let xHosts: Set<String> = ["x.com", "twitter.com", "mobile.x.com", "mobile.twitter.com"]
    private static let xReserved: Set<String> = [
        "home", "explore", "notifications", "messages", "i", "search", "settings", "compose", "login", "logout",
        "signup", "tos", "privacy", "hashtag", "intent", "share", "account", "lists", "bookmarks", "communities",
        "premium", "jobs", "grok", "topics", "about", "download", "help", "following", "followers", "who_to_follow",
    ]

    /// Titles of X's own pages. Photos and posts opened as overlays keep the page's title (often "Home"), so the URL says more.
    private static let xGenericTitles: Set<String> = ["Home", "Explore", "Notifications", "Search", "Bookmarks", "Messages", "X", ""]

    static func xMediaLabel(_ url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 3, parts[1] == "status" else { return nil }
        if parts.count >= 5, parts[3] == "photo" { return "Photo" }
        if parts.count >= 5, parts[3] == "video" { return "Video" }
        return "Post"
    }

    /// The account an x.com URL belongs to (x.com/<handle>/…), or nil for app pages like /home.
    static func xHandle(_ url: URL) -> String? {
        guard let host = url.host?.lowercased(), xHosts.contains(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let first = parts.first, (1...15).contains(first.count), !xReserved.contains(first.lowercased()),
              first.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return nil }
        return first
    }

    static func displayURL(_ url: URL) -> String {
        var s = url.absoluteString
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        return s
    }

    static func abbreviate(_ path: String, directory: Bool) -> String {
        let home = NSHomeDirectory()
        var p = path
        if p.hasPrefix(home) { p = "~" + p.dropFirst(home.count) }
        if directory, !p.hasSuffix("/") { p += "/" }
        return p
    }

    static func primaryLabel(_ a: Activity) -> String {
        let p = parts(path: a.path, title: a.title)
        if let first = p.first, case .domain = first.kind {
            let title = cleanTitle(a.title, host: first.label, group: nil, shared: [])
            return title.isEmpty ? first.label : "\(title) — \(first.label)"
        }
        if p.first?.kind == NodeKind.none { return a.appName }
        return p.map(\.label).joined(separator: " › ")
    }
}

/// Labels derived from activities' paths and titles, remembered across rebuilds of a day's lists.
/// A day repeats the same few hundred paths and titles thousands of times, and each label means parsing a URL and a title.
/// Labels depend only on the activity, so they stay valid from one day to the next.
final class LabelCache {
    private struct PartsKey: Hashable {
        var path: String
        var title: String
        var shared: Set<String>
    }

    private var hosts: [String: String?] = [:]
    private var parts: [PartsKey: [PathComponent]] = [:]
    private var topics: [String: String] = [:]
    private var primary: [String: String] = [:]
    private var trailing: [String: Set<String>] = [:]

    var count: Int { hosts.count + parts.count + topics.count + primary.count + trailing.count }

    /// A title's segments after the first, lowercased, for `sharedTitleSegments`.
    func trailingSegments(_ title: String) -> Set<String> {
        if let s = trailing[title] { return s }
        let s = Set(ActivityPath.segments(title).dropFirst().map { $0.lowercased() })
        trailing[title] = s
        return s
    }

    /// The host of an http(s) URL, as `sharedTitleSegments` groups titles by.
    func webHost(_ path: String) -> String? {
        if let h = hosts[path] { return h }
        var host: String?
        if let url = URL(string: path), url.scheme?.hasPrefix("http") == true { host = url.host }
        hosts[path] = host
        return host
    }

    func parts(_ a: Activity, shared: [String: Set<String>]) -> [PathComponent] {
        let set = webHost(a.path).flatMap { shared[$0] } ?? []
        let key = PartsKey(path: a.path, title: a.title, shared: set)
        if let p = parts[key] { return p }
        let p = ActivityPath.parts(path: a.path, title: a.title, sharedSegments: shared)
        parts[key] = p
        return p
    }

    func topic(_ a: Activity) -> String {
        let key = a.appName + "\u{1}" + a.title + "\u{1}" + a.path
        if let t = topics[key] { return t }
        let t = Blocks.topicLabel(a)
        topics[key] = t
        return t
    }

    func primaryLabel(_ a: Activity) -> String {
        let key = a.appName + "\u{1}" + a.title + "\u{1}" + a.path
        if let l = primary[key] { return l }
        let l = ActivityPath.primaryLabel(a)
        primary[key] = l
        return l
    }
}

struct TreeNode: Identifiable {
    var id: String
    var label: String
    var kind: NodeKind
    var bundleID: String
    var duration: TimeInterval
    var children: [TreeNode]
}

enum ViewMode: String, CaseIterable, Identifiable {
    case unified = "Unified"
    case category = "By Category"
    case project = "By Project"
    case chronological = "Chronological"
    var id: String { rawValue }
}

enum TreeBuilder {
    private final class Builder {
        var label: String
        var kind: NodeKind
        var bundleID: String
        var duration: TimeInterval = 0
        var order: [String] = []
        var children: [String: Builder] = [:]

        init(label: String, kind: NodeKind, bundleID: String) {
            self.label = label
            self.kind = kind
            self.bundleID = bundleID
        }

        func child(_ key: String, label: String, kind: NodeKind, bundleID: String) -> Builder {
            if let c = children[key] { return c }
            let c = Builder(label: label, kind: kind, bundleID: bundleID)
            children[key] = c
            order.append(key)
            return c
        }

        func build(id: String) -> TreeNode {
            var kids = order.map { key in children[key]!.build(id: id + "/" + key) }
                .sorted { $0.duration > $1.duration }
            // A long tail of "<1m" rows hides how the total adds up, so fold it into one row.
            if let cut = kids.firstIndex(where: { $0.duration < 60 }), cut > 0, kids.count - cut >= 2 {
                let small = Array(kids[cut...])
                kids.removeSubrange(cut...)
                kids.append(TreeNode(id: id + "/~others", label: "\(small.count) more", kind: .others, bundleID: bundleID,
                                     duration: small.reduce(0) { $0 + $1.duration }, children: small))
            }
            return TreeNode(id: id, label: label, kind: kind, bundleID: bundleID, duration: duration, children: kids)
        }
    }

    /// `project` places activities under their project in `.project` mode.
    static func build(_ activities: [Activity], mode: ViewMode, labels: LabelCache = LabelCache(), project: (Activity) -> Project? = { _ in nil }) -> [TreeNode] {
        let root = Builder(label: "", kind: .none, bundleID: "")
        let shared = ActivityPath.sharedTitleSegments(activities, labels: labels)
        for a in activities {
            var node = root
            node.duration += a.duration
            if mode == .category {
                let cat = AppCatalog.shared.category(for: a.bundleID)
                node = node.child("c:" + cat, label: cat, kind: .category(cat), bundleID: "")
                node.duration += a.duration
            } else if mode == .project {
                if let p = project(a) {
                    node = node.child("p:" + p.id.uuidString, label: p.name, kind: .project(p.id), bundleID: "")
                } else {
                    node = node.child("p:", label: "No Project", kind: .project(Project.unassigned), bundleID: "")
                }
                node.duration += a.duration
            }
            node = node.child("a:" + a.bundleID, label: a.appName, kind: .app(a.bundleID), bundleID: a.bundleID)
            node.duration += a.duration
            var parts = labels.parts(a, shared: shared)
            if a.bundleID == AmpExtractor.bundleID, parts.count >= 2, parts[0].kind == .segment {
                parts[0].kind = .ampProject(parts[0].label)
                if parts[1].kind == .segment { parts[1].kind = .ampThread(project: parts[0].label, title: parts[1].label) }
            } else if a.bundleID == AmpExtractor.bundleID, a.path == AmpExtractor.puck {
                parts[0].kind = .ampPuck
            } else if SlackCatalog.bundleIDs.contains(a.bundleID), parts.count >= 2, parts[0].kind == .segment, parts[1].kind == .segment {
                let (workspace, label) = (parts[0].label, parts[1].label)
                if label.hasSuffix(" (Channel)") {
                    parts[1].kind = .slackChannel(workspace: workspace, name: String(label.dropLast(" (Channel)".count)))
                } else if label.hasSuffix(" (DM)") {
                    parts[1].kind = .slackDM(workspace: workspace, name: String(label.dropLast(" (DM)".count)))
                }
            }
            for (i, part) in parts.enumerated() {
                let key = switch part.kind {
                case .xUser(let h): "@" + h.lowercased()
                case .githubRepo(let r): r.lowercased()
                default: part.label
                }
                node = node.child("\(i):" + key, label: part.label, kind: part.kind, bundleID: a.bundleID)
                node.duration += a.duration
            }
        }
        return root.build(id: "root").children
    }
}

struct Session: Identifiable {
    var id: String
    var start: Date
    var end: Date
    var bundleID: String
    var appName: String
    var label: String
    var path: String
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

enum Sessions {
    static func merge(_ activities: [Activity], gap: TimeInterval = 5, labels: LabelCache = LabelCache()) -> [Session] {
        var result: [Session] = []
        for a in activities.sorted(by: { $0.start < $1.start }) {
            let label = labels.primaryLabel(a)
            if var last = result.last, last.bundleID == a.bundleID, last.label == label, a.start.timeIntervalSince(last.end) <= gap {
                last.end = max(last.end, a.end)
                result[result.count - 1] = last
            } else {
                result.append(Session(id: "\(a.id)", start: a.start, end: a.end, bundleID: a.bundleID, appName: a.appName, label: label, path: a.path))
            }
        }
        return result
    }

    static func byApp(_ activities: [Activity], gap: TimeInterval = 30) -> [Session] {
        var result: [Session] = []
        for a in activities.sorted(by: { $0.start < $1.start }) {
            if var last = result.last, last.bundleID == a.bundleID, a.start.timeIntervalSince(last.end) <= gap {
                last.end = max(last.end, a.end)
                result[result.count - 1] = last
            } else {
                result.append(Session(id: "\(a.id)", start: a.start, end: a.end, bundleID: a.bundleID, appName: a.appName, label: a.appName, path: ""))
            }
        }
        return result
    }
}

struct TimelineBlock: Identifiable {
    var id: String
    var start: Date
    var end: Date
    var label: String
    var bundleID: String
    var breakdown: [(String, TimeInterval)]
}

enum Blocks {
    static func build(_ activities: [Activity], gap: TimeInterval = 180, maxLength: TimeInterval = 3600, labels: LabelCache = LabelCache()) -> [TimelineBlock] {
        let sorted = activities.sorted { $0.start < $1.start }
        var groups: [[Activity]] = []
        var lastEnd = Date.distantPast
        for a in sorted {
            if let first = groups.last?.first, a.start.timeIntervalSince(lastEnd) <= gap, a.end.timeIntervalSince(first.start) <= maxLength {
                groups[groups.count - 1].append(a)
                lastEnd = max(lastEnd, a.end)
            } else {
                groups.append([a])
                lastEnd = a.end
            }
        }
        return groups.compactMap { group in
            guard let first = group.first, let end = group.map(\.end).max() else { return nil }
            var labelTotals: [String: (TimeInterval, String)] = [:]
            var appTotals: [String: TimeInterval] = [:]
            for a in group {
                let label = labels.topic(a)
                let existing = labelTotals[label]?.0 ?? 0
                labelTotals[label] = (existing + a.duration, a.bundleID)
                appTotals[a.appName, default: 0] += a.duration
            }
            let top = labelTotals.max { $0.value.0 < $1.value.0 }
            let breakdown = appTotals.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
            return TimelineBlock(id: "\(first.id)", start: first.start, end: end, label: top?.key ?? first.appName, bundleID: top?.value.1 ?? first.bundleID, breakdown: breakdown)
        }
    }

    static func topicLabel(_ a: Activity) -> String {
        // Web pages are labelled by their site, so skip the page-title cleanup `parts` would do.
        if let url = URL(string: a.path), let scheme = url.scheme, scheme == "http" || scheme == "https", let host = url.host { return host }
        let parts = ActivityPath.parts(path: a.path, title: a.title)
        guard let first = parts.first else { return a.appName }
        switch first.kind {
        case .domain: return first.label
        case .none: return a.appName
        case .segment: return parts.count > 1 && !(parts[1].kind == .title) ? parts[1].label : first.label
        default: return first.label
        }
    }
}

enum Format {
    static func duration(_ t: TimeInterval, seconds: Bool = false) -> String {
        let total = Int(t.rounded())
        var h = total / 3600
        var m = (total % 3600) / 60
        let s = total % 60
        if !seconds, s >= 30 {
            // Round to the nearest minute rather than down, so rows sum close to their parent's total.
            m += 1
            if m == 60 { h += 1; m = 0 }
        }
        if seconds {
            if h > 0 { return "\(h)h \(m)m \(s)s" }
            if m > 0 { return "\(m)m \(s)s" }
            return "\(s)s"
        }
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        if m > 0 { return "\(m)m" }
        return "<1m"
    }

    static func percent(_ part: TimeInterval, of total: TimeInterval) -> String {
        guard total > 0 else { return "" }
        let p = part / total * 100
        return p < 1 ? "<1%" : "\(Int(p.rounded()))%"
    }

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE, dd MMM yyyy")
        return f
    }()

    static func dayTitle(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return day.string(from: date)
    }
}
