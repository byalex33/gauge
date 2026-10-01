import Foundation

/// Display formatting. Memory uses binary units (like Activity Monitor);
/// storage and network use decimal units (like Finder).
enum Fmt {
    static func memory(_ bytes: Double) -> (String, String) {
        let gb = bytes / 1_073_741_824
        if gb >= 1 { return (String(format: "%.2f", gb), "GB") }
        return (String(format: "%.1f", bytes / 1_048_576), "MB")
    }

    static func memoryText(_ bytes: Double) -> String {
        let (v, u) = memory(bytes)
        return "\(v) \(u)"
    }

    static func storage(_ bytes: Double) -> (String, String) {
        if bytes >= 1e12 { return (String(format: "%.2f", bytes / 1e12), "TB") }
        if bytes >= 1e9 { return (String(format: "%.2f", bytes / 1e9), "GB") }
        if bytes >= 1e6 { return (String(format: "%.1f", bytes / 1e6), "MB") }
        return (String(format: "%.0f", bytes / 1e3), "kB")
    }

    static func storageText(_ bytes: Double) -> String {
        let (v, u) = storage(bytes)
        return "\(v) \(u)"
    }

    static func rate(_ bytesPerSecond: Double) -> (String, String) {
        let b = max(0, bytesPerSecond)
        if b < 1_000 { return (String(format: "%.0f", b), "B/s") }
        if b < 1_000_000 { return (String(format: "%.0f", b / 1e3), "kB/s") }
        if b < 1_000_000_000 { return (String(format: "%.1f", b / 1e6), "MB/s") }
        return (String(format: "%.2f", b / 1e9), "GB/s")
    }

    static func rateText(_ bytesPerSecond: Double) -> String {
        let (v, u) = rate(bytesPerSecond)
        return "\(v) \(u)"
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    static func minutes(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    static func cpuTime(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        if s >= 60 { return "\(s / 60)m \(s % 60)s" }
        return "\(s)s"
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// The smallest "nice" decade scale that fits a rate, for ruler end labels.
    static func rateScale(_ peak: Double) -> Double {
        var scale = 100_000.0
        while scale < peak, scale < 1e11 { scale *= 10 }
        return scale
    }
}
