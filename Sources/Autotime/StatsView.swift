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

    private static let spacing: CGFloat = 12
    private static let listLimit = 8

    private var interval: DateInterval {
        let cal = Calendar.current
        switch range {
        case .day: return cal.dateInterval(of: .day, for: anchor)!
        case .week: return cal.dateInterval(of: .weekOfYear, for: anchor)!
        case .month: return cal.dateInterval(of: .month, for: anchor)!
        }
    }

    var body: some View {
        let query = model.search.trimmingCharacters(in: .whitespaces)
        let data = query.isEmpty ? activities : activities.filter {
            $0.appName.localizedCaseInsensitiveContains(query) || $0.title.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query)
        }
        let apps = Self.totals(data) { ($0.bundleID, $0.appName) }
        let total = data.reduce(0) { $0 + $1.duration }

        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: Self.spacing) {
                    header
                    if data.isEmpty {
                        ContentUnavailableView(
                            query.isEmpty ? "No Activity" : "No Matching Activity",
                            systemImage: query.isEmpty ? "chart.bar" : "magnifyingglass",
                            description: Text(query.isEmpty ? "Nothing was recorded in this period." : "Try a different search.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 320)
                    } else {
                        summary(data, apps: apps, total: total)
                        if geo.size.width >= 860 {
                            HStack(alignment: .top, spacing: Self.spacing) {
                                chartCard(data, apps: apps)
                                appsCard(apps, total: total)
                                    .frame(width: min(460, geo.size.width * 0.42))
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        } else {
                            chartCard(data, apps: apps)
                            appsCard(apps, total: total)
                        }
                        MasonryLayout(minColumnWidth: 300, spacing: Self.spacing) {
                            ForEach(sections(data, total: total)) { section in
                                Card(title: section.title, detail: section.detail) {
                                    RankList(items: section.items, total: total)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .onAppear(perform: load)
        .onChange(of: range) { load() }
        .onChange(of: anchor) { load() }
        .onReceive(NotificationCenter.default.publisher(for: .storeDidChange)) { _ in
            if interval.contains(Date()) { load() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Stats")
                .font(.title2.weight(.semibold))
            Text(rangeTitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 12)
            Picker("", selection: $range) {
                ForEach(StatsRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private func summary(_ data: [Activity], apps: [Total], total: TimeInterval) -> some View {
        let sessions = Sessions.byApp(data, gap: 10)
        let focus = sessions.max { $0.duration < $1.duration }
        let days = activeDays(data)
        let span = data.first.flatMap { first in
            data.map(\.end).max().map { "\(Format.time.string(from: first.start)) – \(Format.time.string(from: $0))" }
        }
        return HStack(spacing: Self.spacing) {
            StatTile(title: "Total Time", value: Format.duration(total), detail: range == .day ? span : "\(apps.count) apps")
            if range == .day {
                StatTile(title: "Apps Used", value: "\(apps.count)", detail: "\(max(0, sessions.count - 1)) switches")
            } else {
                StatTile(title: "Daily Average", value: Format.duration(total / Double(max(1, days))), detail: "\(days) active day\(days == 1 ? "" : "s")")
            }
            StatTile(title: "Top App", value: apps.first?.name ?? "—", detail: apps.first.map { "\(Format.duration($0.duration)) · \(Self.percent($0.duration, of: total))" })
            StatTile(title: "Longest Focus", value: Format.duration(focus?.duration ?? 0), detail: focus?.appName)
        }
    }

    private func chartCard(_ data: [Activity], apps: [Total]) -> some View {
        Card(title: range == .day ? "By Hour" : "By Day") {
            timeChart(data, apps: apps)
                .frame(minHeight: 200, idealHeight: 200, maxHeight: .infinity)
        }
    }

    private func appsCard(_ apps: [Total], total: TimeInterval) -> some View {
        Card(title: "Apps", detail: apps.count > Self.listLimit ? "Top \(Self.listLimit) of \(apps.count)" : nil) {
            HStack(alignment: .center, spacing: 16) {
                donut(apps, total: total)
                    .frame(width: 128, height: 128)
                RankList(items: apps.prefix(Self.listLimit).map {
                    RankItem(id: $0.key, label: $0.name, duration: $0.duration, icon: .app($0.key), tint: AppCatalog.shared.color(for: $0.key))
                }, total: total)
            }
        }
    }

    private struct RankSection: Identifiable {
        var title: String
        var detail: String?
        var items: [RankItem]
        var id: String { title }
    }

    /// Detail lists; empty ones are omitted so the layout has no placeholder cards.
    private func sections(_ data: [Activity], total: TimeInterval) -> [RankSection] {
        func section(_ title: String, _ totals: [Total], showSum: Bool = true, item: (Total) -> RankItem) -> RankSection? {
            guard !totals.isEmpty else { return nil }
            let sum = totals.reduce(0) { $0 + $1.duration }
            return RankSection(title: title, detail: showSum ? Format.duration(sum) : nil, items: totals.prefix(Self.listLimit).map(item))
        }
        let categories = Self.totals(data) { let c = AppCatalog.shared.category(for: $0.bundleID); return (c, c) }
        return [
            section("Categories", categories, showSum: false) {
                RankItem(id: $0.key, label: $0.name, duration: $0.duration, icon: .category($0.name), tint: AppCatalog.shared.color(forCategory: $0.name))
            },
            section("Websites", Self.domains(data)) {
                RankItem(id: $0.key, label: $0.name, duration: $0.duration, icon: .domain($0.name), tint: .accentColor)
            },
            section("Folders & Documents", Self.files(data)) {
                RankItem(id: $0.key, label: $0.name, duration: $0.duration, icon: .file($0.key), tint: .accentColor)
            },
            section("Conversations & Places", Self.places(data)) {
                RankItem(id: $0.key + $0.name, label: $0.name, duration: $0.duration, icon: .app($0.key), tint: AppCatalog.shared.color(for: $0.key))
            },
        ].compactMap { $0 }
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

    static func percent(_ value: TimeInterval, of total: TimeInterval) -> String {
        guard total > 0 else { return "" }
        let p = value / total * 100
        return p < 1 ? "<1%" : "\(Int(p.rounded()))%"
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

    /// The day chart only spans the hours with activity (at least six) instead of a mostly empty 24 hours.
    private func chartDomain(_ data: [Activity]) -> ClosedRange<Date> {
        let cal = Calendar.current
        guard range == .day, let first = data.map(\.start).min(), let last = data.map(\.end).max(),
              let lowHour = cal.dateInterval(of: .hour, for: first),
              let highHour = cal.dateInterval(of: .hour, for: max(first, last.addingTimeInterval(-1))) else {
            return interval.start...interval.end
        }
        let minSpan: TimeInterval = 6 * 3600
        var lo = lowHour.start
        var hi = highHour.end
        if hi.timeIntervalSince(lo) < minSpan {
            hi = min(interval.end, lo.addingTimeInterval(minSpan))
            lo = max(interval.start, hi.addingTimeInterval(-minSpan))
        }
        return lo...hi
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
        .chartXScale(domain: chartDomain(data))
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
        let top = Array(apps.prefix(Self.listLimit))
        let rest = apps.dropFirst(Self.listLimit).reduce(0) { $0 + $1.duration }
        let slices = top.map { ($0.name, $0.duration, AppCatalog.shared.color(for: $0.key)) } + (rest > 0 ? [("Other", rest, Color.gray)] : [])
        Chart(slices, id: \.0) { slice in
            SectorMark(angle: .value("Time", slice.1), innerRadius: .ratio(0.62), angularInset: 1)
                .cornerRadius(2)
                .foregroundStyle(slice.2)
        }
        .chartBackground { _ in
            VStack(spacing: 0) {
                Text(Format.duration(total))
                    .font(.headline)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("total")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 70)
        }
    }
}

struct StatTile: View {
    var title: String
    var value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail ?? " ")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

struct Card<Content: View>: View {
    var title: String
    var detail: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

struct RankItem: Identifiable {
    var id: String
    var label: String
    var duration: TimeInterval
    var icon: NodeKind
    var tint: Color
}

/// One line per item: the bar behind the row shows its share relative to the largest item.
struct RankList: View {
    var items: [RankItem]
    var total: TimeInterval

    var body: some View {
        let largest = max(1, items.first?.duration ?? 1)
        VStack(spacing: 2) {
            ForEach(items) { item in
                HStack(spacing: 8) {
                    NodeIcon(kind: item.icon)
                    Text(item.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.label)
                    Spacer(minLength: 8)
                    Text(StatsView.percent(item.duration, of: total))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                    Text(Format.duration(item.duration))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 48, alignment: .trailing)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(alignment: .leading) {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(item.tint.opacity(0.16))
                            .frame(width: max(4, geo.size.width * CGFloat(item.duration / largest)))
                    }
                }
            }
        }
    }
}

/// Places each card in the currently shortest column, so cards of different heights pack without row gaps.
struct MasonryLayout: Layout {
    var minColumnWidth: CGFloat
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposed = proposal.width ?? minColumnWidth
        let width = proposed.isFinite ? proposed : minColumnWidth
        let height = frames(width: width, subviews: subviews).map(\.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        guard !subviews.isEmpty else { return [] }
        let count = max(1, min(subviews.count, Int((width + spacing) / (minColumnWidth + spacing))))
        let columnWidth = max(0, (width - CGFloat(count - 1) * spacing) / CGFloat(count))
        var heights = [CGFloat](repeating: 0, count: count)
        return subviews.map { subview in
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let height = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            let frame = CGRect(x: CGFloat(column) * (columnWidth + spacing), y: heights[column], width: columnWidth, height: height)
            heights[column] += height + spacing
            return frame
        }
    }
}
