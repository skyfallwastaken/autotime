import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var tracker: Tracker
    @ObservedObject private var updater = Updater.shared
    @AppStorage("idleMinutes") private var idleMinutes = 3.0
    @AppStorage("countVideo") private var countVideo = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var trusted = AccessibilityPermission.isTrusted
    @State private var confirmDelete = false
    @State private var importStatus: String?
    @State private var importing = false
    @State private var screenTimeStatus: String?
    @State private var screenTimeImporting = false
    @State private var screenTimeNeedsAccess = false

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            ExclusionsSettings().tabItem { Label("Privacy", systemImage: "hand.raised") }
            LimitsSettings().tabItem { Label("Limits", systemImage: "hourglass") }
            TimelineSettings().tabItem { Label("Timeline", systemImage: "calendar") }
            data.tabItem { Label("Data", systemImage: "externaldrive") }
        }
        .frame(width: 520, height: 500)
        .onAppear { trusted = AccessibilityPermission.isTrusted }
        .confirmationDialog("Delete all recorded activity?", isPresented: $confirmDelete) {
            Button("Delete Everything", role: .destructive) { Store.shared.deleteAll() }
        } message: {
            Text("This cannot be undone.")
        }
    }

    private var general: some View {
        Form {
            Section("Tracking") {
                Toggle("Pause tracking", isOn: $tracker.isPaused)
                Stepper(value: $idleMinutes, in: 1...30, step: 1) {
                    Text("Stop recording after \(Int(idleMinutes)) min of inactivity")
                }
                Toggle(isOn: $countVideo) {
                    Text("Count watching video as active")
                    Text("Time isn't treated as idle while the app in front is playing video. Background music doesn't count.")
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) {
                        do {
                            if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section("Permissions") {
                HStack {
                    Label(trusted ? "Accessibility access granted" : "Accessibility access not granted",
                          systemImage: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(trusted ? .green : .orange)
                    Spacer()
                    Button("Open Settings") { AccessibilityPermission.openSettings() }
                }
                Text("Accessibility lets Autotime read window titles, browser URLs, document paths and Slack or Discord channels. Everything stays on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
                LabeledContent("Version \(Updater.version)") {
                    CheckForUpdatesButton()
                }
            }
        }
        .formStyle(.grouped)
    }

    private var data: some View {
        Form {
            Section {
                LabeledContent("Export") {
                    Text("File ▸ Export… (⌘E)").foregroundStyle(.secondary)
                }
            }
            Section("History") {
                LabeledContent("Database") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Store.directory]) }
                }
                if FileManager.default.fileExists(atPath: Store.timingDatabase.path) {
                    LabeledContent("Timing history") {
                        HStack {
                            if let importStatus { Text(importStatus).foregroundStyle(.secondary) }
                            if importing { ProgressView().controlSize(.small) }
                            Button("Import from Timing") {
                                importing = true
                                DispatchQueue.global(qos: .userInitiated).async {
                                    let n = Store.shared.importFromTiming()
                                    DispatchQueue.main.async {
                                        importing = false
                                        importStatus = "Imported \(n.formatted()) activities"
                                    }
                                }
                            }
                            .disabled(importing)
                        }
                    }
                }
                LabeledContent {
                    HStack {
                        if let screenTimeStatus { Text(screenTimeStatus).foregroundStyle(.secondary) }
                        if screenTimeImporting { ProgressView().controlSize(.small) }
                        Button("Import from Screen Time", action: importScreenTime)
                            .disabled(screenTimeImporting)
                    }
                } label: {
                    Text("Screen Time history")
                    Text("App usage only, for the last few weeks. Time Autotime already has is skipped.")
                }
                if screenTimeNeedsAccess {
                    HStack {
                        Text("Screen Time data needs Full Disk Access for Autotime.")
                            .font(.callout)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Settings") { ScreenTimeImporter.openFullDiskAccessSettings() }
                    }
                }
                Button("Delete All Recorded Data…", role: .destructive) { confirmDelete = true }
            }
        }
        .formStyle(.grouped)
    }

    private func importScreenTime() {
        screenTimeImporting = true
        screenTimeNeedsAccess = false
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ScreenTimeImporter.load()
            var status: String
            var needsAccess = false
            switch result {
            case .success(let intervals):
                let r = Store.shared.importIntervals(intervals, name: ScreenTimeImporter.appName)
                status = r.count == 0 ? "Nothing new to import" : "Imported \(Format.duration(r.duration)) of app usage"
            case .failure(.noAccess):
                status = "No access"
                needsAccess = true
            case .failure(.noData):
                status = "No Screen Time data found"
            }
            DispatchQueue.main.async {
                screenTimeImporting = false
                screenTimeStatus = status
                screenTimeNeedsAccess = needsAccess
            }
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var tracker: Tracker
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var total: TimeInterval = 0
    @State private var top: [(String, String, TimeInterval)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Today")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(Format.duration(total))
                        .font(.title.weight(.semibold))
                }
                Spacer()
                Toggle("", isOn: Binding(get: { !tracker.isPaused }, set: { tracker.isPaused = !$0 }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(tracker.isPaused ? "Resume Tracking" : "Pause Tracking")
            }

            Group {
                if tracker.isPaused {
                    Label("Tracking paused", systemImage: "pause.circle")
                } else if tracker.isIdle {
                    Label("Idle", systemImage: "moon.zzz")
                } else if !tracker.currentApp.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tracker.currentApp).fontWeight(.medium)
                        if !tracker.currentLabel.isEmpty {
                            Text(tracker.currentLabel).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            }
            .font(.callout)

            if !Limits.shared.list.isEmpty {
                Divider()
                ForEach(Limits.shared.list) { limit in
                    LimitProgress(limit: limit, used: Limits.shared.usage[limit.id] ?? 0)
                        .font(.callout)
                }
            }

            if !top.isEmpty {
                Divider()
                ForEach(top, id: \.0) { item in
                    HStack(spacing: 8) {
                        Image(nsImage: AppCatalog.shared.icon(for: item.0)).resizable().frame(width: 16, height: 16)
                        Text(item.1).lineLimit(1)
                        Spacer()
                        Text(Format.duration(item.2)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }

            Divider()
            HStack {
                Button("Open Autotime") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                Spacer()
                Button { openSettings(); NSApp.activate(ignoringOtherApps: true) } label: { Image(systemName: "gearshape") }
                    .help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit Autotime")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 290)
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: .storeDidChange)) { _ in load() }
    }

    private func load() {
        Limits.shared.refresh()
        let start = Calendar.current.startOfDay(for: Date())
        let list = Store.shared.activities(in: start...start.addingTimeInterval(86400))
        total = list.reduce(0) { $0 + $1.duration }
        var dict: [String: (String, TimeInterval)] = [:]
        for a in list {
            let e = dict[a.bundleID] ?? (a.appName, 0)
            dict[a.bundleID] = (e.0, e.1 + a.duration)
        }
        top = dict.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.2 > $1.2 }.prefix(5).map { $0 }
    }
}
