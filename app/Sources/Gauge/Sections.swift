import SwiftUI
import Charts

// MARK: Vitals

/// Six channels side by side, like a mixing desk. Wraps to 3 or 2 columns when narrow.
struct VitalsSection: View {
    var vitals: [Vital]
    var width: CGFloat
    var bars: Bool
    var open: (String) -> Void

    private var columns: Int { width >= 1080 ? 6 : width >= 680 ? 3 : 2 }

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Vitals")
            let rows = stride(from: 0, to: vitals.count, by: columns).map { Array(vitals[$0..<min($0 + columns, vitals.count)]) }
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Hairline() }
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.element.id) { column, vital in
                        if column > 0 { Hairline(axis: .vertical) }
                        Channel(vital: vital, bars: bars, leading: column == 0, trailing: column == columns - 1) { open(vital.name) }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Hairline()
        }
    }
}

struct Channel: View {
    var vital: Vital
    var bars: Bool
    var leading: Bool
    var trailing: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(Theme.tone(vital.name)).frame(width: 7, height: 7)
                    Text(vital.name).font(.system(size: 13, weight: .semibold))
                    if let flag = vital.flag { FlagLabel(text: flag) }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hovering ? Theme.ink : Theme.faint)
                        .offset(x: hovering ? 2 : 0)
                }
                .frame(height: 18)
                Text(vital.caption).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1).padding(.top, 2)
                GeometryReader { geo in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(vital.value)
                            .font(Theme.mono(min(56, max(28, geo.size.width * 0.235)), .light))
                            .tracking(-1.5)
                            .monospacedDigit()
                            .contentTransition(.opacity)
                        Text(vital.unit).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .frame(height: 58)
                .padding(.top, 8)
                .padding(.bottom, 14)
                Ruler(fraction: vital.fraction, hot: vital.flag != nil, tint: Theme.tone(vital.name))
                    .animation(.smooth(duration: 0.45), value: vital.fraction)
                HStack {
                    Text(vital.scale.0)
                    Spacer()
                    Text(vital.scale.1)
                }
                .font(Theme.mono(10)).foregroundStyle(Theme.faint).padding(.top, 5)
                Trace(values: vital.trace, hot: vital.flag != nil, bars: bars, tint: Theme.tone(vital.name))
                    .frame(height: 38)
                    .padding(.vertical, 18)
                Readings(stats: vital.stats)
            }
            .padding(.top, 18)
            .padding(.bottom, 22)
            .padding(.leading, leading ? 0 : 20)
            .padding(.trailing, trailing ? 0 : 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeOut(duration: 0.25), value: vital.value)
            .background(alignment: .bottom) {
                // Hover marks the channel as clickable with a thin line in its colour.
                Rectangle().fill(Theme.tone(vital.name))
                    .frame(height: 2)
                    .scaleEffect(x: hovering ? 1 : 0, anchor: .leading)
                    .padding(.leading, leading ? 0 : 20)
                    .padding(.trailing, trailing ? 0 : 20)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.25), value: hovering)
        .accessibilityLabel("\(vital.name), \(vital.value) \(vital.unit)\(vital.flag.map { ", \($0)" } ?? "")")
        .accessibilityHint("Shows details")
    }
}

// MARK: Worth a look

struct NoticesSection: View {
    @Bindable var monitor: Monitor
    var width: CGFloat
    var open: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Worth a look", count: monitor.visibleNotices.count) {
                HStack(spacing: 14) {
                    Button("Show all \(monitor.notices.count)") { monitor.dismissed.removeAll() }
                    Button("Clear") { monitor.dismissed.formUnion(monitor.notices.map(\.id)) }
                        .disabled(monitor.visibleNotices.isEmpty)
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.soft)
            }
            if monitor.visibleNotices.isEmpty {
                HStack {
                    Text(monitor.notices.isEmpty ? "Nothing needs your attention." : "No notices. Cleared ones come back with Show all.")
                        .foregroundStyle(Theme.muted)
                    Spacer()
                }
                .font(.system(size: 13))
                .padding(.vertical, 22)
                Hairline()
            }
            ForEach(monitor.visibleNotices) { notice in
                HStack(alignment: .top, spacing: 20) {
                    LED(on: notice.hot).padding(.top, 5)
                    if width >= 640 {
                        Text(notice.tag).font(Theme.mono(12)).foregroundStyle(Theme.tone(notice.target)).frame(width: 84, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notice.title).font(.system(size: 14, weight: .medium))
                        Text(notice.body).font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    if width >= 900 {
                        Text("since \(Fmt.clock(notice.since))").font(Theme.mono(11)).foregroundStyle(Theme.faint).padding(.top, 2)
                    }
                    Button { open(notice.target) } label: {
                        HStack(spacing: 5) { Text("Inspect"); Image(systemName: "arrow.right").font(.system(size: 11)) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.soft)
                    .accessibilityLabel("Inspect \(notice.tag) notice")
                }
                .padding(.vertical, 16)
                Hairline()
            }
        }
    }
}

// MARK: Right now

struct BreakdownsSection: View {
    var breakdowns: [Breakdown]
    var width: CGFloat
    var showProcesses: () -> Void

    var body: some View {
        let columns = width >= 900 ? 2 : 1
        VStack(spacing: 0) {
            SectionHeader(title: "Right now") {
                Button("View processes", action: showProcesses).buttonStyle(QuietButtonStyle())
            }
            let rows = stride(from: 0, to: breakdowns.count, by: columns).map { Array(breakdowns[$0..<min($0 + columns, breakdowns.count)]) }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.element.id) { column, item in
                        if column > 0 { Hairline(axis: .vertical) }
                        BreakdownView(item: item, compact: width < 480)
                            .padding(.leading, column > 0 ? 32 : 0)
                            .padding(.trailing, column < columns - 1 ? 32 : 0)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Hairline()
            }
        }
    }
}

struct BreakdownView: View {
    var item: Breakdown
    var compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Circle().fill(Theme.tone(item.metric)).frame(width: 7, height: 7)
                Text(item.title).font(.system(size: 13, weight: .semibold))
                Text(item.subtitle).font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18)) : AnyLayout(HStackLayout(spacing: 32))
            layout {
                Donut(slices: item.slices, tint: Theme.tone(item.metric), center: item.center, caption: item.centerCaption)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    ForEach(Array(item.slices.enumerated()), id: \.element.id) { index, slice in
                        GridRow {
                            HStack(spacing: 9) {
                                Rectangle().fill(Donut(slices: item.slices, tint: Theme.tone(item.metric), center: "", caption: "").color(index)).frame(width: 8, height: 8)
                                Text(slice.name).lineLimit(1)
                            }
                            Text(slice.value).font(Theme.mono(12.5)).gridColumnAlignment(.trailing)
                            Text(Fmt.percent(slice.share * 100)).font(Theme.mono(12.5)).foregroundStyle(Theme.faint)
                                .gridColumnAlignment(.trailing)
                        }
                        .font(.system(size: 12.5))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Hardware

struct HardwareSection: View {
    var cards: [HardwareCard]
    var width: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Hardware")
            let layout = width >= 900 ? AnyLayout(HStackLayout(alignment: .top, spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                    if index > 0 { Hairline(axis: width >= 900 ? .vertical : .horizontal) }
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 8) {
                            Circle().fill(Theme.tone(card.tone)).frame(width: 7, height: 7)
                            Text(card.title).font(.system(size: 13, weight: .semibold))
                        }
                        Readings(stats: card.rows, size: 13)
                        if let note = card.note {
                            Text(note).font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 22)
                    .padding(.leading, width >= 900 && index > 0 ? 28 : 0)
                    .padding(.trailing, width >= 900 && index < cards.count - 1 ? 28 : 0)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Hairline()
        }
    }
}

// MARK: Over time

struct HistorySection: View {
    @Bindable var monitor: Monitor
    var width: CGFloat
    var bars: Bool
    @State private var selection: Date?

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Over time") {
                HStack(spacing: 8) {
                    Segmented(options: HistoryMetric.allCases.map { ($0, $0.rawValue, nil) },
                              selection: $monitor.historyMetric, accessibilityName: "History metric")
                    Segmented(options: HistoryPeriod.allCases.map { ($0, $0.short, nil) },
                              selection: $monitor.period, accessibilityName: "History period")
                }
            }
            let layout = width >= 900 ? AnyLayout(HStackLayout(alignment: .top, spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                chartPanel
                    .padding(.trailing, width >= 900 ? 32 : 0)
                    .frame(maxWidth: .infinity)
                    .layoutPriority(2)
                Hairline(axis: width >= 900 ? .vertical : .horizontal)
                topAppsPanel
                    .padding(.leading, width >= 900 ? 32 : 0)
                    .frame(width: width >= 900 ? max(280, width / 3) : nil)
            }
            .fixedSize(horizontal: false, vertical: true)
            Hairline()
        }
    }

    private var tint: Color { Theme.tone(monitor.historyMetric.rawValue) }

    private struct Point: Identifiable { var id: Date { date }; var date: Date; var value: Double }

    private var metric: (title: String, unit: String, max: Double, points: [Point], format: (Double) -> String, headline: String) {
        let h = monitor.history
        switch monitor.historyMetric {
        case .cpu:
            let avg = h.map(\.cpu).reduce(0, +) / Double(max(h.count, 1))
            return ("Average CPU load", "%", 100, h.map { Point(date: $0.date, value: $0.cpu) },
                    { String(format: "%.0f%%", $0) }, String(format: "%.0f", avg))
        case .memory:
            let total = max(h.map(\.memoryTotal).max() ?? 0, 1)
            let gb = 1_073_741_824.0
            let current = (h.last?.memoryUsed ?? 0) / gb
            return ("Memory used", "GB", total / gb, h.map { Point(date: $0.date, value: $0.memoryUsed / gb) },
                    { String(format: "%.1f GB", $0) }, String(format: "%.2f", current))
        case .network:
            let avg = h.map(\.download).reduce(0, +) / Double(max(h.count, 1))
            let (value, unit) = Fmt.rate(avg)
            let peak = h.map(\.download).max() ?? 0
            return ("Average download rate", unit, Fmt.rateScale(peak) / 1000, h.map { Point(date: $0.date, value: $0.download / 1000) },
                    { Fmt.rateText($0 * 1000) }, value)
        }
    }

    private var caption: String {
        if let oldest = monitor.oldestSample, Date().timeIntervalSince(oldest) < Double(monitor.period.rawValue) {
            return "Since \(Fmt.clock(oldest)) · stored on this Mac"
        }
        return "\(monitor.period.label) · stored on this Mac"
    }

    private var chartPanel: some View {
        let m = metric
        return VStack(alignment: .leading, spacing: 0) {
            Text(m.title).font(.system(size: 13)).foregroundStyle(Theme.muted)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(m.headline).font(Theme.mono(44, .light)).tracking(-1.5)
                Text(m.unit).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            .padding(.top, 10)
            Text(caption).font(Theme.mono(11)).foregroundStyle(Theme.muted).padding(.top, 6)
            if m.points.count < 2 {
                Text("Collecting history. Readings are saved every 10 seconds and stay on this Mac.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
            } else {
                chart(m)
                    .frame(height: 220)
                    .padding(.top, 26)
            }
        }
        .padding(.vertical, 22)
    }

    private func chart(_ m: (title: String, unit: String, max: Double, points: [Point], format: (Double) -> String, headline: String)) -> some View {
        let nearest = selection.flatMap { s in m.points.min { abs($0.date.timeIntervalSince(s)) < abs($1.date.timeIntervalSince(s)) } }
        return Chart {
            ForEach(m.points) { p in
                if bars {
                    BarMark(x: .value("Time", p.date), y: .value(m.unit, p.value), width: .fixed(2))
                        .foregroundStyle(tint.opacity(0.75))
                } else {
                    AreaMark(x: .value("Time", p.date), y: .value(m.unit, p.value))
                        .foregroundStyle(tint.opacity(0.1))
                    LineMark(x: .value("Time", p.date), y: .value(m.unit, p.value))
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 1.25, lineJoin: .round))
                }
            }
            if let nearest {
                RuleMark(x: .value("Time", nearest.date))
                    .foregroundStyle(Theme.muted)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 6, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        HStack(spacing: 8) {
                            Text(Fmt.clock(nearest.date)).foregroundStyle(Theme.muted)
                            Text(m.format(nearest.value))
                        }
                        .font(Theme.mono(11.5))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.raise2))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line2))
                    }
                PointMark(x: .value("Time", nearest.date), y: .value(m.unit, nearest.value))
                    .symbol(.square).symbolSize(36).foregroundStyle(tint)
            }
        }
        .chartXSelection(value: $selection)
        .chartYScale(domain: 0...max(m.max, 0.001))
        .chartYAxis {
            AxisMarks(position: .trailing, values: [m.max * 0.25, m.max * 0.5, m.max * 0.75]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Theme.line)
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(m.format(v)).font(Theme.mono(10)).foregroundStyle(Theme.faint) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisValueLabel(format: monitor.period == .week ? .dateTime.weekday(.abbreviated) : .dateTime.hour().minute())
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
            }
        }
    }

    private var topAppsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Top apps by CPU time").font(.system(size: 13)).foregroundStyle(Theme.muted)
            if monitor.topApps.isEmpty {
                Text("Builds up as Gauge runs.").font(.system(size: 13)).foregroundStyle(Theme.faint).padding(.top, 14)
            }
            let top = monitor.topApps.first?.1 ?? 1
            VStack(spacing: 0) {
                ForEach(monitor.topApps, id: \.0) { app in
                    HStack(spacing: 14) {
                        Text(app.0).font(.system(size: 13)).lineLimit(1)
                        Spacer(minLength: 8)
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Theme.line2)
                            Rectangle().fill(Theme.tone("CPU")).frame(width: 64 * app.1 / max(top, 0.001))
                        }
                        .frame(width: 64, height: 2)
                        Text(Fmt.cpuTime(app.1)).font(Theme.mono(12)).foregroundStyle(Theme.soft).frame(width: 64, alignment: .trailing)
                    }
                    .padding(.vertical, 7)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 14)
        }
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
