import AppKit
import Observation

struct Stat: Hashable { var label: String; var value: String }

struct Vital: Identifiable {
    var id: String { name }
    var name: String
    var caption: String
    var value: String
    var unit: String
    /// Position on the channel's ruler, 0...1.
    var fraction: Double
    var scale: (String, String)
    var stats: [Stat]
    /// Recent trace, normalised to 0...1.
    var trace: [Double]
    var flag: String?
    var symbol: String
}

struct Notice: Identifiable {
    var id: String { tag + title }
    var tag: String
    var title: String
    var body: String
    var hot: Bool
    var since: Date
    var target: String
}

struct Slice: Identifiable {
    var id: String { name }
    var name: String
    var value: String
    var share: Double
    var hot = false
}

struct Breakdown: Identifiable {
    var id: String { title }
    /// The metric whose colour the ring uses.
    var metric: String
    var title: String
    var subtitle: String
    var center: String
    var centerCaption: String
    var slices: [Slice]
}

struct HardwareCard: Identifiable {
    var id: String { title }
    /// Colour key for the card's dot.
    var tone: String
    var title: String
    var rows: [Stat]
    var note: String?
}

struct StatusItem: Identifiable {
    var id: String { text }
    var on: Bool
    var text: String
}

enum HistoryMetric: String, CaseIterable, Identifiable {
    case cpu = "CPU", memory = "Memory", network = "Network"
    var id: String { rawValue }
}

enum HistoryPeriod: Int, CaseIterable, Identifiable {
    case hour = 3600, sixHours = 21_600, twelveHours = 43_200, day = 86_400, week = 604_800
    var id: Int { rawValue }
    var short: String {
        switch self {
        case .hour: "1h"
        case .sixHours: "6h"
        case .twelveHours: "12h"
        case .day: "24h"
        case .week: "7d"
        }
    }
    var label: String {
        switch self {
        case .hour: "1 hour"
        case .sixHours: "6 hours"
        case .twelveHours: "12 hours"
        case .day: "24 hours"
        case .week: "7 days"
        }
    }
}

/// A recent reading kept in memory for channel traces and detail sheets.
struct RecentSample {
    var date: Date
    var cpu: Double
    var memory: Double
    var memoryTotal: Double
    var gpu: Double
    var diskRead: Double
    var diskWrite: Double
    var down: Double
    var up: Double
    var battery: Double?
    var diskIO: Double { diskRead + diskWrite }
}

@MainActor @Observable
final class Monitor {
    static let tabs = ["Overview", "CPU", "Memory", "Disk", "Network", "GPU", "Battery", "Projects"]

    var ready = false
    var vitals: [Vital] = []
    var notices: [Notice] = []
    var dismissed: Set<String> = []
    var breakdowns: [Breakdown] = []
    var hardware: [HardwareCard] = []
    var apps: [AppUsage] = []
    var servers: [DevServer] = []
    var status: [StatusItem] = []
    var processCount = 0
    var appCount = 0
    var machine = ""
    var recent: [RecentSample] = []

    var historyMetric: HistoryMetric = .cpu
    var period: HistoryPeriod = .twelveHours { didSet { reloadHistory() } }
    var history: [HistoryPoint] = []
    var topApps: [(String, Double)] = []
    var oldestSample: Date?

    let store = HistoryStore()
    let sampler = Sampler()
    private let queue = DispatchQueue(label: "gauge.sampler", qos: .utility)
    private var timer: Timer?
    private(set) var latest: Reading?
    private var pending: [Reading] = []
    private var pendingCPU: [String: Double] = [:]
    private var ticks = 0
    private var serverList: [DevServer] = []
    private var memoryWarningSince: Date?
    private var busyApps: [String: Date] = [:]
    private var cpuHighSince: Date?
    private var gpuPeak = 0.0

    var visibleNotices: [Notice] { notices.filter { !dismissed.contains($0.id) } }

    /// False while no Gauge window is visible: sampling and history continue, view updates pause.
    private var windowVisible = true
    private var occlusionObserver: NSObjectProtocol?

    func start() {
        guard timer == nil else { return }
        machine = "\(sampler.chip) · \(sampler.cores) cores · \(Int(sampler.memoryTotal / 1_073_741_824)) GB"
        store.prune(keepingDays: Self.retentionDays)
        let sampler = sampler
        queue.async { _ = sampler.read() }  // prime the counters so the first delta is real
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.tick() }
        reloadHistory()
        occlusionObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeOcclusionStateNotification,
                                                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let visible = NSApp.occlusionState.contains(.visible)
                guard visible != self.windowVisible else { return }
                self.windowVisible = visible
                if visible, let latest = self.latest { self.publish(latest) }
            }
        }
    }

    static var retentionDays: Int {
        let days = UserDefaults.standard.integer(forKey: "historyRetentionDays")
        return days > 0 ? days : 30
    }

    private func tick() {
        let sampler = sampler
        queue.async {
            let reading = sampler.read()
            DispatchQueue.main.async { [weak self] in self?.ingest(reading) }
        }
    }

    // MARK: Ingest

    private func ingest(_ r: Reading) {
        guard r.cpuUser != nil else { return }
        latest = r
        ticks += 1
        if let servers = r.servers { serverList = servers }

        let cpu = (r.cpuUser ?? 0) + (r.cpuSystem ?? 0)
        gpuPeak = max(gpuPeak, r.gpuUtilization ?? 0)
        updateFlags(r, cpu: cpu)
        persist(r)
        if ticks % 1800 == 0 { store.prune(keepingDays: Self.retentionDays) }
        recent.append(RecentSample(date: r.date, cpu: cpu, memory: r.memory.used, memoryTotal: r.memory.total,
                                   gpu: r.gpuUtilization ?? 0, diskRead: r.disk.readRate, diskWrite: r.disk.writeRate,
                                   down: r.network.downRate, up: r.network.upRate, battery: r.battery?.percent))
        if recent.count > 300 { recent.removeFirst(recent.count - 300) }
        if windowVisible || !ready || Snapshot.folder != nil { publish(r) }
    }

    /// Rebuilds everything the views show from a reading.
    private func publish(_ r: Reading) {
        let cpu = (r.cpuUser ?? 0) + (r.cpuSystem ?? 0)
        appCount = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.count
        processCount = r.processCount
        apps = r.apps.sorted { $0.cpu > $1.cpu }
        servers = serverList
        vitals = buildVitals(r, cpu: cpu)
        notices = buildNotices(r)
        breakdowns = buildBreakdowns(r, cpu: cpu)
        hardware = buildHardware(r)
        status = buildStatus()
        ready = true
        if ticks % 15 == 1 { reloadHistory() }
    }

    private func persist(_ r: Reading) {
        pending.append(r)
        for (app, seconds) in r.cpuSecondsDelta { pendingCPU[app, default: 0] += seconds }
        if pending.count >= 5 {
            let n = Double(pending.count)
            func avg(_ f: (Reading) -> Double) -> Double { pending.map(f).reduce(0, +) / n }
            let batteries = pending.compactMap { $0.battery?.percent }
            store.insert(.init(t: Int(r.date.timeIntervalSince1970),
                               cpu: avg { ($0.cpuUser ?? 0) + ($0.cpuSystem ?? 0) },
                               memory: avg { $0.memory.used }, memoryTotal: r.memory.total,
                               gpu: avg { $0.gpuUtilization ?? 0 },
                               down: avg { $0.network.downRate }, up: avg { $0.network.upRate },
                               diskRead: avg { $0.disk.readRate }, diskWrite: avg { $0.disk.writeRate },
                               battery: batteries.isEmpty ? nil : batteries.reduce(0, +) / Double(batteries.count)))
            pending.removeAll()
        }
        if ticks % 30 == 0 {
            store.addCPUTime(pendingCPU, at: r.date)
            pendingCPU.removeAll()
        }
    }

    func reloadHistory() {
        let since = Date().addingTimeInterval(-Double(period.rawValue))
        store.series(since: since) { [weak self] points in self?.history = points }
        store.topApps(since: since) { [weak self] apps in self?.topApps = apps }
        store.oldestSample { [weak self] date in self?.oldestSample = date }
    }

    func clearHistory() {
        store.clear { [weak self] in
            self?.history = []
            self?.topApps = []
            self?.oldestSample = nil
        }
    }

    // MARK: Flags

    private var memoryFlag: String? {
        guard let p = latest?.memory.pressure else { return nil }
        return p >= 4 ? "Critical" : p >= 2 ? "Elevated" : nil
    }

    private var diskLow: Bool {
        guard let d = latest?.disk, d.total > 0 else { return false }
        return d.available / d.total < 0.1
    }

    private func updateFlags(_ r: Reading, cpu: Double) {
        memoryWarningSince = r.memory.pressure >= 2 ? (memoryWarningSince ?? r.date) : nil
        cpuHighSince = cpu >= 85 ? (cpuHighSince ?? r.date) : nil
        var busy: [String: Date] = [:]
        for app in r.apps where app.cpu >= 90 && app.name != "macOS" { busy[app.name] = busyApps[app.name] ?? r.date }
        busyApps = busy
    }

    private func sustained(_ since: Date?, _ seconds: TimeInterval = 30) -> Bool {
        guard let since else { return false }
        return Date().timeIntervalSince(since) >= seconds
    }

    // MARK: Vitals

    private func trace(_ f: (RecentSample) -> Double, scale: Double? = nil) -> [Double] {
        let values = recent.suffix(58).map(f)
        let top = scale ?? max(values.max() ?? 1, 1)
        return values.map { min(1, max(0, $0 / top)) }
    }

    private func buildVitals(_ r: Reading, cpu: Double) -> [Vital] {
        let cpuAverage = recent.map(\.cpu).reduce(0, +) / Double(max(recent.count, 1))
        let mem = r.memory
        let (memValue, memUnit) = Fmt.memory(mem.used)
        let gpu = r.gpuUtilization
        let gpuAverage = recent.map(\.gpu).reduce(0, +) / Double(max(recent.count, 1))
        let (freeValue, freeUnit) = Fmt.storage(r.disk.available)
        let (downValue, downUnit) = Fmt.rate(r.network.downRate)
        let netScale = Fmt.rateScale(recent.suffix(58).map(\.down).max() ?? 0)

        var list = [
            Vital(name: "CPU", caption: "Now", value: String(format: "%.0f", cpu), unit: "%",
                  fraction: cpu / 100, scale: ("0", "100%"),
                  stats: [Stat(label: "User", value: Fmt.percent(r.cpuUser ?? 0)),
                          Stat(label: "System", value: Fmt.percent(r.cpuSystem ?? 0)),
                          Stat(label: "Average", value: Fmt.percent(cpuAverage))],
                  trace: trace(\.cpu, scale: 100), flag: sustained(cpuHighSince) ? "High" : nil, symbol: "cpu"),
            Vital(name: "Memory", caption: "In use of \(Int(mem.total / 1_073_741_824)) GB", value: memValue, unit: memUnit,
                  fraction: mem.total > 0 ? mem.used / mem.total : 0, scale: ("0", "\(Int(mem.total / 1_073_741_824)) GB"),
                  stats: [Stat(label: "App", value: Fmt.memoryText(mem.app)),
                          Stat(label: "Wired", value: Fmt.memoryText(mem.wired)),
                          Stat(label: "Compressed", value: Fmt.memoryText(mem.compressed))],
                  trace: trace(\.memory, scale: mem.total), flag: memoryFlag, symbol: "memorychip"),
            Vital(name: "GPU", caption: sampler.chip, value: gpu.map { String(format: "%.0f", $0) } ?? "–", unit: "%",
                  fraction: (gpu ?? 0) / 100, scale: ("0", "100%"),
                  stats: [Stat(label: "Memory", value: r.gpuMemory.map(Fmt.memoryText) ?? "–"),
                          Stat(label: "Average", value: Fmt.percent(gpuAverage)),
                          Stat(label: "Peak", value: Fmt.percent(gpuPeak))],
                  trace: trace(\.gpu, scale: 100), symbol: "square.stack.3d.up"),
            Vital(name: "Disk", caption: "Free of \(Fmt.storageText(r.disk.total))", value: freeValue, unit: freeUnit,
                  fraction: r.disk.total > 0 ? r.disk.available / r.disk.total : 0, scale: ("0", Fmt.storageText(r.disk.total)),
                  stats: [Stat(label: "Reading", value: Fmt.rateText(r.disk.readRate)),
                          Stat(label: "Writing", value: Fmt.rateText(r.disk.writeRate)),
                          Stat(label: "Written since launch", value: Fmt.storageText(r.disk.writtenSinceLaunch))],
                  trace: trace(\.diskIO), flag: diskLow ? "Low space" : nil, symbol: "internaldrive"),
            Vital(name: "Network", caption: "Downloading", value: downValue, unit: downUnit,
                  fraction: r.network.downRate / netScale, scale: ("0", Fmt.rateText(netScale)),
                  stats: [Stat(label: "Uploading", value: Fmt.rateText(r.network.upRate)),
                          Stat(label: "Received", value: Fmt.storageText(r.network.receivedSinceLaunch)),
                          Stat(label: "Sent", value: Fmt.storageText(r.network.sentSinceLaunch))],
                  trace: trace(\.down), symbol: "network"),
        ]

        if let b = r.battery {
            let caption = b.charging ? "Charging" : b.onAC ? "On power adapter" : "On battery"
            let time = b.charging ? b.minutesToFull.map(Fmt.minutes) : b.minutesToEmpty.map(Fmt.minutes)
            list.append(Vital(name: "Battery", caption: caption, value: String(format: "%.0f", b.percent), unit: "%",
                              fraction: b.percent / 100, scale: ("0", "100%"),
                              stats: [Stat(label: b.charging ? "Until full" : "Remaining", value: time ?? "–"),
                                      Stat(label: "Power", value: b.watts.map { String(format: "%.1f W", $0) } ?? "–"),
                                      Stat(label: "Health", value: b.health.map(Fmt.percent) ?? "–")],
                              trace: trace({ $0.battery ?? 0 }, scale: 100),
                              flag: !b.onAC && b.percent < 15 ? "Low" : nil, symbol: "battery.75percent"))
        } else {
            list.append(Vital(name: "Battery", caption: "No battery", value: "AC", unit: "power", fraction: 0,
                              scale: ("0", "100%"), stats: [Stat(label: "Source", value: "Power adapter")],
                              trace: [], symbol: "powerplug"))
        }
        return list
    }

    // MARK: Notices

    private func buildNotices(_ r: Reading) -> [Notice] {
        var list: [Notice] = []
        if let since = memoryWarningSince {
            let top = r.apps.filter { $0.name != "macOS" }.sorted { $0.memory > $1.memory }.prefix(2)
            let users = top.map { "\($0.name), \(Fmt.memoryText($0.memory))" }.joined(separator: ", and ")
            list.append(Notice(tag: "Memory", title: "Memory pressure is elevated",
                               body: users.isEmpty ? "macOS is compressing memory to keep up." : "The biggest users are \(users).",
                               hot: true, since: since, target: "Memory"))
        }
        for (name, since) in busyApps where sustained(since) {
            let cpu = r.apps.first { $0.name == name }?.cpu ?? 0
            list.append(Notice(tag: "CPU", title: "\(name) is using a lot of CPU",
                               body: "\(Fmt.percent(cpu)) of one core for the last \(max(1, Int(Date().timeIntervalSince(since) / 60))) min.",
                               hot: true, since: since, target: "CPU"))
        }
        if diskLow {
            list.append(Notice(tag: "Disk", title: "Your startup disk is almost full",
                               body: "\(Fmt.storageText(r.disk.available)) free of \(Fmt.storageText(r.disk.total)).",
                               hot: true, since: r.date, target: "Disk"))
        }
        if !servers.isEmpty {
            let idle = servers.allSatisfy(\.idle)
            let count = servers.count == 1 ? "A dev server is" : "\(servers.count) dev servers are"
            let byRuntime = Dictionary(grouping: servers, by: \.name)
            let ports = byRuntime.keys.sorted().map { name in
                let list = byRuntime[name]!.flatMap(\.ports).sorted().map(String.init)
                return "\(name) on \(list.formatted(.list(type: .and)))"
            }
            .joined(separator: "; ")
            let memory = Fmt.memoryText(servers.map(\.memory).reduce(0, +))
            list.append(Notice(tag: "Projects", title: "\(count) running\(idle ? " but idle" : "")",
                               body: "\(ports). Together they use \(memory).",
                               hot: false, since: notices.first { $0.tag == "Projects" }?.since ?? r.date, target: "Projects"))
        }
        if let health = r.battery?.health, health < 80 {
            list.append(Notice(tag: "Battery", title: "Battery health is \(Fmt.percent(health))",
                               body: "Cycle count \(r.battery?.cycles ?? 0). Capacity is below 80% of its design.",
                               hot: false, since: r.date, target: "Battery"))
        }
        return list
    }

    private func buildStatus() -> [StatusItem] {
        let flagged = vitals.filter { $0.flag != nil }
        let names = flagged.map { v -> String in
            switch v.name {
            case "Memory": "Memory pressure \(v.flag!.lowercased())"
            case "CPU": "CPU load high"
            case "Disk": "Startup disk low on space"
            case "Battery": "Battery low"
            default: "\(v.name) \(v.flag!.lowercased())"
            }
        }
        let normal = vitals.count - flagged.count
        if flagged.isEmpty { return [StatusItem(on: false, text: "All \(normal) readings normal")] }
        return names.map { StatusItem(on: true, text: $0) } + [StatusItem(on: false, text: "\(normal) readings normal")]
    }

    // MARK: Breakdowns

    private func buildBreakdowns(_ r: Reading, cpu: Double) -> [Breakdown] {
        let m = r.memory
        let total = max(m.total, 1)
        let types: [(String, Double)] = [("App", m.app), ("Wired", m.wired), ("Compressed", m.compressed), ("Cached", m.cached), ("Free", m.free)]
        let memoryByType = Breakdown(metric: "Memory", title: "Memory by type", subtitle: "\(Fmt.percent(m.used / total * 100)) in use",
                                     center: Fmt.percent(m.used / total * 100), centerCaption: "in use",
                                     slices: types.map { Slice(name: $0.0, value: Fmt.memoryText($0.1), share: $0.1 / total,
                                                               hot: $0.0 == "Compressed" && memoryFlag != nil) })

        // App footprints include shared and compressed pages, so they can add up to more than
        // "memory used". Shares are taken of whichever total is larger so the ring never overflows.
        let byMemory = r.apps.sorted { $0.memory > $1.memory }
        let topMemory = Array(byMemory.prefix(5))
        let topTotal = topMemory.map(\.memory).reduce(0, +)
        let otherMemory = max(0, m.used - topTotal)
        let ringTotal = max(m.used, topTotal, 1)
        let (usedValue, usedUnit) = Fmt.memory(m.used)
        var appSlices = topMemory.map { Slice(name: $0.name, value: Fmt.memoryText($0.memory), share: $0.memory / ringTotal) }
        if otherMemory / ringTotal >= 0.01 {
            appSlices.append(Slice(name: "Other & system", value: Fmt.memoryText(otherMemory), share: otherMemory / ringTotal))
        }
        let memoryByApp = Breakdown(metric: "Memory", title: "Memory by app", subtitle: "\(usedValue) \(usedUnit) in use",
                                    center: usedValue, centerCaption: usedUnit, slices: appSlices)

        let byCPU = r.apps.sorted { $0.cpu > $1.cpu }
        let topCPU = Array(byCPU.prefix(4))
        let otherCPU = byCPU.dropFirst(4).map(\.cpu).reduce(0, +)
        let cpuSum = max(topCPU.map(\.cpu).reduce(0, +) + otherCPU, 0.01)
        let cpuByApp = Breakdown(metric: "CPU", title: "CPU by app", subtitle: "\(Fmt.percent(cpu)) in use",
                                 center: Fmt.percent(cpu), centerCaption: "in use",
                                 slices: topCPU.map { Slice(name: $0.name, value: String(format: "%.1f%%", $0.cpu), share: $0.cpu / cpuSum) }
                                     + [Slice(name: "Other", value: String(format: "%.1f%%", otherCPU), share: otherCPU / cpuSum)])

        let d = r.disk
        let diskTotal = max(d.total, 1)
        let disk = Breakdown(metric: "Disk", title: "Startup disk", subtitle: d.name,
                             center: Fmt.percent((d.total - d.available) / diskTotal * 100), centerCaption: "used",
                             slices: [Slice(name: "Used", value: Fmt.storageText(d.total - d.available), share: (d.total - d.available) / diskTotal),
                                      Slice(name: "Available", value: Fmt.storageText(d.available), share: d.available / diskTotal, hot: diskLow)])
        return [memoryByType, memoryByApp, cpuByApp, disk]
    }

    // MARK: Hardware

    private func buildHardware(_ r: Reading) -> [HardwareCard] {
        var audioRows = [Stat(label: "Playing", value: r.audioPlaying ? "Yes" : "Nothing")]
        if let device = r.audioDevice { audioRows.append(Stat(label: "Output", value: device)) }
        let accessories = r.accessories.map { Stat(label: $0.name, value: "\($0.percent)%") }
        return [
            HardwareCard(tone: "Disk", title: "Temperature & fans", rows: [Stat(label: "Sensors", value: "Not available yet")],
                         note: "Reading temperature sensors needs a privileged helper, which Gauge doesn't have yet."),
            HardwareCard(tone: "GPU", title: "Audio activity", rows: audioRows,
                         note: r.audioPlaying ? "Audio is playing through this output." : "Nothing is playing."),
            HardwareCard(tone: "CPU", title: "Bluetooth batteries",
                         rows: accessories.isEmpty ? [Stat(label: "Accessories", value: "None")] : accessories,
                         note: accessories.isEmpty ? "Apple keyboards, mice and trackpads show their battery here when connected." : nil),
        ]
    }

    // MARK: Export

    func csv() -> String {
        var lines = ["time,cpu_percent,memory_used_gb,download_bytes_per_second"]
        let formatter = ISO8601DateFormatter()
        for p in history {
            lines.append("\(formatter.string(from: p.date)),\(String(format: "%.1f", p.cpu)),\(String(format: "%.2f", p.memoryUsed / 1_073_741_824)),\(String(format: "%.0f", p.download))")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
