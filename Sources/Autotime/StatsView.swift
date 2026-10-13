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
    @Environment(DayModel.self) private var model
    @State private var range: StatsRange = .day
    @State private var activities: [Activity] = []

    /// Apps drawn in their own colour in the chart, donut and apps list; the rest are grouped as "Other".
    private static let colored = 7

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
            VStack(alignment: .leading, spacing: 12) {
                header
                if data.isEmpty {
                    ContentUnavailableView(
                        model.search.isEmpty ? "No activities recorded" : "No matching activities",
                        systemImage: model.search.isEmpty ? "clock.badge.questionmark" : "magnifyingglass",
                        description: Text(rangeTitle)
                    )
                    .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    summary(data, apps: apps, total: total)

                    // Chart and apps side by side while the chart keeps a useful width; when space is tight the donut is dropped before stacking.
                    ViewThatFits(in: .horizontal) {
                        chartAndApps(data, apps: apps, total: total, chartWidth: 440, appsWidth: 380, donut: true)
                        chartAndApps(data, apps: apps, total: total, chartWidth: 360, appsWidth: 300, donut: false)
                        VStack(spacing: 12) {
                            chartCard(data, apps: apps)
                            appsCard(apps, total: total, donut: true)
                        }
                    }

                    MasonryLayout(minColumnWidth: 280, spacing: 12) {
                        detailCards(data, total: total)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 20)
        }
        .onAppear(perform: load)
        .onChange(of: range) { load() }
        .onChange(of: anchor) { load() }
        .onReceive(NotificationCenter.default.publisher(for: .storeDidChange)) { _ in
            if interval.contains(Date()) { load() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
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
        let days = activeDays(data)
        let focus = Sessions.byApp(data, gap: 10).max { $0.duration < $1.duration }
        let categories = Set(data.map { AppCatalog.shared.category(for: $0.bundleID) }).count
        let span: String = {
            guard let first = data.map(\.start).min(), let last = data.map(\.end).max() else { return "" }
            return "\(Format.time.string(from: first)) – \(Format.time.string(from: last))"
        }()

        return HStack(alignment: .top, spacing: 0) {
            Metric(title: "Total Time", value: Format.duration(total),
                   detail: range == .day ? span : "\(apps.count) apps")
            Divider().padding(.horizontal, 14)
            if range == .day {
                Metric(title: "Apps Used", value: "\(apps.count)", detail: "\(categories) \(categories == 1 ? "category" : "categories")")
            } else {
                Metric(title: "Daily Average", value: Format.duration(total / Double(max(1, days))), detail: "\(days) active \(days == 1 ? "day" : "days")")
            }
            Divider().padding(.horizontal, 14)
            Metric(title: "Top App", value: apps.first?.name ?? "—",
                   detail: apps.first.map { "\(Format.duration($0.duration)) · \(Format.percent($0.duration, of: total))" } ?? "",
                   icon: apps.first?.key)
            Divider().padding(.horizontal, 14)
            Metric(title: "Longest Focus", value: Format.duration(focus?.duration ?? 0), detail: focus?.appName ?? "")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func chartAndApps(_ data: [Activity], apps: [Total], total: TimeInterval, chartWidth: CGFloat, appsWidth: CGFloat, donut: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            chartCard(data, apps: apps)
                .frame(minWidth: chartWidth, idealWidth: chartWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            appsCard(apps, total: total, donut: donut)
                .frame(width: appsWidth)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chartCard(_ data: [Activity], apps: [Total]) -> some View {
        Card(title: range == .day ? "By Hour" : "By Day") {
            timeChart(data, apps: apps)
                .frame(minHeight: 180, idealHeight: 180, maxHeight: .infinity)
        }
    }

    private func appsCard(_ apps: [Total], total: TimeInterval, donut showDonut: Bool) -> some View {
        let rest = apps.dropFirst(Self.colored)
        var items = apps.prefix(Self.colored).map {
            RankItem(label: $0.name, duration: $0.duration, icon: .app($0.key), tint: AppCatalog.shared.color(for: $0.key))
        }
        if !rest.isEmpty {
            items.append(RankItem(label: "Other (\(rest.count) \(rest.count == 1 ? "app" : "apps"))", duration: rest.reduce(0) { $0 + $1.duration }, icon: .none, tint: .gray))
        }
        return Card(title: "Apps") {
            HStack(alignment: .center, spacing: 14) {
                if showDonut {
                    donut(items, total: total)
                        .frame(width: 108, height: 108)
                }
                RankList(items: items, total: total, relativeToTotal: true)
            }
        }
    }

    @ViewBuilder
    private func detailCards(_ data: [Activity], total: TimeInterval) -> some View {
        let categories = Self.totals(data) { let c = AppCatalog.shared.category(for: $0.bundleID); return (c, c) }
        let domains = Self.domains(data)
        let files = Self.files(data)
        let places = Self.places(data)

        Card(title: "Categories") {
            RankList(items: categories.prefix(10).map { RankItem(label: $0.name, duration: $0.duration, icon: .category($0.name), tint: AppCatalog.shared.color(forCategory: $0.name)) }, total: total)
        }
        if !domains.isEmpty {
            Card(title: "Websites") {
                RankList(items: domains.prefix(10).map { RankItem(label: $0.name, duration: $0.duration, icon: .domain($0.name)) }, total: total)
            }
        }
        if !files.isEmpty {
            Card(title: "Folders & Documents") {
                RankList(items: files.prefix(10).map { RankItem(label: $0.name, duration: $0.duration, icon: .file($0.key)) }, total: total)
            }
        }
        if !places.isEmpty {
            Card(title: "Conversations & Places") {
                RankList(items: places.prefix(10).map { RankItem(label: $0.name, duration: $0.duration, icon: .app($0.key)) }, total: total)
            }
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
        let top = Array(apps.prefix(Self.colored))
        let topIDs = Set(top.map(\.key))
        let other = apps.count > Self.colored
        let names = top.map(\.name) + (other ? ["Other"] : [])
        let colors = top.map { AppCatalog.shared.color(for: $0.key) } + (other ? [Color.gray] : [])
        let unit: Calendar.Component = range == .day ? .hour : .day
        let buckets = Self.buckets(data, unit: unit, name: { topIDs.contains($0.bundleID) ? $0.appName : "Other" })
        let suffix = range == .day ? "m" : "h"

        Chart(buckets) { b in
            BarMark(
                x: .value("Time", b.start, unit: unit),
                y: .value(range == .day ? "Minutes" : "Hours", range == .day ? b.minutes : b.minutes / 60)
            )
            .foregroundStyle(by: .value("App", b.app))
        }
        .chartForegroundStyleScale(domain: names, range: colors)
        .chartXScale(domain: chartDomain(data))
        .chartXAxis {
            if range == .week {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated).day(), centered: true)
                }
            } else {
                AxisMarks()
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text("\(v.formatted())\(suffix)") }
                }
            }
        }
        .chartLegend(.hidden)
    }

    /// Days show only the hours with activity (at least eight), so bars aren't squeezed into one corner of a 24-hour axis.
    private func chartDomain(_ data: [Activity]) -> ClosedRange<Date> {
        let cal = Calendar.current
        guard range == .day, let first = data.map(\.start).min(), let last = data.map(\.end).max(),
              var lo = cal.dateInterval(of: .hour, for: first)?.start,
              var hi = cal.dateInterval(of: .hour, for: last.addingTimeInterval(-1))?.end
        else { return interval.start...interval.end }
        let minSpan: TimeInterval = 8 * 3600
        if hi.timeIntervalSince(lo) < minSpan {
            hi = min(interval.end, lo.addingTimeInterval(minSpan))
            lo = max(interval.start, hi.addingTimeInterval(-minSpan))
        }
        return lo...hi
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

    private func donut(_ items: [RankItem], total: TimeInterval) -> some View {
        Chart(items) { item in
            SectorMark(angle: .value("Time", item.duration), innerRadius: .ratio(0.64), angularInset: 1)
                .cornerRadius(2)
                .foregroundStyle(item.tint)
        }
        .chartBackground { _ in
            VStack(spacing: 0) {
                Text(Format.duration(total)).font(.headline).monospacedDigit()
                Text("total").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct Metric: View {
    var title: String
    var value: String
    var detail: String
    var icon: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if let icon {
                    Image(nsImage: AppCatalog.shared.icon(for: icon)).resizable().frame(width: 18, height: 18)
                }
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(detail.isEmpty ? " " : detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Card<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

struct RankItem: Identifiable {
    var id: String { label }
    var label: String
    var duration: TimeInterval
    var icon: NodeKind
    var tint: Color = .accentColor
}

/// One line per item with its share drawn as a bar behind the row.
struct RankList: View {
    var items: [RankItem]
    var total: TimeInterval
    /// Bars show share of the total instead of length relative to the largest item.
    var relativeToTotal = false

    var body: some View {
        let scale = max(1, relativeToTotal ? total : items.first?.duration ?? 1)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items) { item in
                HStack(spacing: 6) {
                    if item.icon == NodeKind.none {
                        Image(systemName: "ellipsis.circle.fill").foregroundStyle(.tertiary).frame(width: 16)
                    } else {
                        NodeIcon(kind: item.icon)
                    }
                    Text(item.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.label)
                    Spacer(minLength: 8)
                    Text(Format.percent(item.duration, of: total))
                        .foregroundStyle(.tertiary)
                    Text(Format.duration(item.duration))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 46, alignment: .trailing)
                }
                .monospacedDigit()
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(alignment: .leading) {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(item.tint.opacity(0.15))
                            .frame(width: max(4, geo.size.width * CGFloat(item.duration / scale)))
                    }
                }
            }
        }
    }
}

/// Columns of at least `minColumnWidth`; each card goes into the currently shortest column so cards of different heights leave no gaps.
struct MasonryLayout: Layout {
    var minColumnWidth: CGFloat
    var spacing: CGFloat

    private func frames(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        let count = max(1, min(subviews.count, Int((width + spacing) / (minColumnWidth + spacing))))
        let columnWidth = (width - spacing * CGFloat(count - 1)) / CGFloat(count)
        var heights = Array(repeating: CGFloat(0), count: count)
        var frames: [CGRect] = []
        for subview in subviews {
            let column = heights.indices.min { heights[$0] < heights[$1] }!
            let height = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            frames.append(CGRect(x: CGFloat(column) * (columnWidth + spacing), y: heights[column], width: columnWidth, height: height))
            heights[column] += height + spacing
        }
        return (frames, max(0, (heights.max() ?? 0) - spacing))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? minColumnWidth
        return CGSize(width: width, height: frames(subviews, width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(subviews, width: bounds.width).frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
}
