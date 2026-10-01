import SwiftUI

/// The instrument palette: warm graphite, off-white, and one signal orange
/// reserved for readings that need attention.
enum Theme {
    static let bg = Color(hex: 0x0F0F0E)
    static let raise = Color(hex: 0x171715)
    static let raise2 = Color(hex: 0x1E1E1C)
    static let line = Color(hex: 0x262624)
    static let line2 = Color(hex: 0x363632)
    static let ink = Color(hex: 0xEDECE6)
    static let soft = Color(hex: 0xBDBCB4)
    static let muted = Color(hex: 0x8A8981)
    static let faint = Color(hex: 0x5C5B55)
    /// Reserved for readings that need attention.
    static let signal = Color(hex: 0xFF6B2C)

    /// Each metric's own flat colour, carried through its dot, scale, trace, rings and history.
    static func tone(_ metric: String) -> Color {
        switch metric {
        case "CPU": Color(hex: 0x5AA7FF)
        case "Memory": Color(hex: 0xB08CFF)
        case "GPU": Color(hex: 0xFF7EB6)
        case "Disk": Color(hex: 0xE9BE55)
        case "Network": Color(hex: 0x3FD0A8)
        case "Battery": Color(hex: 0x9BD25B)
        case "Projects": Color(hex: 0xC9C8C0)
        default: ink
        }
    }

    /// Tonal steps of a metric colour for ring slices, strongest first.
    static let rampOpacity: [Double] = [1, 0.74, 0.52, 0.36, 0.24, 0.15]

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// A one-pixel hairline in the panel line colour.
struct Hairline: View {
    var axis: Axis = .horizontal
    var color: Color = Theme.line
    var body: some View {
        Rectangle().fill(color)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
    }
}

/// Status LED: filled orange when on, a faint ring when off.
struct LED: View {
    var on: Bool
    var body: some View {
        Circle()
            .fill(on ? Theme.signal : .clear)
            .strokeBorder(on ? Theme.signal : Theme.faint, lineWidth: 1)
            .frame(width: 7, height: 7)
    }
}

/// The Gauge mark: a dial arc drawn as a G, with the orange needle as its crossbar.
struct GaugeMark: View {
    var size: CGFloat = 18
    var body: some View {
        Canvas { ctx, s in
            let c = CGPoint(x: s.width / 2, y: s.height / 2)
            let r = s.width * 0.34
            let w = s.width * 0.11
            var arc = Path()
            arc.addArc(center: c, radius: r, startAngle: .degrees(-44), endAngle: .degrees(0), clockwise: true)
            ctx.stroke(arc, with: .color(Theme.ink), style: StrokeStyle(lineWidth: w, lineCap: .round))
            var bar = Path()
            bar.move(to: c)
            bar.addLine(to: CGPoint(x: c.x + r, y: c.y))
            ctx.stroke(bar, with: .color(Theme.signal), style: StrokeStyle(lineWidth: w, lineCap: .round))
            let d = w * 1.3
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)), with: .color(Theme.ink))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
