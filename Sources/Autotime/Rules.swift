import AppKit

/// Something an activity can be matched against: projects are made of these, and limits and exclusions use the same matching.
enum Rule: Codable, Hashable {
    case app(String)
    case website(String)
    case repo(String)
    case folder(String)
    case ampProject(String)
    /// A Slack, Discord or Teams path prefix, such as "Hack Club ▸ general (Channel)".
    case conversation(String)
    case keyword(String)

    enum Kind: String, CaseIterable, Identifiable {
        case app = "App"
        case website = "Website"
        case repo = "GitHub Repo"
        case folder = "Folder or File"
        case ampProject = "Amp Project"
        case conversation = "Conversation"
        case keyword = "Keyword"
        var id: String { rawValue }

        var placeholder: String {
            switch self {
            case .app: "Bundle ID"
            case .website: "example.com"
            case .repo: "owner/repo"
            case .folder: "~/code/project"
            case .ampProject: "Project name"
            case .conversation: "Workspace ▸ channel"
            case .keyword: "Text in the title, URL or path"
            }
        }
    }

    init(kind: Kind, value: String) {
        switch kind {
        case .app: self = .app(value)
        case .website: self = .website(value)
        case .repo: self = .repo(value)
        case .folder: self = .folder(value)
        case .ampProject: self = .ampProject(value)
        case .conversation: self = .conversation(value)
        case .keyword: self = .keyword(value)
        }
    }

    var kind: Kind {
        switch self {
        case .app: .app
        case .website: .website
        case .repo: .repo
        case .folder: .folder
        case .ampProject: .ampProject
        case .conversation: .conversation
        case .keyword: .keyword
        }
    }

    var value: String {
        switch self {
        case .app(let v), .website(let v), .repo(let v), .folder(let v), .ampProject(let v), .conversation(let v), .keyword(let v): v
        }
    }

    var label: String {
        switch self {
        case .app(let id): AppCatalog.shared.name(for: id)
        case .folder(let p): ActivityPath.abbreviate(p, directory: false)
        default: value
        }
    }

    /// The rule for a row in the activity list, for "Add to Project".
    init?(node: TreeNode) {
        switch node.kind {
        case .app(let id): self = .app(id)
        case .domain(let host): self = .website(host)
        case .githubRepo(let repo): self = .repo(repo)
        case .ampProject(let name): self = .ampProject(name)
        case .file(let path): self = .folder(path)
        case .slackChannel(let workspace, let name): self = .conversation(workspace + Extractor.separator + name + " (Channel)")
        case .slackDM(let workspace, let name): self = .conversation(workspace + Extractor.separator + name + " (DM)")
        default: return nil
        }
    }

    func matches(_ a: Activity) -> Bool {
        switch self {
        case .app(let id):
            return a.bundleID == id
        case .website(let host):
            return Hosts.webHost(a.path).map { Hosts.matches($0, host) } ?? false
        case .repo(let repo):
            guard let url = URL(string: a.path), let r = ActivityPath.githubRepo(url) else { return false }
            return r.caseInsensitiveCompare(repo.trimmingCharacters(in: .whitespaces)) == .orderedSame
        case .folder(let folder):
            guard let url = URL(string: a.path), url.isFileURL else { return false }
            let f = (folder.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            guard !f.isEmpty else { return false }
            return url.path == f || url.path.hasPrefix(f.hasSuffix("/") ? f : f + "/")
        case .ampProject(let name):
            return a.bundleID == AmpExtractor.bundleID && a.path.components(separatedBy: Extractor.separator).first == name
        case .conversation(let prefix):
            return !prefix.isEmpty && Hosts.webHost(a.path) == nil && a.path.hasPrefix(prefix)
        case .keyword(let text):
            let t = text.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && (a.title.localizedCaseInsensitiveContains(t) || a.path.localizedCaseInsensitiveContains(t) || a.appName.localizedCaseInsensitiveContains(t))
        }
    }
}

enum Hosts {
    /// The host of an http(s) URL, lowercased and without "www.".
    static func webHost(_ path: String) -> String? {
        guard path.hasPrefix("http"), let url = URL(string: path), let scheme = url.scheme, scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Whether `host` is `pattern` or one of its subdomains.
    static func matches(_ host: String, _ pattern: String) -> Bool {
        var p = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        if p.hasPrefix("www.") { p.removeFirst(4) }
        guard !p.isEmpty else { return false }
        return host == p || host.hasSuffix("." + p)
    }
}

extension AppCatalog {
    func name(for bundleID: String) -> String {
        guard let url = appURL(bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
