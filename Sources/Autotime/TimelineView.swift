import SwiftUI
import Combine

struct TimelineView: View {
    @Environment(DayModel.self) private var model
    @State private var dragStart: Date?
    @State private var now = Date()
    @State private var hoverBlock: String?
    @State private var scrolledDay: Date?
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private let stripX: CGFloat = 10
    private let stripWidth: CGFloat = 26
    private let blocksX: CGFloat = 46
    private let labelWidth: CGFloat = 30

    var body: some View {
        let activities = model.searched
        let (appSessions, blocks) = model.timeline

        VStack(spacing: 0) {
            HStack {
                Text("Timeline")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { zoom(1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom Out")
                Button { zoom(1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom In")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()

            GeometryReader { geo in
                let width = geo.size.width
                let blocksWidth = max(40, width - blocksX - labelWidth - 6)
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        ZStack(alignment: .topLeading) {
                            hourGrid(width: width)
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { model.selection = nil }
                            strip(appSessions)
                                .frame(width: stripWidth, height: model.hourHeight * 24)
                                .offset(x: stripX)
                                .allowsHitTesting(false)
                            ForEach(blocks) { block in
                                blockView(block, width: blocksWidth)
                            }
                            selectionOverlay(width: width)
                            if model.isToday {
                                nowLine(width: width)
                            }
                        }
                        .frame(width: width, height: model.hourHeight * 24, alignment: .topLeading)
                        .gesture(dragGesture)
                    }
                    .onAppear { scrollToStart(proxy, activities) }
                    .onChange(of: model.date) { scrollToStart(proxy, model.searched) }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        .onReceive(clock) { now = $0 }
    }

    private func y(_ date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(model.date) / 3600) * model.hourHeight
    }

    private func date(atY y: CGFloat) -> Date {
        let hours = Double(max(0, min(model.hourHeight * 24, y)) / model.hourHeight)
        return model.date.addingTimeInterval(hours * 3600)
    }

    private func zoom(_ factor: CGFloat) {
        withAnimation(.easeOut(duration: 0.2)) {
            model.hourHeight = min(600, max(60, model.hourHeight * factor))
        }
    }

    private func scrollToStart(_ proxy: ScrollViewProxy, _ activities: [Activity]) {
        guard scrolledDay != model.date else { return }
        scrolledDay = model.date
        let hour: Int
        if model.isToday {
            hour = max(0, Calendar.current.component(.hour, from: Date()) - 2)
        } else if let first = activities.first {
            hour = Calendar.current.component(.hour, from: first.start)
        } else {
            hour = 8
        }
        DispatchQueue.main.async { proxy.scrollTo(hour, anchor: .top) }
    }

    private func hourGrid(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { h in
                ZStack(alignment: .topTrailing) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity, alignment: .top)
                    Text("\(h)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 8)
                        .padding(.top, 3)
                }
                .frame(height: model.hourHeight, alignment: .top)
                .id(h)
            }
        }
        .frame(width: width)
    }

    private func strip(_ sessions: [Session]) -> some View {
        let hourHeight = model.hourHeight
        let day = model.date
        return Canvas { context, size in
            for s in sessions {
                let top = CGFloat(s.start.timeIntervalSince(day) / 3600) * hourHeight
                let height = max(1.5, CGFloat(s.duration / 3600) * hourHeight)
                let rect = CGRect(x: 0, y: top, width: size.width, height: height)
                context.fill(Path(rect), with: .color(AppCatalog.shared.color(for: s.bundleID).opacity(0.9)))
                if height >= 18 {
                    let icon = context.resolve(Image(nsImage: AppCatalog.shared.icon(for: s.bundleID)))
                    let side: CGFloat = 16
                    context.draw(icon, in: CGRect(x: (size.width - side) / 2, y: top + min(3, (height - side) / 2), width: side, height: side))
                }
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: TimelineBlock, width: CGFloat) -> some View {
        let top = y(block.start)
        let height = max(4, y(block.end) - top)
        let color = AppCatalog.shared.color(for: block.bundleID)
        let selected = model.selection.map { $0.lowerBound <= block.start && $0.upperBound >= block.end } ?? false
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(color.opacity(selected ? 0.35 : (hoverBlock == block.id ? 0.24 : (height < 12 ? 0.3 : 0.14))))
            if height >= 12 {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(color.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            if height >= 16 {
                HStack(spacing: 5) {
                    Image(nsImage: AppCatalog.shared.icon(for: block.bundleID))
                        .resizable()
                        .frame(width: 13, height: 13)
                    Text(block.label)
                        .font(.caption)
                        .lineLimit(height >= 34 ? 2 : 1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.top, 3)
            }
        }
        .frame(width: width, height: height)
        .offset(x: blocksX, y: top)
        .onHover { hoverBlock = $0 ? block.id : (hoverBlock == block.id ? nil : hoverBlock) }
        .onTapGesture { model.selection = block.start...block.end }
        .help(tooltip(block))
    }

    private func tooltip(_ block: TimelineBlock) -> String {
        var lines = ["\(Format.time.string(from: block.start)) – \(Format.time.string(from: block.end))"]
        lines += block.breakdown.prefix(6).map { "\($0.0): \(Format.duration($0.1, seconds: true))" }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func selectionOverlay(width: CGFloat) -> some View {
        if let sel = model.selection {
            let top = y(sel.lowerBound)
            let height = max(2, y(sel.upperBound) - top)
            Rectangle()
                .fill(Color.accentColor.opacity(0.12))
                .overlay(alignment: .top) { Rectangle().fill(Color.accentColor).frame(height: 1.5) }
                .overlay(alignment: .bottom) { Rectangle().fill(Color.accentColor).frame(height: 1.5) }
                .frame(width: width - labelWidth, height: height)
                .offset(y: top)
                .allowsHitTesting(false)
        }
    }

    private func nowLine(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Circle().fill(.red).frame(width: 7, height: 7)
            Rectangle().fill(.red).frame(height: 1.5)
        }
        .frame(width: width - labelWidth + 4)
        .offset(x: 4, y: y(now) - 3.5)
        .allowsHitTesting(false)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let start = date(atY: value.startLocation.y)
                let current = date(atY: value.location.y)
                dragStart = start
                model.selection = min(start, current)...max(start, current)
            }
            .onEnded { _ in dragStart = nil }
    }
}
