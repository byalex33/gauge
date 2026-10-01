import SwiftUI

/// A 0–100 tick scale with a filled bar up to the reading. The ticks are drawn once; the fill is a
/// plain shape so width changes animate on the GPU instead of redrawing a canvas every frame.
struct Ruler: View {
    var fraction: Double
    var hot = false
    var tint: Color = Theme.ink

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                let w = size.width
                ctx.fill(Path(CGRect(x: 0, y: 2, width: w, height: 3)), with: .color(Theme.line2))
                for i in 0...20 {
                    let x = (w - 1) * Double(i) / 20 + 0.5
                    let bottom: Double = i % 10 == 0 ? 14 : i % 5 == 0 ? 12.5 : 11
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: 8))
                    tick.addLine(to: CGPoint(x: x, y: bottom))
                    ctx.stroke(tick, with: .color(Theme.faint), lineWidth: 1)
                }
            }
            Rectangle()
                .fill(hot ? Theme.signal : tint)
                .frame(height: 3)
                .scaleEffect(x: min(1, max(0, fraction)), anchor: .leading)
                .padding(.top, 2)
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }
}

/// A thin line (or bar) trace of normalised values.
struct Trace: View {
    var values: [Double]
    var hot = false
    var bars = false
    var tint: Color = Theme.ink

    var body: some View {
        Canvas { ctx, size in
            let color = hot ? Theme.signal : tint
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            ctx.stroke(baseline, with: .color(Theme.line), lineWidth: 1)
            guard values.count > 1 else { return }
            let step = size.width / Double(values.count - 1)
            func y(_ v: Double) -> Double { size.height - v * size.height }
            if bars {
                let barWidth = size.width / Double(values.count) * 0.64
                for (i, v) in values.enumerated() {
                    let x = size.width / Double(values.count) * (Double(i) + 0.18)
                    ctx.fill(Path(CGRect(x: x, y: y(v), width: barWidth, height: v * size.height)), with: .color(color.opacity(0.7)))
                }
                return
            }
            var line = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: Double(i) * step, y: y(v))
                i == 0 ? line.move(to: p) : line.addLine(to: p)
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .color(color.opacity(0.08)))
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.25, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// Flat ring chart: tonal steps of the metric colour by rank, orange only for a slice that needs attention.
struct Donut: View {
    var slices: [Slice]
    var tint: Color = Theme.ink
    var center: String
    var caption: String
    var size: CGFloat = 132

    var body: some View {
        ZStack {
            Circle().stroke(Theme.raise2, lineWidth: 14)
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                Circle()
                    .trim(from: segment.start, to: segment.end)
                    .stroke(color(index), style: StrokeStyle(lineWidth: 14, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 3) {
                Text(center).font(Theme.mono(20, .light)).tracking(-0.6)
                Text(caption).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
        }
        .padding(7)
        .frame(width: size, height: size)
    }

    private var segments: [(start: Double, end: Double)] {
        var start = 0.0
        return slices.map { slice in
            let share = max(0, slice.share)
            defer { start += share }
            let gap = share > 0.012 ? 0.004 : 0
            return (start + gap, max(start + gap, start + share - gap))
        }
    }

    func color(_ index: Int) -> Color {
        slices[index].hot ? Theme.signal : tint.opacity(Theme.rampOpacity[min(index, Theme.rampOpacity.count - 1)])
    }
}

struct SectionHeader<Trailing: View>: View {
    var title: String
    var count: Int?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    if let count { Text("\(count)").font(Theme.mono(12)).foregroundStyle(Theme.muted) }
                }
                .accessibilityAddTraits(.isHeader)
                Spacer()
                trailing
            }
            Hairline()
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, count: Int? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

struct FlagLabel: View {
    var text: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.signal).frame(width: 6, height: 6)
            Text(text.uppercased()).font(Theme.mono(10.5)).tracking(0.6).foregroundStyle(Theme.signal)
        }
    }
}

/// Label/value rows with monospaced values.
struct Readings: View {
    var stats: [Stat]
    var size: CGFloat = 12

    var body: some View {
        VStack(spacing: 6) {
            ForEach(stats, id: \.self) { stat in
                HStack {
                    Text(stat.label).foregroundStyle(Theme.muted)
                    Spacer(minLength: 8)
                    Text(stat.value).font(Theme.mono(size)).lineLimit(1)
                }
                .font(.system(size: size))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Plain bordered button matching the instrument style.
struct QuietButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: primary ? .medium : .regular))
            .foregroundStyle(primary ? Theme.bg : Theme.ink)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(primary ? Theme.ink : (configuration.isPressed ? Theme.raise2 : .clear)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(primary ? Theme.ink : Theme.line2))
            .contentShape(Rectangle())
    }
}

/// Compact segmented control in the instrument style (hairline frame, raised selection).
struct Segmented<Value: Hashable>: View {
    var options: [(value: Value, label: String, symbol: String?)]
    @Binding var selection: Value
    var accessibilityName: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Group {
                        if let symbol = option.symbol {
                            Image(systemName: symbol).font(.system(size: 12))
                        } else {
                            Text(option.label).font(.system(size: 12.5))
                        }
                    }
                    .padding(.horizontal, option.symbol == nil ? 10 : 8)
                    .frame(minWidth: 30, minHeight: 26)
                    .foregroundStyle(selected ? Theme.ink : Theme.muted)
                    .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Theme.raise2 : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(option.label)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line2))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityName)
    }
}
