import AppKit
import SwiftUI

enum NodeKind: Hashable {
    case category(String)
    case app(String)
    case domain(String)
    case url(String)
    case file(String)
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

    static func parts(path: String, title: String) -> [PathComponent] {
        var result: [PathComponent] = []
        if !path.isEmpty {
            if let url = URL(string: path), let scheme = url.scheme, scheme == "http" || scheme == "https", let host = url.host {
                result.append(PathComponent(label: host, kind: .domain(host)))
                result.append(PathComponent(label: displayURL(url), kind: .url(path)))
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
            return a.title.isEmpty ? first.label : "\(a.title) — \(first.label)"
        }
        if p.first?.kind == NodeKind.none { return a.appName }
        return p.map(\.label).joined(separator: " › ")
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
            let kids = order.map { key in children[key]!.build(id: id + "/" + key) }
                .sorted { $0.duration > $1.duration }
            return TreeNode(id: id, label: label, kind: kind, bundleID: bundleID, duration: duration, children: kids)
        }
    }

    static func build(_ activities: [Activity], mode: ViewMode) -> [TreeNode] {
        let root = Builder(label: "", kind: .none, bundleID: "")
        for a in activities {
            var node = root
            node.duration += a.duration
            if mode == .category {
                let cat = AppCatalog.shared.category(for: a.bundleID)
                node = node.child("c:" + cat, label: cat, kind: .category(cat), bundleID: "")
                node.duration += a.duration
            }
            node = node.child("a:" + a.bundleID, label: a.appName, kind: .app(a.bundleID), bundleID: a.bundleID)
            node.duration += a.duration
            for (i, part) in ActivityPath.parts(path: a.path, title: a.title).enumerated() {
                node = node.child("\(i):" + part.label, label: part.label, kind: part.kind, bundleID: a.bundleID)
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
    static func merge(_ activities: [Activity], gap: TimeInterval = 5) -> [Session] {
        var result: [Session] = []
        for a in activities.sorted(by: { $0.start < $1.start }) {
            let label = ActivityPath.primaryLabel(a)
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
    static func build(_ activities: [Activity], gap: TimeInterval = 180, maxLength: TimeInterval = 3600) -> [TimelineBlock] {
        let sorted = activities.sorted { $0.start < $1.start }
        var groups: [[Activity]] = []
        for a in sorted {
            if let last = groups.last, let lastEnd = last.map(\.end).max(), let first = last.first,
               a.start.timeIntervalSince(lastEnd) <= gap, a.end.timeIntervalSince(first.start) <= maxLength {
                groups[groups.count - 1].append(a)
            } else {
                groups.append([a])
            }
        }
        return groups.compactMap { group in
            guard let first = group.first, let end = group.map(\.end).max() else { return nil }
            var labelTotals: [String: (TimeInterval, String)] = [:]
            var appTotals: [String: TimeInterval] = [:]
            for a in group {
                let label = topicLabel(a)
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
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
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
