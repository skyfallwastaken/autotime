import SwiftUI
import Observation

struct Project: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var hue: Double
    var rules: [Rule] = []

    var color: Color { Color(hue: hue, saturation: 0.6, brightness: 0.85) }

    static let hues: [Double] = [0.58, 0.33, 0.08, 0.92, 0.75, 0.48, 0.15, 0.0]
    /// Stands in for "No Project" in lists grouped by project.
    static let unassigned = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}

struct ProjectDraft: Identifiable {
    var project: Project
    var isNew: Bool
    var id: UUID { project.id }
}

/// The user's projects, kept in projects.json next to the database. When several match an activity, the one listed first wins.
@MainActor
@Observable
final class Projects {
    static let shared = Projects()

    private(set) var list: [Project] = []
    /// Bumped on every change, so lists grouped by project know to rebuild.
    private(set) var version = 0
    @ObservationIgnored private var cache: [String: UUID?] = [:]

    private static let url = Store.directory.appendingPathComponent("projects.json")

    private init() {
        list = (try? Data(contentsOf: Self.url)).flatMap { try? JSONDecoder().decode([Project].self, from: $0) } ?? []
    }

    func project(for a: Activity) -> Project? {
        let key = a.key
        let id: UUID?
        if let cached = cache[key] {
            id = cached
        } else {
            id = list.first { $0.rules.contains { $0.matches(a) } }?.id
            if cache.count > 50_000 { cache.removeAll() }
            cache[key] = id
        }
        return id.flatMap { id in list.first { $0.id == id } }
    }

    func project(id: UUID) -> Project? { list.first { $0.id == id } }

    func save(_ project: Project) {
        if let i = list.firstIndex(where: { $0.id == project.id }) { list[i] = project } else { list.append(project) }
        changed()
    }

    func remove(_ id: UUID) {
        list.removeAll { $0.id == id }
        changed()
    }

    func move(from: IndexSet, to: Int) {
        list.move(fromOffsets: from, toOffset: to)
        changed()
    }

    func add(_ rule: Rule, to id: UUID) {
        guard let i = list.firstIndex(where: { $0.id == id }), !list[i].rules.contains(rule) else { return }
        list[i].rules.append(rule)
        changed()
    }

    func newProject(name: String = "", rules: [Rule] = []) -> Project {
        let used = Set(list.map(\.hue))
        return Project(name: name, hue: Project.hues.first { !used.contains($0) } ?? Double(list.count % 12) / 12, rules: rules)
    }

    private func changed() {
        cache.removeAll()
        version += 1
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: Self.url, options: .atomic) }
    }
}

struct ProjectEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var project: Project
    @State private var apps: [(bundleID: String, name: String)] = []
    var isNew: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Project" : "Edit Project").font(.headline)
            Form {
                TextField("Name", text: $project.name)
                LabeledContent("Colour") {
                    HStack(spacing: 6) {
                        ForEach(Project.hues, id: \.self) { hue in
                            Circle()
                                .fill(Color(hue: hue, saturation: 0.6, brightness: 0.85))
                                .frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(.primary.opacity(project.hue == hue ? 0.8 : 0), lineWidth: 2))
                                .onTapGesture { project.hue = hue }
                        }
                    }
                }
                Section {
                    ForEach(project.rules.indices, id: \.self) { i in
                        // Bounds-checked, as a removed row's binding can still be read once more.
                        let rule = Binding(get: { i < project.rules.count ? project.rules[i] : .keyword("") },
                                           set: { if i < project.rules.count { project.rules[i] = $0 } })
                        RuleRow(rule: rule, apps: apps) { if i < project.rules.count { project.rules.remove(at: i) } }
                    }
                    Button("Add Rule") { project.rules.append(.website("")) }
                } header: {
                    Text("Rules")
                } footer: {
                    Text("Activities matching any rule belong to this project. When several projects match, the one higher in the sidebar wins. You can also right-click a site, repo, folder or channel and choose Add to Project.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                if !isNew {
                    Button("Delete Project", role: .destructive) { Projects.shared.remove(project.id); dismiss() }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") {
                    project.name = project.name.trimmingCharacters(in: .whitespaces)
                    project.rules.removeAll { $0.value.trimmingCharacters(in: .whitespaces).isEmpty }
                    Projects.shared.save(project)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(project.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, height: 480)
        .task { apps = await Store.shared.recentApps() }
    }
}

struct RuleRow: View {
    @Binding var rule: Rule
    var apps: [(bundleID: String, name: String)]
    var remove: () -> Void

    var body: some View {
        HStack {
            Picker("", selection: Binding(get: { rule.kind }, set: { rule = Rule(kind: $0, value: $0 == .app ? (apps.first?.bundleID ?? "") : "") })) {
                ForEach(Rule.Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            switch rule.kind {
            case .app:
                Picker("", selection: Binding(get: { rule.value }, set: { rule = .app($0) })) {
                    if !apps.contains(where: { $0.bundleID == rule.value }) { Text(rule.label).tag(rule.value) }
                    ForEach(apps, id: \.bundleID) { Text($0.name).tag($0.bundleID) }
                }
                .labelsHidden()
            case .folder:
                TextField("", text: valueBinding, prompt: Text(rule.kind.placeholder))
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = true
                    if panel.runModal() == .OK, let url = panel.url { rule = .folder(ActivityPath.abbreviate(url.path, directory: false)) }
                }
            default:
                TextField("", text: valueBinding, prompt: Text(rule.kind.placeholder))
            }
            Button { remove() } label: { Image(systemName: "minus.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
    }

    private var valueBinding: Binding<String> {
        Binding(get: { rule.value }, set: { rule = Rule(kind: rule.kind, value: $0) })
    }
}
