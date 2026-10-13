import SwiftUI
import Observation
import EventKit

struct CalendarEvent: Identifiable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var calendar: String
    var color: Color
}

struct Commit: Identifiable {
    var id: String { repo + hash }
    var hash: String
    var date: Date
    var repo: String
    var message: String
}

extension Notification.Name {
    static let annotationSettingsDidChange = Notification.Name("AutotimeAnnotationSettingsDidChange")
}

/// Calendar events and git commits drawn beside the timeline. Both are off until turned on in Settings.
@MainActor
@Observable
final class Annotations {
    private(set) var events: [CalendarEvent] = []
    private(set) var commits: [Commit] = []
    @ObservationIgnored private var loaded: (day: Date, at: Date)?
    @ObservationIgnored private var task: Task<Void, Never>?

    static var showCalendar: Bool { UserDefaults.standard.bool(forKey: "showCalendar") }
    static var showCommits: Bool { UserDefaults.standard.bool(forKey: "showCommits") }
    static var commitFolders: [String] { UserDefaults.standard.stringArray(forKey: "commitFolders") ?? [] }
    static var onlyMyCommits: Bool { UserDefaults.standard.object(forKey: "onlyMyCommits") as? Bool ?? true }

    /// Loads the day's annotations; today's are refreshed at most every two minutes unless `force`.
    func load(_ day: Date, force: Bool = false) {
        if !force, let loaded, loaded.day == day, !Calendar.current.isDateInToday(day) || Date().timeIntervalSince(loaded.at) < 120 { return }
        if loaded?.day != day { events = []; commits = [] }
        loaded = (day, Date())
        task?.cancel()
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        let (calendar, git, folders, mine) = (Self.showCalendar, Self.showCommits, Self.commitFolders, Self.onlyMyCommits)
        task = Task {
            async let e = calendar ? CalendarSource.events(from: day, to: end) : []
            async let c = git ? GitSource.commits(in: folders, from: day, to: end, onlyMine: mine) : []
            let (ev, co) = await (e, c)
            guard !Task.isCancelled else { return }
            events = ev
            commits = co
        }
    }
}

enum CalendarSource {
    static let store = EKEventStore()

    static var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    static func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    static func events(from start: Date, to end: Date) async -> [CalendarEvent] {
        guard authorized else { return [] }
        return await Task.detached(priority: .utility) {
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            return store.events(matching: predicate).filter { !$0.isAllDay }.map {
                CalendarEvent(id: ($0.eventIdentifier ?? UUID().uuidString) + "\($0.startDate.timeIntervalSince1970)", title: $0.title ?? "",
                              start: $0.startDate, end: $0.endDate, calendar: $0.calendar.title, color: Color(cgColor: $0.calendar.cgColor))
            }
        }.value
    }
}

enum GitSource {
    /// A git that won't trigger macOS's "install the command line developer tools" prompt when it isn't really installed.
    static let executable: String? = {
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where FileManager.default.isExecutableFile(atPath: path) { return path }
        guard run("/usr/bin/xcode-select", ["-p"]) != nil else { return nil }
        return "/usr/bin/git"
    }()

    static var available: Bool { executable != nil }

    /// Repositories in each folder: the folder itself, or ones up to two levels inside it.
    static func repositories(in folders: [String]) -> [URL] {
        var repos: [URL] = []
        func scan(_ url: URL, depth: Int) {
            guard repos.count < 300 else { return }
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { repos.append(url); return }
            guard depth > 0, let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { scan(child, depth: depth - 1) }
        }
        for folder in folders { scan(URL(fileURLWithPath: (folder as NSString).expandingTildeInPath), depth: 2) }
        return repos
    }

    static func commits(in folders: [String], from start: Date, to end: Date, onlyMine: Bool) async -> [Commit] {
        guard let git = executable, !folders.isEmpty else { return [] }
        return await Task.detached(priority: .utility) {
            var all: [String: Commit] = [:]
            await withTaskGroup(of: [Commit].self) { group in
                for repo in repositories(in: folders) {
                    group.addTask {
                        var args = ["-C", repo.path, "log", "--all", "--no-merges", "--since=@\(Int(start.timeIntervalSince1970))",
                                    "--until=@\(Int(end.timeIntervalSince1970))", "--format=%H%x1f%ct%x1f%s"]
                        if onlyMine {
                            guard let email = run(git, ["-C", repo.path, "config", "user.email"])?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else { return [] }
                            args += ["--fixed-strings", "--author=<\(email)>"]
                        }
                        return (run(git, args) ?? "").split(separator: "\n").compactMap { line in
                            let f = line.split(separator: "\u{1F}", maxSplits: 2, omittingEmptySubsequences: false)
                            guard f.count == 3, let t = Double(f[1]) else { return nil }
                            return Commit(hash: String(f[0]), date: Date(timeIntervalSince1970: t), repo: repo.lastPathComponent, message: String(f[2]))
                        }
                    }
                }
                for await list in group { for c in list { all[c.hash] = c } }
            }
            return all.values.sorted { $0.date < $1.date }
        }.value
    }

    /// Output of a command, or nil if it failed or took longer than five seconds.
    static func run(_ executable: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let timeout = DispatchWorkItem { p.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timeout.cancel()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

struct TimelineSettings: View {
    @AppStorage("showCalendar") private var showCalendar = false
    @AppStorage("showCommits") private var showCommits = false
    @AppStorage("onlyMyCommits") private var onlyMyCommits = true
    @State private var folders = Annotations.commitFolders
    @State private var calendarDenied = false

    var body: some View {
        Form {
            Section {
                Toggle("Show calendar events", isOn: $showCalendar)
                    .onChange(of: showCalendar) {
                        guard showCalendar else { changed(); return }
                        Task {
                            let granted = CalendarSource.authorized ? true : await CalendarSource.requestAccess()
                            calendarDenied = !granted
                            if !granted { showCalendar = false }
                            changed()
                        }
                    }
                if calendarDenied {
                    HStack {
                        Text("Autotime doesn't have access to your calendars.").foregroundStyle(.orange)
                        Spacer()
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                        }
                    }
                }
            } footer: {
                Text("Timed events from every calendar on this Mac, beside the timeline.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show git commits", isOn: $showCommits)
                    .disabled(!GitSource.available)
                    .onChange(of: showCommits) { changed() }
                if showCommits {
                    Toggle("Only my commits", isOn: $onlyMyCommits).onChange(of: onlyMyCommits) { changed() }
                    ForEach(folders, id: \.self) { folder in
                        HStack {
                            Image(systemName: "folder")
                            Text(ActivityPath.abbreviate((folder as NSString).expandingTildeInPath, directory: false))
                            Spacer()
                            Button { setFolders(folders.filter { $0 != folder }) } label: { Image(systemName: "minus.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                    }
                    Button("Add Folder…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = true
                        if panel.runModal() == .OK {
                            setFolders(folders + panel.urls.map { ActivityPath.abbreviate($0.path, directory: false) }.filter { !folders.contains($0) })
                        }
                    }
                }
            } footer: {
                Text(GitSource.available
                     ? "Commits from repositories in these folders (up to two levels deep), marked on the timeline. Only my commits uses each repository's user.email."
                     : "Needs git. Install Xcode's command line tools to use this.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func setFolders(_ list: [String]) {
        folders = list
        UserDefaults.standard.set(list, forKey: "commitFolders")
        changed()
    }

    private func changed() {
        NotificationCenter.default.post(name: .annotationSettingsDidChange, object: nil)
    }
}
