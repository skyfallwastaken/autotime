import SwiftUI
import Combine

struct ContentView: View {
    @Environment(DayModel.self) private var model
    @State private var trusted = AccessibilityPermission.isTrusted
    @State private var showDatePicker = false
    private let permissionTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if !trusted {
                    PermissionBanner()
                }
                switch model.sidebar {
                case .stats:
                    StatsView(anchor: model.date)
                default:
                    HSplitView {
                        ActivityListView()
                            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                        TimelineView()
                            .frame(minWidth: 280, idealWidth: 400, maxWidth: 700, maxHeight: .infinity)
                    }
                }
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 0) {
                    Button { model.shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 28) }
                        .help("Previous Day")
                    Button { showDatePicker.toggle() } label: {
                        Text(Format.dayTitle(model.date))
                            .font(.headline)
                            .frame(minWidth: 170)
                    }
                    .popover(isPresented: $showDatePicker) {
                        VStack {
                            DatePicker("", selection: Binding(get: { model.date }, set: { model.date = Calendar.current.startOfDay(for: $0) }), in: ...Date(), displayedComponents: .date)
                                .datePickerStyle(.graphical)
                                .labelsHidden()
                            Button("Today") { model.goToToday(); showDatePicker = false }
                        }
                        .padding()
                    }
                    Button { model.shift(1) } label: { Image(systemName: "chevron.right").frame(width: 28) }
                        .help("Next Day")
                        .disabled(model.isToday)
                }
                .buttonStyle(.borderless)
            }
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search")
        .sheet(item: $model.deletion) { DeleteHistorySheet(filter: $0, day: model.date) }
        .sheet(item: $model.limitDraft) { LimitEditor(limit: $0) }
        .sheet(item: $model.projectDraft) { ProjectEditor(project: $0.project, isNew: $0.isNew) }
        .sheet(isPresented: $model.showExport) { ExportSheet(day: model.date) }
        .onReceive(permissionTimer) { _ in
            let now = AccessibilityPermission.isTrusted
            if now != trusted { trusted = now }
        }
    }
}

struct PermissionBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility access is needed")
                    .font(.headline)
                Text("Without it Autotime only records which app is in front, not window titles, URLs, paths or channels.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open System Settings") { AccessibilityPermission.openSettings() }
        }
        .padding(12)
        .background(.orange.opacity(0.12))
    }
}

struct SidebarView: View {
    @Environment(DayModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebar) {
            Label("Activities", systemImage: "waveform.path.ecg")
                .tag(SidebarItem.activities)
            Label("Stats", systemImage: "chart.pie")
                .tag(SidebarItem.stats)

            Section {
                ForEach(model.projectTotals, id: \.project.id) { item in
                    HStack(spacing: 8) {
                        Circle().fill(item.project.color).frame(width: 10, height: 10).frame(width: 16)
                        Text(item.project.name).lineLimit(1)
                        Spacer()
                        Text(Format.duration(item.duration))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .tag(SidebarItem.project(item.project.id))
                    .contextMenu {
                        Button("Edit Project…") { model.projectDraft = ProjectDraft(project: item.project, isNew: false) }
                        Button("Set Daily Limit…") { model.limitDraft = Limit(target: .project(item.project.id), minutes: 120) }
                        Divider()
                        Button("Delete Project", role: .destructive) {
                            if model.sidebar == .project(item.project.id) { model.sidebar = .activities }
                            Projects.shared.remove(item.project.id)
                        }
                    }
                }
                .onMove { Projects.shared.move(from: $0, to: $1) }
                Button { model.projectDraft = ProjectDraft(project: Projects.shared.newProject(), isNew: true) } label: {
                    Label("New Project", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            } header: {
                Text("Projects")
            }

            Section("Apps") {
                ForEach(model.appTotals, id: \.bundleID) { app in
                    HStack(spacing: 8) {
                        Image(nsImage: AppCatalog.shared.icon(for: app.bundleID))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(app.name)
                            .lineLimit(1)
                        Spacer()
                        Text(Format.duration(app.duration))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .tag(SidebarItem.app(app.bundleID))
                }
            }
        }
        .listStyle(.sidebar)
    }
}
