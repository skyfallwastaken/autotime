import SwiftUI

struct ActivityListView: View {
    @Environment(DayModel.self) private var model

    var body: some View {
        let visible = model.visible
        let total = model.searched.reduce(0) { $0 + $1.duration }
        let selected = visible.reduce(0) { $0 + $1.duration }

        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(headerTitle(total: total, selected: selected))
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if model.selection != nil {
                    Button { model.selection = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear Selection")
                }
                Spacer(minLength: 12)
                Picker("", selection: $model.mode) {
                    ForEach(ViewMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if visible.isEmpty {
                EmptyStateView(searching: !model.search.isEmpty)
            } else if model.mode == .chronological {
                ChronologicalList(sessions: model.sessions)
            } else {
                OutlineList(nodes: model.tree)
            }
        }
    }

    private func headerTitle(total: TimeInterval, selected: TimeInterval) -> String {
        var name = "All Activities"
        if let app = model.appFilter {
            name = model.appTotals.first { $0.bundleID == app }?.name ?? name
        }
        var s = "\(name): \(Format.duration(total))"
        if model.selection != nil { s += " (\(Format.duration(selected, seconds: true)) selected)" }
        return s
    }
}

struct EmptyStateView: View {
    var searching: Bool

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: searching ? "magnifyingglass" : "clock.badge.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(searching ? "No matching activities" : "No activities recorded")
                .font(.title3)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct OutlineRow: Identifiable {
    var node: TreeNode
    var depth: Int
    var id: String { node.id }
}

struct OutlineList: View {
    @Environment(DayModel.self) private var model
    var nodes: [TreeNode]

    var body: some View {
        List {
            ForEach(rows()) { row in
                NodeRow(row: row, expanded: model.expanded.contains(row.id)) { recursive in
                    let value = !model.expanded.contains(row.id)
                    withAnimation(.easeOut(duration: 0.15)) {
                        model.setExpanded(row.node, value, recursive: recursive)
                    }
                }
                .listRowSeparator(.visible)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private func rows() -> [OutlineRow] {
        var result: [OutlineRow] = []
        func walk(_ list: [TreeNode], _ depth: Int) {
            for n in list {
                result.append(OutlineRow(node: n, depth: depth))
                if model.expanded.contains(n.id) { walk(n.children, depth + 1) }
            }
        }
        walk(nodes, 0)
        return result
    }
}

struct NodeRow: View {
    var row: OutlineRow
    var expanded: Bool
    var toggle: (Bool) -> Void

    var body: some View {
        let node = row.node
        HStack(spacing: 6) {
            Text(Format.duration(node.duration))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            Color.clear.frame(width: CGFloat(row.depth) * 18, height: 1)
            Group {
                if node.children.isEmpty {
                    Color.clear
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .frame(width: 14)
            NodeIcon(kind: node.kind)
            Text(node.label)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(node.kind == .none || node.kind == .others ? .secondary : .primary)
                .help(node.tooltip)
            if case .xUser(let handle) = node.kind {
                XDisplayName(handle: handle)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !node.children.isEmpty else { return }
            toggle(NSEvent.modifierFlags.contains(.option))
        }
        .contextMenu { NodeMenu(node: node) }
    }
}

extension TreeNode {
    /// Page rows are labelled by title, so their tooltip shows the URL instead.
    var tooltip: String {
        if case .url(let s) = kind { return "\(label)\n\(s)" }
        return label
    }
}

struct NodeIcon: View {
    var kind: NodeKind

    var body: some View {
        switch kind {
        case .app(let id):
            Image(nsImage: AppCatalog.shared.icon(for: id)).resizable().frame(width: 16, height: 16)
        case .category(let name):
            Circle().fill(AppCatalog.shared.color(forCategory: name)).frame(width: 11, height: 11).frame(width: 16)
        case .domain(let host):
            FaviconView(host: host, fallback: "globe")
        case .url(let s):
            if let host = URL(string: s)?.host {
                FaviconView(host: host, fallback: "link")
            } else {
                Image(systemName: "link").foregroundStyle(.secondary).frame(width: 16)
            }
        case .xUser(let handle):
            XAvatarView(handle: handle)
        case .githubRepo(let repo):
            GitHubOwnerAvatar(repo: repo)
        case .ampProject(let name):
            AmpProjectIcon(project: name)
        case .ampThread(let project, let title):
            AmpThreadIconView(project: project, title: title)
        case .ampPuck:
            AmpPuckIcon()
        case .slackChannel(let workspace, let name):
            SlackChannelIcon(workspace: workspace, name: name)
        case .slackDM(let workspace, let name):
            SlackDMIcon(workspace: workspace, name: name)
        case .file(let path):
            Image(nsImage: AppCatalog.shared.fileIcon(for: path)).resizable().frame(width: 16, height: 16)
        case .others:
            Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 16)
        default:
            EmptyView()
        }
    }
}

struct NodeMenu: View {
    var node: TreeNode

    var body: some View {
        Button("Copy") { copy(node.label) }
        switch node.kind {
        case .url(let s):
            Button("Copy URL") { copy(s) }
            if let url = URL(string: s) { Button("Open in Browser") { NSWorkspace.shared.open(url) } }
        case .domain(let host):
            if let url = URL(string: "https://\(host)") { Button("Open \(host)") { NSWorkspace.shared.open(url) } }
        case .xUser(let handle):
            if let url = URL(string: "https://x.com/\(handle)") { Button("Open Profile") { NSWorkspace.shared.open(url) } }
        case .githubRepo(let repo):
            if let url = URL(string: "https://github.com/\(repo)") { Button("Open Repository") { NSWorkspace.shared.open(url) } }
        case .file(let path):
            Button("Copy Path") { copy(path) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        case .app(let id):
            if let url = AppCatalog.shared.appURL(id) { Button("Open \(node.label)") { NSWorkspace.shared.open(url) } }
        default:
            EmptyView()
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct ChronologicalList: View {
    @Environment(DayModel.self) private var model
    var sessions: [Session]

    var body: some View {
        List(sessions) { s in
            HStack(spacing: 8) {
                Text(Format.duration(s.duration))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
                Text("\(Format.time.string(from: s.start)) – \(Format.time.string(from: s.end))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 130, alignment: .leading)
                Image(nsImage: AppCatalog.shared.icon(for: s.bundleID)).resizable().frame(width: 16, height: 16)
                Text(s.appName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .fixedSize()
                Text(s.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help(s.path.isEmpty ? s.label : s.path)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture { model.selection = s.start...s.end }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}
