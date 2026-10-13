import SwiftUI
import UniformTypeIdentifiers

struct ExportSheet: View {
    enum Span: String, CaseIterable, Identifiable {
        case day = "Day", week = "Week", month = "Month", custom = "Custom"
        var id: String { rawValue }
    }

    enum Content: String, CaseIterable, Identifiable {
        case activities = "Activities"
        case timesheet = "Timesheet"
        var id: String { rawValue }
    }

    enum FileFormat: String, CaseIterable, Identifiable {
        case csv = "CSV", json = "JSON"
        var id: String { rawValue }
        var type: UTType { self == .csv ? .commaSeparatedText : .json }
    }

    var day: Date
    @Environment(\.dismiss) private var dismiss
    @State private var span: Span = .week
    @State private var from = Date()
    @State private var to = Date()
    @AppStorage("exportContent") private var content: Content = .timesheet
    @AppStorage("exportFormat") private var format: FileFormat = .csv

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export").font(.headline)
            Form {
                Picker("Range", selection: $span) {
                    ForEach(Span.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if span == .custom {
                    DatePicker("From", selection: $from, displayedComponents: .date)
                    DatePicker("To", selection: $to, in: from..., displayedComponents: .date)
                } else {
                    LabeledContent("Dates", value: rangeTitle)
                }
                Picker("Export", selection: $content) {
                    ForEach(Content.allCases) { Text($0.rawValue).tag($0) }
                }
                Text(content == .activities
                     ? "Every recorded activity, with its app, title, address or path, and project."
                     : Projects.shared.list.isEmpty ? "Time per day and app." : "Time per day and project.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Format", selection: $format) {
                    ForEach(FileFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…", action: export).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { from = day; to = day }
    }

    private var interval: DateInterval {
        let cal = Calendar.current
        switch span {
        case .day: return cal.dateInterval(of: .day, for: day)!
        case .week: return cal.dateInterval(of: .weekOfYear, for: day)!
        case .month: return cal.dateInterval(of: .month, for: day)!
        case .custom: return DateInterval(start: cal.startOfDay(for: from), end: cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: max(from, to)))!)
        }
    }

    private var rangeTitle: String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        let i = interval
        return span == .day ? f.string(from: i.start) : "\(f.string(from: i.start)) – \(f.string(from: i.end.addingTimeInterval(-1)))"
    }

    private func export() {
        let i = interval
        let name = "Autotime \(content.rawValue) \(Exporter.day.string(from: i.start))"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = name + "." + (format == .csv ? "csv" : "json")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let activities = Store.shared.activities(in: i.start...i.end)
        let data = content == .activities ? Exporter.activities(activities, format: format) : Exporter.timesheet(activities, format: format)
        try? data.write(to: url, options: .atomic)
        dismiss()
    }
}

@MainActor
enum Exporter {
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let timestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return f
    }()

    static func activities(_ list: [Activity], format: ExportSheet.FileFormat) -> Data {
        let rows: [[String: Any]] = list.map { a in
            [
                "start": timestamp.string(from: a.start), "end": timestamp.string(from: a.end), "seconds": Int(a.duration.rounded()),
                "app": a.appName, "bundle_id": a.bundleID, "title": a.title, "path": a.path,
                "project": Projects.shared.project(for: a)?.name ?? "",
            ]
        }
        return encode(rows, columns: ["start", "end", "seconds", "app", "bundle_id", "title", "path", "project"], format: format)
    }

    /// Time per day and project, or per day and app when there are no projects.
    static func timesheet(_ list: [Activity], format: ExportSheet.FileFormat) -> Data {
        let byProject = !Projects.shared.list.isEmpty
        let column = byProject ? "project" : "app"
        var totals: [String: [String: TimeInterval]] = [:]
        for a in list {
            let key = byProject ? Projects.shared.project(for: a)?.name ?? "No Project" : a.appName
            totals[day.string(from: a.start), default: [:]][key, default: 0] += a.duration
        }
        var rows: [[String: Any]] = []
        for date in totals.keys.sorted() {
            for (key, seconds) in totals[date]!.sorted(by: { $0.value > $1.value }) where seconds >= 1 {
                rows.append(["date": date, column: key, "hours": (seconds / 36).rounded() / 100, "duration": Format.duration(seconds)])
            }
        }
        return encode(rows, columns: ["date", column, "hours", "duration"], format: format)
    }

    private static func encode(_ rows: [[String: Any]], columns: [String], format: ExportSheet.FileFormat) -> Data {
        if format == .json {
            return (try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        }
        func field(_ v: Any?) -> String {
            let s = v.map { "\($0)" } ?? ""
            return s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        var lines = [columns.joined(separator: ",")]
        for row in rows { lines.append(columns.map { field(row[$0]) }.joined(separator: ",")) }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }
}
