import SwiftUI

/// Apps and websites never to record. Read by the tracker on its own queue, edited from Settings and the activity list.
final class Exclusions: @unchecked Sendable {
    static let shared = Exclusions()

    private let lock = NSLock()
    private var apps: [String]
    private var sites: [String]

    private init() {
        apps = UserDefaults.standard.stringArray(forKey: "excludedApps") ?? []
        sites = UserDefaults.standard.stringArray(forKey: "excludedSites") ?? []
    }

    var appList: [String] { lock.withLock { apps } }
    var siteList: [String] { lock.withLock { sites } }

    func excludes(app bundleID: String) -> Bool {
        lock.withLock { apps.contains(bundleID) }
    }

    func excludes(path: String) -> Bool {
        guard let host = Hosts.webHost(path) else { return false }
        return lock.withLock { sites.contains { Hosts.matches(host, $0) } }
    }

    func add(app bundleID: String) { update { if !$0.apps.contains(bundleID) { $0.apps.append(bundleID) } } }
    func remove(app bundleID: String) { update { $0.apps.removeAll { $0 == bundleID } } }

    func add(site: String) {
        var host = site.trimmingCharacters(in: .whitespaces).lowercased()
        if let h = Hosts.webHost(host.contains("://") ? host : "https://" + host) { host = h }
        guard !host.isEmpty else { return }
        update { if !$0.sites.contains(host) { $0.sites.append(host) } }
    }

    func remove(site: String) { update { $0.sites.removeAll { $0 == site } } }

    private func update(_ change: (Exclusions) -> Void) {
        lock.lock()
        change(self)
        let (a, s) = (apps, sites)
        lock.unlock()
        UserDefaults.standard.set(a, forKey: "excludedApps")
        UserDefaults.standard.set(s, forKey: "excludedSites")
    }
}

/// Which history a deletion covers.
enum DeletionFilter: Identifiable, Hashable {
    case search(String)
    case website(String)
    case app(String)

    var id: Self { self }

    var title: String {
        switch self {
        case .search(let q): "activities matching “\(q)”"
        case .website(let host): "history for \(host)"
        case .app(let id): "history for \(AppCatalog.shared.name(for: id))"
        }
    }

    func matches(_ a: Activity) -> Bool {
        switch self {
        case .search(let q):
            a.appName.localizedCaseInsensitiveContains(q) || a.title.localizedCaseInsensitiveContains(q) || a.path.localizedCaseInsensitiveContains(q)
        case .website(let host): Rule.website(host).matches(a)
        case .app(let id): a.bundleID == id
        }
    }
}

struct DeleteHistorySheet: View {
    enum Scope: String, CaseIterable, Identifiable {
        case day = "This Day"
        case all = "All Time"
        case range = "Date Range"
        var id: String { rawValue }
    }

    var filter: DeletionFilter
    var day: Date
    @Environment(\.dismiss) private var dismiss
    @State private var scope: Scope = .day
    @State private var from = Date()
    @State private var to = Date()
    @State private var matches: [Activity]?
    @State private var alsoExclude = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete \(filter.title)").font(.headline)
            Picker("", selection: $scope) {
                ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if scope == .range {
                HStack {
                    DatePicker("From", selection: $from, displayedComponents: .date)
                    DatePicker("To", selection: $to, in: from..., displayedComponents: .date)
                }
            }
            Group {
                if let matches {
                    if matches.isEmpty {
                        Text("Nothing matches.")
                    } else {
                        Text("\(matches.count.formatted()) \(matches.count == 1 ? "activity" : "activities") totalling \(Format.duration(matches.reduce(0) { $0 + $1.duration })) will be deleted. This can't be undone.")
                    }
                } else {
                    HStack { ProgressView().controlSize(.small); Text("Counting…") }
                }
            }
            .foregroundStyle(.secondary)
            switch filter {
            case .website(let host): Toggle("Also stop recording \(host)", isOn: $alsoExclude)
            case .app(let id): Toggle("Also stop recording \(AppCatalog.shared.name(for: id))", isOn: $alsoExclude)
            case .search: EmptyView()
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    Store.shared.delete(ids: matches?.map(\.id) ?? [])
                    if alsoExclude {
                        switch filter {
                        case .website(let host): Exclusions.shared.add(site: host)
                        case .app(let id): Exclusions.shared.add(app: id)
                        case .search: break
                        }
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(matches?.isEmpty ?? true)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { from = day; to = day }
        .task(id: [scope.rawValue, "\(from)", "\(to)"]) { await count() }
    }

    private var range: ClosedRange<Date> {
        let cal = Calendar.current
        switch scope {
        case .day: return day...cal.date(byAdding: .day, value: 1, to: day)!
        case .all: return Date.distantPast...Date.distantFuture
        case .range: return cal.startOfDay(for: from)...cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: max(from, to)))!
        }
    }

    private func count() async {
        matches = nil
        let (range, filter) = (range, filter)
        matches = await Task.detached(priority: .userInitiated) {
            Store.shared.activities(in: range).filter { filter.matches($0) }
        }.value
    }
}

struct ExclusionsSettings: View {
    @State private var apps = Exclusions.shared.appList
    @State private var sites = Exclusions.shared.siteList
    @State private var recent: [(bundleID: String, name: String)] = []
    @State private var newSite = ""

    var body: some View {
        Form {
            Section {
                ForEach(sites, id: \.self) { site in
                    HStack {
                        FaviconView(host: site, fallback: "globe")
                        Text(site)
                        Spacer()
                        removeButton { Exclusions.shared.remove(site: site) }
                    }
                }
                HStack {
                    TextField("", text: $newSite, prompt: Text("example.com"))
                        .onSubmit(addSite)
                    Button("Add", action: addSite).disabled(newSite.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Websites")
            } footer: {
                Text("Time on these sites, and their subdomains, still counts towards the browser but is recorded without a title or address.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(apps, id: \.self) { id in
                    HStack {
                        Image(nsImage: AppCatalog.shared.icon(for: id)).resizable().frame(width: 16, height: 16)
                        Text(AppCatalog.shared.name(for: id))
                        Spacer()
                        removeButton { Exclusions.shared.remove(app: id) }
                    }
                }
                Menu("Add App") {
                    ForEach(recent.filter { !apps.contains($0.bundleID) }, id: \.bundleID) { app in
                        Button(app.name) { Exclusions.shared.add(app: app.bundleID); reload() }
                    }
                }
                .fixedSize()
            } header: {
                Text("Apps")
            } footer: {
                Text("Time in these apps isn't recorded at all. Existing history stays until you delete it: search for it in the activity list, or right-click a row, and choose Delete.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { recent = await Store.shared.recentApps() }
    }

    private func addSite() {
        Exclusions.shared.add(site: newSite)
        newSite = ""
        reload()
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button { action(); reload() } label: { Image(systemName: "minus.circle.fill") }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
    }

    private func reload() {
        apps = Exclusions.shared.appList
        sites = Exclusions.shared.siteList
    }
}
