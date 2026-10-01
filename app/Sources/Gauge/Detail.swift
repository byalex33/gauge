import SwiftUI
import Charts

enum DetailRange: Int, CaseIterable, Identifiable {
    case live = 0, hour = 3600, sixHours = 21_600, day = 86_400, week = 604_800
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .live: "Live"
        case .hour: "1h"
        case .sixHours: "6h"
        case .day: "24h"
        case .week: "7d"
        }
    }
}

/// One point in time with a value per series.
struct ChartSample: Identifiable {
    var id: Date { date }
    var date: Date
    var values: [Double]
}

/// How a metric's detail chart is drawn and formatted.
struct MetricSpec {
    enum Kind { case percent, memory, rate }

    var series: [(name: String, dashed: Bool)]
    var kind: Kind
    var live: (RecentSample) -> [Double]?
    var stored: (HistoryPoint) -> [Double]?

    func format(_ value: Double) -> String {
        switch kind {
        case .percent: Fmt.percent(value)
        case .memory: Fmt.memoryText(value)
        case .rate: Fmt.rateText(value)
        }
    }

    static func of(_ metric: String) -> MetricSpec {
        switch metric {
        case "Memory": MetricSpec(series: [("Used", false)], kind: .memory, live: { [$0.memory] }, stored: { [$0.memoryUsed] })
        case "GPU": MetricSpec(series: [("GPU", false)], kind: .percent, live: { [$0.gpu] }, stored: { [$0.gpu] })
        case "Disk": MetricSpec(series: [("Read", false), ("Write", true)], kind: .rate,
                                live: { [$0.diskRead, $0.diskWrite] }, stored: { [$0.diskRead, $0.diskWrite] })
        case "Network": MetricSpec(series: [("Download", false), ("Upload", true)], kind: .rate,
                                   live: { [$0.down, $0.up] }, stored: { [$0.download, $0.upload] })
        case "Battery": MetricSpec(series: [("Charge", false)], kind: .percent,
                                   live: { $0.battery.map { [$0] } }, stored: { $0.battery.map { [$0] } })
        default: MetricSpec(series: [("CPU", false)], kind: .percent, live: { [$0.cpu] }, stored: { [$0.cpu] })
        }
    }
}

/// Full page for one metric: live readout, a large interactive chart, and its readings.
struct DetailPage: View {
    var name: String
    var monitor: Monitor
    var width: CGFloat
    var back: () -> Void
    /// Snapshot aid: shows the hover readout at this fraction of the chart without a pointer.
    var previewHover: Double? = nil

    @State private var range: DetailRange = .live
    @State private var stored: [HistoryPoint] = []
    @State private var selection: Date?

    private var spec: MetricSpec { MetricSpec.of(name) }
    private var tone: Color { Theme.tone(name) }
    private var vital: Vital? { monitor.vitals.first { $0.name == name } }

    private var samples: [ChartSample] {
        if range == .live {
            return monitor.recent.compactMap { s in spec.live(s).map { ChartSample(date: s.date, values: $0) } }
        }
        return stored.compactMap { p in spec.stored(p).map { ChartSample(date: p.date, values: $0) } }
    }

    private var yMax: Double {
        switch spec.kind {
        case .percent: return 100
        case .memory: return max(monitor.latest?.memory.total ?? 1, 1)
        case .rate:
            let peak = samples.flatMap(\.values).max() ?? 0
            return Self.niceCeiling(max(peak * 1.15, 10_000))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let vital {
                summary(vital)
                chartBlock
                details(vital)
            }
        }
        .task(id: range) {
            guard range != .live else { return }
            while !Task.isCancelled {
                monitor.store.series(since: Date().addingTimeInterval(-Double(range.rawValue)), points: 360) { points in
                    stored = points
                }
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    // MARK: Header and summary

    private var header: some View {
        HStack(alignment: .center) {
            Button(action: back) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("Overview")
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.soft)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to Overview (Esc)")
            Spacer()
            Segmented(options: DetailRange.allCases.map { ($0, $0.label, nil) }, selection: $range, accessibilityName: "Chart range")
        }
        .padding(.top, 24)
    }

    private func summary(_ vital: Vital) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(tone).frame(width: 9, height: 9)
                Text(vital.name).font(.system(size: 30, weight: .semibold)).tracking(-0.75)
                if let flag = vital.flag { FlagLabel(text: flag).padding(.leading, 4) }
            }
            .padding(.top, 22)
            Text(vital.caption).font(.system(size: 13)).foregroundStyle(Theme.muted).padding(.top, 4)

            let stats = rangeStats
            let layout = width >= 760 ? AnyLayout(HStackLayout(alignment: .bottom, spacing: 48)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
            layout {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(vital.value)
                        .font(Theme.mono(64, .light)).tracking(-2.5)
                        .contentTransition(.opacity)
                        .animation(.easeOut(duration: 0.25), value: vital.value)
                    Text(vital.unit).font(.system(size: 14)).foregroundStyle(Theme.muted)
                }
                HStack(spacing: 36) {
                    ForEach(stats, id: \.label) { stat in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(stat.label).font(.system(size: 12)).foregroundStyle(Theme.muted)
                            Text(stat.value).font(Theme.mono(15))
                                .contentTransition(.opacity)
                                .animation(.easeOut(duration: 0.25), value: stat.value)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .padding(.top, 18)
        }
    }

    /// Average, low and peak of the primary series over the chosen range.
    private var rangeStats: [Stat] {
        let values = samples.map { $0.values.first ?? 0 }
        guard !values.isEmpty else { return [] }
        let avgLabel = spec.series.count > 1 ? "\(spec.series[0].name) average" : "Average"
        let avg = values.reduce(0, +) / Double(values.count)
        return [Stat(label: avgLabel, value: spec.format(avg)),
                Stat(label: "Low", value: spec.format(values.min() ?? 0)),
                Stat(label: "Peak", value: spec.format(values.max() ?? 0))]
    }

    // MARK: Chart

    private var chartBlock: some View {
        let data = samples
        let hovered = selection.flatMap { s in data.min { abs($0.date.timeIntervalSince(s)) < abs($1.date.timeIntervalSince(s)) } }
            ?? previewHover.flatMap { f in data.isEmpty ? nil : data[min(data.count - 1, Int(Double(data.count - 1) * f))] }
        let max = yMax
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 18) {
                ForEach(Array(spec.series.enumerated()), id: \.offset) { index, series in
                    HStack(spacing: 7) {
                        SeriesSwatch(color: tone, dashed: series.dashed)
                        Text(series.name).font(.system(size: 12)).foregroundStyle(Theme.soft)
                    }
                }
                Spacer()
                Text(caption(for: data)).font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }
            if data.count < 2 {
                Text(range == .live ? "Collecting readings…" : "No saved history for this range yet. Gauge saves readings every 10 seconds while it runs.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: 340)
            } else {
                Chart {
                    ForEach(Array(spec.series.enumerated()), id: \.offset) { index, series in
                        ForEach(data) { sample in
                            if index == 0 {
                                AreaMark(x: .value("Time", sample.date), y: .value(series.name, sample.values[index]),
                                         series: .value("Series", series.name))
                                    .foregroundStyle(tone.opacity(0.13))
                                    .interpolationMethod(.monotone)
                            }
                            LineMark(x: .value("Time", sample.date), y: .value(series.name, sample.values[index]),
                                     series: .value("Series", series.name))
                                .foregroundStyle(index == 0 ? tone : tone.opacity(0.8))
                                .lineStyle(StrokeStyle(lineWidth: index == 0 ? 1.8 : 1.4, lineCap: .round, lineJoin: .round,
                                                       dash: series.dashed ? [4, 3] : []))
                                .interpolationMethod(.monotone)
                        }
                    }
                    if let hovered {
                        RuleMark(x: .value("Time", hovered.date))
                            .foregroundStyle(Theme.muted.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .annotation(position: .top, spacing: 8, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                tooltip(hovered)
                            }
                        ForEach(Array(spec.series.enumerated()), id: \.offset) { index, series in
                            PointMark(x: .value("Time", hovered.date), y: .value(series.name, hovered.values[index]))
                                .symbolSize(48)
                                .foregroundStyle(tone)
                        }
                    }
                }
                .chartXSelection(value: $selection)
                .chartYScale(domain: 0...max)
                .chartLegend(.hidden)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: [max * 0.25, max * 0.5, max * 0.75, max]) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Theme.line)
                        AxisValueLabel {
                            if let v = value.as(Double.self) { Text(spec.format(v)).font(Theme.mono(10)).foregroundStyle(Theme.faint) }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 4])).foregroundStyle(Theme.line)
                        AxisValueLabel(format: range == .week ? .dateTime.weekday(.abbreviated).hour()
                                        : range == .live ? .dateTime.hour().minute().second() : .dateTime.hour().minute())
                            .font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
                    }
                }
                .frame(height: 340)
                .padding(.top, 34)
                .accessibilityLabel("\(name) chart, \(range.label)")
            }
        }
        .padding(.top, 34)
        .padding(.bottom, 26)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func tooltip(_ sample: ChartSample) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(sample.date.formatted(date: range == .week ? .abbreviated : .omitted, time: .standard))
                .foregroundStyle(Theme.muted)
            ForEach(Array(spec.series.enumerated()), id: \.offset) { index, series in
                HStack(spacing: 7) {
                    SeriesSwatch(color: tone, dashed: series.dashed).frame(width: 12)
                    Text(series.name).foregroundStyle(Theme.soft)
                    Spacer(minLength: 12)
                    Text(spec.format(sample.values[index]))
                }
            }
        }
        .font(Theme.mono(11.5))
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(minWidth: 170)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.raise2))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line2))
    }

    private func caption(for data: [ChartSample]) -> String {
        if range == .live { return "Last \(max(1, Int((data.last?.date.timeIntervalSince(data.first?.date ?? Date()) ?? 0) / 60))) min · every 2 s" }
        if let first = data.first?.date, Date().timeIntervalSince(first) < Double(range.rawValue) * 0.9 {
            return "Since \(Fmt.clock(first)) · stored on this Mac"
        }
        return "\(range.label) · stored on this Mac"
    }

    // MARK: Details

    private func details(_ vital: Vital) -> some View {
        let apps = topApps
        let layout = width >= 900 && apps != nil ? AnyLayout(HStackLayout(alignment: .top, spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        return layout {
            VStack(alignment: .leading, spacing: 14) {
                Text("Readings").font(.system(size: 13, weight: .semibold))
                Readings(stats: readings(vital), size: 13)
            }
            .frame(maxWidth: apps == nil ? 520 : .infinity, alignment: .topLeading)
            .padding(.vertical, 22)
            .padding(.trailing, width >= 900 && apps != nil ? 32 : 0)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            if let apps {
                Hairline(axis: width >= 900 ? .vertical : .horizontal)
                VStack(alignment: .leading, spacing: 14) {
                    Text(name == "CPU" ? "Top apps by CPU" : "Top apps by memory").font(.system(size: 13, weight: .semibold))
                    let top = apps.first?.1 ?? 1
                    VStack(spacing: 0) {
                        ForEach(apps, id: \.0) { app in
                            HStack(spacing: 14) {
                                Text(app.0).font(.system(size: 13)).lineLimit(1)
                                Spacer(minLength: 8)
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(Theme.line2)
                                    Rectangle().fill(tone).frame(width: 90 * app.1 / max(top, 0.001))
                                }
                                .frame(width: 90, height: 3)
                                Text(name == "CPU" ? String(format: "%.1f%%", app.1) : Fmt.memoryText(app.1))
                                    .font(Theme.mono(12)).foregroundStyle(Theme.soft).frame(width: 72, alignment: .trailing)
                            }
                            .padding(.vertical, 6)
                            .animation(.easeOut(duration: 0.3), value: app.1)
                        }
                    }
                }
                .padding(.vertical, 22)
                .padding(.leading, width >= 900 ? 32 : 0)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private var topApps: [(String, Double)]? {
        switch name {
        case "CPU": return monitor.apps.sorted { $0.cpu > $1.cpu }.prefix(8).map { ($0.name, $0.cpu) }
        case "Memory": return monitor.apps.sorted { $0.memory > $1.memory }.prefix(8).map { ($0.name, $0.memory) }
        default: return nil
        }
    }

    private func readings(_ vital: Vital) -> [Stat] {
        guard let r = monitor.latest else { return vital.stats }
        switch name {
        case "CPU":
            return vital.stats + [Stat(label: "Cores", value: "\(monitor.sampler.cores)"),
                                  Stat(label: "Processes", value: "\(monitor.processCount)")]
        case "Memory":
            let m = r.memory
            let pressure = m.pressure >= 4 ? "Critical" : m.pressure >= 2 ? "Elevated" : "Normal"
            return [Stat(label: "Pressure", value: pressure),
                    Stat(label: "App", value: Fmt.memoryText(m.app)), Stat(label: "Wired", value: Fmt.memoryText(m.wired)),
                    Stat(label: "Compressed", value: Fmt.memoryText(m.compressed)), Stat(label: "Cached files", value: Fmt.memoryText(m.cached)),
                    Stat(label: "Free", value: Fmt.memoryText(m.free)), Stat(label: "Swap used", value: Fmt.memoryText(m.swapUsed))]
        case "Disk":
            let d = r.disk
            return [Stat(label: "Volume", value: d.name), Stat(label: "Capacity", value: Fmt.storageText(d.total)),
                    Stat(label: "Available", value: Fmt.storageText(d.available))] + vital.stats
        case "Network":
            return [Stat(label: "Downloading", value: Fmt.rateText(r.network.downRate))] + vital.stats
        case "Battery":
            guard let b = r.battery else { return vital.stats }
            return [Stat(label: "State", value: vital.caption)] + vital.stats + [Stat(label: "Cycle count", value: b.cycles.map(String.init) ?? "–")]
        default:
            return vital.stats
        }
    }

    static func niceCeiling(_ value: Double) -> Double {
        let exponent = pow(10, floor(log10(value)))
        for step in [1.0, 2, 2.5, 5, 10] where step * exponent >= value { return step * exponent }
        return 10 * exponent
    }
}

/// Legend swatch: a short solid or dashed line.
struct SeriesSwatch: View {
    var color: Color
    var dashed: Bool
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            p.move(to: CGPoint(x: 0, y: size.height / 2))
            p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dashed ? [3, 2.5] : []))
        }
        .frame(width: 16, height: 8)
    }
}

/// Projects page: local dev servers.
struct ProjectsPage: View {
    var monitor: Monitor
    var back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: back) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("Overview")
                }
                .font(.system(size: 13)).foregroundStyle(Theme.soft).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 24)
            HStack(spacing: 10) {
                Circle().fill(Theme.tone("Projects")).frame(width: 9, height: 9)
                Text("Projects").font(.system(size: 30, weight: .semibold)).tracking(-0.75)
            }
            .padding(.top, 22)
            Text("Local dev servers listening on TCP ports").font(.system(size: 13)).foregroundStyle(Theme.muted).padding(.top, 4)
            Hairline().padding(.top, 26)
            ProjectsView(servers: monitor.servers).padding(.top, 18)
        }
    }
}
