import SwiftUI
import Observation
import UserNotifications

enum LimitTarget: Codable, Hashable {
    case app(String)
    case website(String)
    case project(UUID)

    @MainActor var name: String {
        switch self {
        case .app(let id): AppCatalog.shared.name(for: id)
        case .website(let host): host
        case .project(let id): Projects.shared.project(id: id)?.name ?? "Deleted project"
        }
    }

    @MainActor func matches(_ a: Activity) -> Bool {
        switch self {
        case .app(let id): a.bundleID == id
        case .website(let host): Rule.website(host).matches(a)
        case .project(let id): Projects.shared.project(for: a)?.id == id
        }
    }

    var icon: NodeKind {
        switch self {
        case .app(let id): .app(id)
        case .website(let host): .domain(host)
        case .project(let id): .project(id)
        }
    }
}

struct Limit: Codable, Identifiable, Hashable {
    var id = UUID()
    var target: LimitTarget
    var minutes: Int
}

/// Daily time limits. Today's usage is recomputed every minute; going over a limit sends a notification,
/// and another for every further 15 minutes spent over it.
@MainActor
@Observable
final class Limits {
    static let shared = Limits()
    private static let reminderEvery: TimeInterval = 15 * 60

    private(set) var list: [Limit] = []
    /// Seconds used today per limit.
    private(set) var usage: [UUID: TimeInterval] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observer: Any?

    private init() {
        list = UserDefaults.standard.data(forKey: "limits").flatMap { try? JSONDecoder().decode([Limit].self, from: $0) } ?? []
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { Limits.shared.refresh() } }
        refresh()
    }

    func save(_ limit: Limit) {
        if let i = list.firstIndex(where: { $0.id == limit.id }) { list[i] = limit } else { list.append(limit) }
        persist()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        refresh()
    }

    func remove(_ id: UUID) {
        list.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: "limits") }
    }

    func refresh() {
        guard !list.isEmpty else { usage = [:]; return }
        let start = Calendar.current.startOfDay(for: Date())
        let today = Store.shared.activities(in: start...start.addingTimeInterval(86400))
        var used: [UUID: TimeInterval] = [:]
        for limit in list { used[limit.id] = today.lazy.filter { limit.target.matches($0) }.reduce(0) { $0 + $1.duration } }
        usage = used
        notify(day: start)
    }

    private func notify(day: Date) {
        let key = "limitReminders-\(Int(day.timeIntervalSince1970))"
        var sent = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        for limit in list {
            let over = (usage[limit.id] ?? 0) - Double(limit.minutes * 60)
            guard over >= 0 else { continue }
            let step = Int(over / Self.reminderEvery) + 1
            guard step > sent[limit.id.uuidString] ?? 0 else { continue }
            sent[limit.id.uuidString] = step
            let content = UNMutableNotificationContent()
            content.title = step == 1 ? "Daily limit reached" : "Still over your daily limit"
            content.body = "\(limit.target.name): \(Format.duration(usage[limit.id] ?? 0)) today, limit \(Format.duration(Double(limit.minutes * 60)))."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(limit.id)-\(step)", content: content, trigger: nil))
        }
        UserDefaults.standard.set(sent, forKey: key)
        // Forget earlier days' reminders.
        for k in UserDefaults.standard.dictionaryRepresentation().keys where k.hasPrefix("limitReminders-") && k != key {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }
}

struct LimitProgress: View {
    var limit: Limit
    var used: TimeInterval

    var body: some View {
        let fraction = used / Double(max(1, limit.minutes * 60))
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                NodeIcon(kind: limit.target.icon)
                Text(limit.target.name).lineLimit(1)
                Spacer()
                Text("\(Format.duration(used)) / \(Format.duration(Double(limit.minutes * 60)))")
                    .monospacedDigit()
                    .foregroundStyle(fraction >= 1 ? .red : .secondary)
            }
            ProgressView(value: min(1, fraction))
                .tint(fraction >= 1 ? .red : fraction >= 0.8 ? .orange : .accentColor)
        }
    }
}

struct LimitsSettings: View {
    @State private var editing: Limit?

    var body: some View {
        let limits = Limits.shared
        Form {
            Section {
                if limits.list.isEmpty {
                    Text("No limits yet.").foregroundStyle(.secondary)
                }
                ForEach(limits.list) { limit in
                    HStack {
                        LimitProgress(limit: limit, used: limits.usage[limit.id] ?? 0)
                        Button("Edit") { editing = limit }.buttonStyle(.borderless)
                    }
                }
                Button("Add Limit…") { editing = Limit(target: .website(""), minutes: 60) }
            } footer: {
                Text("You'll get a notification when you reach a limit, then every 15 minutes you stay over it. Right-click an app or website in the activity list to set a limit for it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { LimitEditor(limit: $0) }
        .onAppear { limits.refresh() }
    }
}

struct LimitEditor: View {
    enum Kind: String, CaseIterable, Identifiable {
        case app = "App", website = "Website", project = "Project"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @State var limit: Limit
    @State private var apps: [(bundleID: String, name: String)] = []

    var body: some View {
        let isNew = !Limits.shared.list.contains { $0.id == limit.id }
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Daily Limit" : "Edit Daily Limit").font(.headline)
            Form {
                Picker("Limit", selection: kindBinding) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                switch limit.target {
                case .app(let id):
                    Picker("App", selection: Binding(get: { id }, set: { limit.target = .app($0) })) {
                        if !apps.contains(where: { $0.bundleID == id }) { Text(id.isEmpty ? "Choose…" : AppCatalog.shared.name(for: id)).tag(id) }
                        ForEach(apps, id: \.bundleID) { Text($0.name).tag($0.bundleID) }
                    }
                case .website(let host):
                    TextField("Website", text: Binding(get: { host }, set: { limit.target = .website($0.trimmingCharacters(in: .whitespaces).lowercased()) }), prompt: Text("example.com"))
                case .project(let id):
                    Picker("Project", selection: Binding(get: { id }, set: { limit.target = .project($0) })) {
                        if Projects.shared.project(id: id) == nil { Text("Choose…").tag(id) }
                        ForEach(Projects.shared.list) { Text($0.name).tag($0.id) }
                    }
                }
                Stepper(value: $limit.minutes, in: 5...(24 * 60), step: limit.minutes < 60 ? 5 : 15) {
                    Text("\(Format.duration(Double(limit.minutes * 60))) a day")
                }
            }
            .formStyle(.grouped)
            HStack {
                if !isNew { Button("Delete Limit", role: .destructive) { Limits.shared.remove(limit.id); dismiss() } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { Limits.shared.save(limit); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task { apps = await Store.shared.recentApps() }
    }

    private var valid: Bool {
        switch limit.target {
        case .app(let id): !id.isEmpty
        case .website(let host): !host.isEmpty
        case .project(let id): Projects.shared.project(id: id) != nil
        }
    }

    private var kindBinding: Binding<Kind> {
        Binding {
            switch limit.target {
            case .app: .app
            case .website: .website
            case .project: .project
            }
        } set: { kind in
            switch kind {
            case .app: limit.target = .app(apps.first?.bundleID ?? "")
            case .website: limit.target = .website("")
            case .project: limit.target = .project(Projects.shared.list.first?.id ?? UUID())
            }
        }
    }
}
