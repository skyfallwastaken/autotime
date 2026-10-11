import SwiftUI
import Combine

enum SidebarItem: Hashable {
    case activities
    case stats
    case app(String)
}

@MainActor
final class DayModel: ObservableObject {
    @Published var date = Calendar.current.startOfDay(for: Date()) { didSet { selection = nil; reload() } }
    @Published private(set) var activities: [Activity] = []
    @Published var search = ""
    @Published var selection: ClosedRange<Date>?
    @Published var mode: ViewMode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "viewMode") ?? "") ?? .unified {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "viewMode") }
    }
    @Published var sidebar: SidebarItem? = .activities
    @Published var expanded: Set<String> = []
    @Published var hourHeight: CGFloat = CGFloat(UserDefaults.standard.double(forKey: "hourHeight")).clamped(60, 600, default: 120) {
        didSet { UserDefaults.standard.set(Double(hourHeight), forKey: "hourHeight") }
    }

    private var observer: Any?

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
        activities = Store.shared.activities(in: dayRange)
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

    var searched: [Activity] {
        var list = activities
        if let app = appFilter { list = list.filter { $0.bundleID == app } }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter {
                $0.appName.localizedCaseInsensitiveContains(q) || $0.title.localizedCaseInsensitiveContains(q) || $0.path.localizedCaseInsensitiveContains(q)
            }
        }
        return list
    }

    var visible: [Activity] {
        guard let selection else { return searched }
        return searched.compactMap { $0.clipped(to: selection) }
    }

    var appTotals: [(bundleID: String, name: String, duration: TimeInterval)] {
        var totals: [String: (String, TimeInterval)] = [:]
        for a in activities {
            let e = totals[a.bundleID] ?? (a.appName, 0)
            totals[a.bundleID] = (e.0, e.1 + a.duration)
        }
        return totals.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.2 > $1.2 }
    }

    func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    func setExpanded(_ node: TreeNode, _ value: Bool, recursive: Bool) {
        if value { expanded.insert(node.id) } else { expanded.remove(node.id) }
        if recursive { node.children.forEach { setExpanded($0, value, recursive: true) } }
    }
}

extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat, default d: CGFloat) -> CGFloat {
        self == 0 ? d : Swift.min(hi, Swift.max(lo, self))
    }
}
