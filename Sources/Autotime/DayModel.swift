import SwiftUI
import Observation

enum SidebarItem: Hashable {
    case activities
    case stats
    case app(String)
}

/// Observed per property, so a view re-renders only when something it read changes:
/// zooming the timeline or toggling a row leaves the other views alone.
@MainActor
@Observable
final class DayModel {
    var date = Calendar.current.startOfDay(for: Date()) { didSet { selection = nil; reload() } }
    private(set) var activities: [Activity] = []
    var search = ""
    var selection: ClosedRange<Date>?
    var mode: ViewMode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "viewMode") ?? "") ?? .unified {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "viewMode") }
    }
    var sidebar: SidebarItem? = .activities
    var expanded: Set<String> = []
    var hourHeight: CGFloat = CGFloat(UserDefaults.standard.double(forKey: "hourHeight")).clamped(60, 600, default: 120) {
        didSet { UserDefaults.standard.set(Double(hourHeight), forKey: "hourHeight") }
    }

    @ObservationIgnored private var observer: Any?
    /// Bumped whenever `activities` is replaced, so the lists derived from it know to rebuild.
    private var generation = 0
    @ObservationIgnored private var labels = LabelCache()
    @ObservationIgnored private var searchedMemo = Memo<FilterKey, [Activity]>()
    @ObservationIgnored private var visibleMemo = Memo<VisibleKey, [Activity]>()
    @ObservationIgnored private var appTotalsMemo = Memo<Int, [(bundleID: String, name: String, duration: TimeInterval)]>()
    @ObservationIgnored private var treeMemo = Memo<TreeKey, [TreeNode]>()
    @ObservationIgnored private var sessionsMemo = Memo<VisibleKey, [Session]>()
    @ObservationIgnored private var timelineMemo = Memo<FilterKey, (apps: [Session], blocks: [TimelineBlock])>()

    init() {
        observer = NotificationCenter.default.addObserver(forName: .storeDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isToday || self.activities.isEmpty { self.reload() }
            }
        }
        reload()
    }

    var dayRange: ClosedRange<Date> {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: date)!
        return date...end
    }

    var isToday: Bool { Calendar.current.isDateInToday(date) }

    func reload() {
        if labels.count > 100_000 { labels = LabelCache() }
        activities = Store.shared.activities(in: dayRange)
        generation += 1
    }

    func shift(_ days: Int) {
        date = Calendar.current.date(byAdding: .day, value: days, to: date)!
    }

    func goToToday() {
        date = Calendar.current.startOfDay(for: Date())
    }

    var appFilter: String? {
        if case .app(let id) = sidebar { return id }
        return nil
    }

    // Views re-render on every keystroke and drag step, so everything derived from the day's activities is
    // remembered against the inputs it depends on rather than rebuilt on each render.

    private var filterKey: FilterKey {
        FilterKey(generation: generation, app: appFilter, search: search.trimmingCharacters(in: .whitespaces))
    }

    private var visibleKey: VisibleKey { VisibleKey(filter: filterKey, selection: selection) }

    var searched: [Activity] {
        let key = filterKey
        return searchedMemo.get(key) {
            var list = activities
            if let app = key.app { list = list.filter { $0.bundleID == app } }
            let q = key.search
            if !q.isEmpty {
                list = list.filter {
                    $0.appName.localizedCaseInsensitiveContains(q) || $0.title.localizedCaseInsensitiveContains(q) || $0.path.localizedCaseInsensitiveContains(q)
                }
            }
            return list
        }
    }

    var visible: [Activity] {
        visibleMemo.get(visibleKey) {
            guard let selection else { return searched }
            return searched.compactMap { $0.clipped(to: selection) }
        }
    }

    /// The outline for the current view mode (not used in chronological mode).
    var tree: [TreeNode] {
        treeMemo.get(TreeKey(visible: visibleKey, mode: mode)) { TreeBuilder.build(visible, mode: mode, labels: labels) }
    }

    /// Chronological mode's rows, newest first.
    var sessions: [Session] {
        sessionsMemo.get(visibleKey) { Sessions.merge(visible, labels: labels).reversed() }
    }

    /// The timeline's per-app strip and its blocks, which ignore the selection.
    var timeline: (apps: [Session], blocks: [TimelineBlock]) {
        timelineMemo.get(filterKey) { (Sessions.byApp(searched), Blocks.build(searched, labels: labels)) }
    }

    var appTotals: [(bundleID: String, name: String, duration: TimeInterval)] {
        appTotalsMemo.get(generation) {
            var totals: [String: (String, TimeInterval)] = [:]
            for a in activities {
                let e = totals[a.bundleID] ?? (a.appName, 0)
                totals[a.bundleID] = (e.0, e.1 + a.duration)
            }
            return totals.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.2 > $1.2 }
        }
    }

    func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    func setExpanded(_ node: TreeNode, _ value: Bool, recursive: Bool) {
        if value { expanded.insert(node.id) } else { expanded.remove(node.id) }
        if recursive { node.children.forEach { setExpanded($0, value, recursive: true) } }
    }
}

private struct FilterKey: Equatable {
    var generation: Int
    var app: String?
    var search: String
}

private struct VisibleKey: Equatable {
    var filter: FilterKey
    var selection: ClosedRange<Date>?
}

private struct TreeKey: Equatable {
    var visible: VisibleKey
    var mode: ViewMode
}

/// The last value computed and the key it was computed for.
private struct Memo<Key: Equatable, Value> {
    private var last: (key: Key, value: Value)?

    mutating func get(_ key: Key, _ make: () -> Value) -> Value {
        if let last, last.key == key { return last.value }
        let value = make()
        last = (key, value)
        return value
    }
}

extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat, default d: CGFloat) -> CGFloat {
        self == 0 ? d : Swift.min(hi, Swift.max(lo, self))
    }
}
