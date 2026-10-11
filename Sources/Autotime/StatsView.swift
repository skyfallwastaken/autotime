import SwiftUI
import Charts

enum StatsRange: String, CaseIterable, Identifiable {
    case day = "Day"
    case week = "Week"
    case month = "Month"
    var id: String { rawValue }
}

struct StatsView: View {
    var anchor: Date
    @EnvironmentObject var model: DayModel
    @State private var range: StatsRange = .day
    @State private var activities: [Activity] = []

    private var interval: DateInterval {
        let cal = Calendar.current
        switch range {
        case .day: return cal.dateInterval(of: .day, for: anchor)!
        case .week: return cal.dateInterval(of: .weekOfYear, for: anchor)!
        case .month: return cal.dateInterval(of: .month, for: anchor)!
        }
    }

    var body: some View {
        let data = model.search.isEmpty ? activities : activities.filter {
            $0.appName.localizedCaseInsensitiveContains(model.search) || $0.title.localizedCaseInsensitiveContains(model.search) || $0.path.localizedCaseInsensitiveContains(model.search)
        }
        let apps = Self.totals(data) { ($0.bundleID, $0.appName) }
        let total = data.reduce(0) { $0 + $1.duration }

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Stats")
                        .font(.title2.weight(.semibold))
                    Text(rangeTitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $range) {
                        ForEach(StatsRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                    StatTile(title: "Total Time", value: Format.duration(total))
                    StatTile(title: range == .day ? "Apps Used" : "Daily Average", value: range == .day ? "\(apps.count)" : Format.duration(total / Double(max(1, activeDays(data)))))
                    StatTile(title: "Top App", value: apps.first?.name ?? "—")
                    StatTile(title: "Longest Focus", value: Format.duration(Sessions.byApp(data, gap: 10).map(\.duration).max() ?? 0))
                }

                Card(title: range == .day ? "By Hour" : "By Day") {
                    timeChart(data, apps: apps)
                        .frame(height: 220)
                }

                HStack(alignment: .top, spacing: 14) {
                    Card(title: "Apps") {
                        donut(apps, total: total)
                            .frame(height: 240)
                    }
                    Card(title: "Top Apps") {
                        RankList(items: apps.prefix(10).map { RankItem(label: $0.name, duration: $0.duration, icon: .app($0.key)) }, total: total)
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14, alignment: .top)], spacing: 14) {
                    Card(title: "Websites") {
                        RankList(items: Self.domains(data).prefix(10).map { RankItem(label: $0.name, duration: $0.duration, icon: .domain($0.name)) }, total: total)
                    }
                    Card(title: "Folders & Documents") {
                        RankList(items: Self.files(data).prefix(10).map { RankItem(label: $0.name, duration: $0.duration, icon: .file($0.key)) }, total: total)
                    }
                    Card(title: "Conversations & Places") {
                        RankList(items: Self.places(data).prefix(10).map { RankItem(label: $0.name, duration: $0.duration, icon: .app($0.key)) }, total: total)
                    }
                    Card(title: "Categories") {
                        RankList(items: Self.totals(data) { let c = AppCatalog.shared.category(for: $0.bundleID); return (c, c) }.prefix(10).map { RankItem(label: $0.name, duration: $0.duration, icon: .category($0.name)) }, total: total)
                    }
                }
            }
            .padding(20)
        }
        .onAppear(perform: load)
        .onChange(of: range) { load() }
        .onChange(of: anchor) { load() }
        .onReceive(NotificationCenter.default.publisher(for: .storeDidChange)) { _ in
            if interval.contains(Date()) { load() }
        }
    }

    private var rangeTitle: String {
        let f = DateFormatter()
        switch range {
        case .day: return Format.dayTitle(anchor)
        case .week:
            f.setLocalizedDateFormatFromTemplate("d MMM")
            return "\(f.string(from: interval.start)) – \(f.string(from: interval.end.addingTimeInterval(-1)))"
        case .month:
            f.setLocalizedDateFormatFromTemplate("MMMM yyyy")
            return f.string(from: anchor)
        }
    }

    private func load() {
        activities = Store.shared.activities(in: interval.start...interval.end)
    }

    private func activeDays(_ data: [Activity]) -> Int {
        Set(data.map { Calendar.current.startOfDay(for: $0.start) }).count
    }

    struct Total { var key: String; var name: String; var duration: TimeInterval }

    static func totals(_ data: [Activity], key: (Activity) -> (String, String)?) -> [Total] {
        var dict: [String: Total] = [:]
        for a in data {
            guard let (k, name) = key(a) else { continue }
            dict[k, default: Total(key: k, name: name, duration: 0)].duration += a.duration
        }
        return dict.values.sorted { $0.duration > $1.duration }
    }

    static func domains(_ data: [Activity]) -> [Total] {
        totals(data) { a in
            guard let url = URL(string: a.path), url.scheme?.hasPrefix("http") == true, let host = url.host else { return nil }
            return (host, host)
        }
    }

    static func files(_ data: [Activity]) -> [Total] {
        totals(data) { a in
            guard let url = URL(string: a.path), url.isFileURL else { return nil }
            return (url.path, ActivityPath.abbreviate(url.path, directory: url.hasDirectoryPath))
        }
    }

    static func places(_ data: [Activity]) -> [Total] {
        var dict: [String: Total] = [:]
        for a in data where a.path.contains(Extractor.separator) {
            let name = a.path.components(separatedBy: Extractor.separator).prefix(2).joined(separator: " › ")
            dict[a.bundleID + name, default: Total(key: a.bundleID, name: name, duration: 0)].duration += a.duration
        }
        return dict.values.sorted { $0.duration > $1.duration }
    }

    private struct Bucket: Identifiable {
        var id: String { "\(start.timeIntervalSince1970)-\(app)" }
        var start: Date
        var app: String
        var minutes: Double
    }

    @ViewBuilder
    private func timeChart(_ data: [Activity], apps: [Total]) -> some View {
        let top = Array(apps.prefix(6))
        let topIDs = Set(top.map(\.key))
        let names = top.map(\.name) + (apps.count > 6 ? ["Other"] : [])
        let colors = top.map { AppCatalog.shared.color(for: $0.key) } + (apps.count > 6 ? [Color.gray] : [])
        let unit: Calendar.Component = range == .day ? .hour : .day
        let buckets = Self.buckets(data, unit: unit, name: { topIDs.contains($0.bundleID) ? $0.appName : "Other" })

        Chart(buckets) { b in
            BarMark(
                x: .value("Time", b.start, unit: unit),
                y: .value("Minutes", range == .day ? b.minutes : b.minutes / 60)
            )
            .foregroundStyle(by: .value("App", b.app))
        }
        .chartForegroundStyleScale(domain: names, range: colors)
        .chartXScale(domain: interval.start...interval.end)
        .chartYAxisLabel(range == .day ? "minutes" : "hours")
        .chartLegend(position: .bottom, alignment: .leading)
    }

    private static func buckets(_ data: [Activity], unit: Calendar.Component, name: (Activity) -> String) -> [Bucket] {
        let cal = Calendar.current
        var dict: [String: Bucket] = [:]
        for a in data {
            var cursor = a.start
            while cursor < a.end {
                guard let slot = cal.dateInterval(of: unit, for: cursor) else { break }
                let end = min(a.end, slot.end)
                let n = name(a)
                let key = "\(slot.start.timeIntervalSince1970)-\(n)"
                dict[key, default: Bucket(start: slot.start, app: n, minutes: 0)].minutes += end.timeIntervalSince(cursor) / 60
                cursor = end
            }
        }
        return dict.values.sorted { $0.start < $1.start }
    }

    @ViewBuilder
    private func donut(_ apps: [Total], total: TimeInterval) -> some View {
        let top = Array(apps.prefix(8))
        let rest = apps.dropFirst(8).reduce(0) { $0 + $1.duration }
        let slices = top.map { ($0.name, $0.duration, AppCatalog.shared.color(for: $0.key)) } + (rest > 0 ? [("Other", rest, Color.gray)] : [])
        Chart(slices, id: \.0) { slice in
            SectorMark(angle: .value("Time", slice.1), innerRadius: .ratio(0.6), angularInset: 1.2)
                .cornerRadius(3)
                .foregroundStyle(slice.2)
        }
        .chartBackground { _ in
            VStack(spacing: 2) {
                Text(Format.duration(total)).font(.title2.weight(.semibold))
                Text("total").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct StatTile: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

struct Card<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

struct RankItem: Identifiable {
    var id: String { label }
    var label: String
    var duration: TimeInterval
    var icon: NodeKind
}

struct RankList: View {
    var items: [RankItem]
    var total: TimeInterval

    var body: some View {
        if items.isEmpty {
            Text("Nothing yet")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            NodeIcon(kind: item.icon)
                            Text(item.label)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(Format.duration(item.duration))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        GeometryReader { geo in
                            Capsule()
                                .fill(Color.accentColor.opacity(0.6))
                                .frame(width: max(2, geo.size.width * CGFloat(item.duration / max(1, items.first?.duration ?? 1))))
                        }
                        .frame(height: 3)
                    }
                }
            }
        }
    }
}
