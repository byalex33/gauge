import Foundation
import Darwin
import IOKit
import IOKit.ps
import CoreAudio

// Raw readings from public macOS counters. Nothing here needs elevated privileges,
// and nothing leaves the Mac.

struct MemoryReading {
    var total: Double = 0, app: Double = 0, wired: Double = 0, compressed: Double = 0
    var cached: Double = 0, free: Double = 0, swapUsed: Double = 0
    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical.
    var pressure: Int = 1
    var used: Double { app + wired + compressed }
}

struct DiskReading {
    var name = "Macintosh HD"
    var total: Double = 0, available: Double = 0
    var readRate: Double = 0, writeRate: Double = 0
    var writtenSinceLaunch: Double = 0
}

struct NetworkReading {
    var downRate: Double = 0, upRate: Double = 0
    var receivedSinceLaunch: Double = 0, sentSinceLaunch: Double = 0
}

struct BatteryReading {
    var percent: Double
    var charging: Bool
    var onAC: Bool
    var minutesToFull: Int?
    var minutesToEmpty: Int?
    var watts: Double?
    var health: Double?
    var cycles: Int?
}

struct AppUsage: Identifiable, Hashable {
    var id: String { name }
    var name: String
    /// Percent of one core, like Activity Monitor.
    var cpu: Double
    var memory: Double
    /// Lifetime CPU seconds of the app's running processes.
    var cpuTime: Double
}

struct DevServer: Identifiable, Hashable {
    var id: String { "\(pid)" }
    var pid: Int32
    var name: String
    var folder: String
    var ports: [Int]
    var cpu: Double
    var memory: Double
    var idle: Bool { cpu < 1 }
}

struct Reading {
    var date = Date()
    var cpuUser: Double?
    var cpuSystem: Double?
    var memory = MemoryReading()
    var gpuUtilization: Double?
    var gpuMemory: Double?
    var disk = DiskReading()
    var network = NetworkReading()
    var battery: BatteryReading?
    var apps: [AppUsage] = []
    var processCount = 0
    /// CPU seconds each app used since the previous reading, for the history store.
    var cpuSecondsDelta: [String: Double] = [:]
    /// Nil when the listening-port scan did not run this tick.
    var servers: [DevServer]?
    var audioPlaying = false
    var audioDevice: String?
    var accessories: [(name: String, percent: Int)] = []
}

/// Samples system counters. Not thread-safe: Monitor only uses it from one serial queue.
final class Sampler: @unchecked Sendable {
    private var previousCPU: [UInt64]?
    private var previousNetwork: (down: UInt64, up: UInt64, at: Date)?
    private var networkBase: (down: UInt64, up: UInt64)?
    private var previousDisk: (read: UInt64, write: UInt64, at: Date)?
    private var diskWriteBase: UInt64?
    private var previousProcesses: [Int32: UInt64] = [:]
    private var previousProcessWall: UInt64 = 0
    private var lastVolumeCheck = Date.distantPast
    private var volume: (name: String, total: Double, available: Double) = ("Macintosh HD", 0, 0)
    private var lastServerScan = Date.distantPast
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    let memoryTotal: Double = Double(Sampler.sysctlInt64("hw.memsize") ?? 0)
    let cores: Int = Int(Sampler.sysctlInt64("hw.ncpu") ?? 0)
    let chip: String = Sampler.sysctlString("machdep.cpu.brand_string") ?? "Apple silicon"

    func read() -> Reading {
        var r = Reading()
        let priming = previousCPU == nil  // the first read only seeds counters; its result is discarded
        if let cpu = readCPU() { r.cpuUser = cpu.user; r.cpuSystem = cpu.system }
        r.memory = readMemory()
        if let gpu = readGPU() { r.gpuUtilization = gpu.utilization; r.gpuMemory = gpu.memory }
        r.disk = readDisk(now: r.date)
        r.network = readNetwork(now: r.date)
        r.battery = readBattery()
        let processes = readProcesses()
        r.apps = processes.apps
        r.processCount = processes.count
        r.cpuSecondsDelta = processes.cpuDelta
        if !priming, r.date.timeIntervalSince(lastServerScan) >= 15 {
            lastServerScan = r.date
            r.servers = scanDevServers(processes: processes.byPID)
        }
        let audio = readAudio()
        r.audioPlaying = audio.playing
        r.audioDevice = audio.device
        r.accessories = readAccessoryBatteries()
        return r
    }

    // MARK: CPU

    private func readCPU() -> (user: Double, system: Double)? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var totals: [UInt64] = [0, 0, 0, 0]  // user, system, idle, nice
        for cpu in 0..<Int(count) {
            let base = cpu * Int(CPU_STATE_MAX)
            totals[0] += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            totals[1] += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            totals[2] += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            totals[3] += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
        }
        defer { previousCPU = totals }
        guard let previous = previousCPU else { return nil }
        let d = zip(totals, previous).map { $0 >= $1 ? Double($0 - $1) : 0 }
        let total = d.reduce(0, +)
        guard total > 0 else { return nil }
        return ((d[0] + d[3]) / total * 100, d[1] / total * 100)
    }

    // MARK: Memory

    private func readMemory() -> MemoryReading {
        var m = MemoryReading(total: memoryTotal)
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            m.app = Double(stats.internal_page_count &- stats.purgeable_count) * page
            m.wired = Double(stats.wire_count) * page
            m.compressed = Double(stats.compressor_page_count) * page
            m.cached = Double(stats.external_page_count + stats.purgeable_count) * page
            m.free = max(0, memoryTotal - m.used - m.cached)
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { m.swapUsed = Double(swap.xsu_used) }
        m.pressure = Int(Sampler.sysctlInt32("kern.memorystatus_vm_pressure_level") ?? 1)
        return m
    }

    // MARK: GPU

    private func readGPU() -> (utilization: Double, memory: Double)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            let utilization = (stats["Device Utilization %"] as? NSNumber) ?? (stats["GPU Activity(%)"] as? NSNumber)
            if let utilization {
                let memory = (stats["In use system memory"] as? NSNumber)?.doubleValue ?? 0
                return (utilization.doubleValue, memory)
            }
        }
        return nil
    }

    // MARK: Disk

    private func readDisk(now: Date) -> DiskReading {
        if now.timeIntervalSince(lastVolumeCheck) >= 15 {
            lastVolumeCheck = now
            let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
            if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) {
                volume = (v.volumeName ?? "Macintosh HD",
                          Double(v.volumeTotalCapacity ?? 0),
                          Double(v.volumeAvailableCapacityForImportantUsage ?? 0))
            }
        }
        var d = DiskReading(name: volume.name, total: volume.total, available: volume.available)
        var read: UInt64 = 0, write: UInt64 = 0
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS {
            var entry = IOIteratorNext(iterator)
            while entry != 0 {
                if let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] {
                    read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                    write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
                }
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
        }
        if diskWriteBase == nil { diskWriteBase = write }
        d.writtenSinceLaunch = Double(write &- (diskWriteBase ?? write))
        if let p = previousDisk {
            let seconds = max(0.001, now.timeIntervalSince(p.at))
            d.readRate = read >= p.read ? Double(read - p.read) / seconds : 0
            d.writeRate = write >= p.write ? Double(write - p.write) / seconds : 0
        }
        previousDisk = (read, write, now)
        return d
    }

    // MARK: Network

    private func readNetwork(now: Date) -> NetworkReading {
        var n = NetworkReading()
        let (down, up) = Sampler.interfaceBytes()
        if networkBase == nil { networkBase = (down, up) }
        if let base = networkBase {
            n.receivedSinceLaunch = Double(down &- base.down)
            n.sentSinceLaunch = Double(up &- base.up)
        }
        if let p = previousNetwork {
            let seconds = max(0.001, now.timeIntervalSince(p.at))
            n.downRate = down >= p.down ? Double(down - p.down) / seconds : 0
            n.upRate = up >= p.up ? Double(up - p.up) / seconds : 0
        }
        previousNetwork = (down, up, now)
        return n
    }

    /// 64-bit byte counters for physical interfaces (Wi-Fi, Ethernet, cellular).
    private static func interfaceBytes() -> (UInt64, UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return (0, 0) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return (0, 0) }
        var down: UInt64 = 0, up: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if header.ifm_type == UInt8(RTM_IFINFO2), offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(info.ifm_index), &name) != nil {
                        let interface = String(cString: name)
                        if interface.hasPrefix("en") || interface.hasPrefix("pdp_ip") {
                            down += info.ifm_data.ifi_ibytes
                            up += info.ifm_data.ifi_obytes
                        }
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (down, up)
    }

    // MARK: Battery

    private func readBattery() -> BatteryReading? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (d["Type"] as? String) == "InternalBattery" else { continue }
            let current = (d["Current Capacity"] as? Int) ?? 0
            let maximum = max(1, (d["Max Capacity"] as? Int) ?? 100)
            var b = BatteryReading(percent: Double(current) / Double(maximum) * 100,
                                   charging: (d["Is Charging"] as? Bool) ?? false,
                                   onAC: (d["Power Source State"] as? String) == "AC Power")
            if let full = d["Time to Full Charge"] as? Int, full > 0 { b.minutesToFull = full }
            if let empty = d["Time to Empty"] as? Int, empty > 0 { b.minutesToEmpty = empty }
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                defer { IOObjectRelease(service) }
                var props: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let p = props?.takeRetainedValue() as? [String: Any] {
                    if let volts = (p["Voltage"] as? NSNumber)?.doubleValue,
                       let amps = (p["InstantAmperage"] as? NSNumber ?? p["Amperage"] as? NSNumber)?.int64Value {
                        b.watts = abs(volts * Double(amps)) / 1_000_000
                    }
                    if let raw = (p["AppleRawMaxCapacity"] as? NSNumber)?.doubleValue,
                       let design = (p["DesignCapacity"] as? NSNumber)?.doubleValue, design > 0 {
                        b.health = min(100, raw / design * 100)
                    }
                    b.cycles = (p["CycleCount"] as? NSNumber)?.intValue
                }
            }
            return b
        }
        return nil
    }

    // MARK: Processes

    private struct ProcessSample {
        var pid: Int32
        var app: String
        var command: String
        var cpu: Double
        var memory: Double
    }

    private func readProcesses() -> (apps: [AppUsage], count: Int, cpuDelta: [String: Double], byPID: [Int32: ProcessSample]) {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return ([], 0, [:], [:]) }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let found = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
        let wall = mach_absolute_time()
        let wallDelta = previousProcessWall > 0 ? toSeconds(wall - previousProcessWall) : 0
        var groups: [String: AppUsage] = [:]
        var delta: [String: Double] = [:]
        var byPID: [Int32: ProcessSample] = [:]
        var ticks: [Int32: UInt64] = [:]

        for pid in pids.prefix(found) where pid > 0 {
            var task = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size else { continue }
            let total = task.pti_total_user + task.pti_total_system
            ticks[pid] = total
            var usage = rusage_info_v4()
            let footprint = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            } == 0 ? Double(usage.ri_phys_footprint) : Double(task.pti_resident_size)

            var pathBuffer = [CChar](repeating: 0, count: 4096)
            proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            var nameBuffer = [CChar](repeating: 0, count: 256)
            proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let command = String(cString: nameBuffer)
            let app = Sampler.appName(path: String(cString: pathBuffer), command: command)

            var seconds = 0.0
            if let before = previousProcesses[pid], total >= before { seconds = toSeconds(total - before) }
            let cpu = wallDelta > 0 ? seconds / wallDelta * 100 : 0
            delta[app, default: 0] += seconds
            byPID[pid] = ProcessSample(pid: pid, app: app, command: command, cpu: cpu, memory: footprint)

            var group = groups[app] ?? AppUsage(name: app, cpu: 0, memory: 0, cpuTime: 0)
            group.cpu += cpu
            group.memory += footprint
            group.cpuTime += toSeconds(total)
            groups[app] = group
        }
        previousProcesses = ticks
        previousProcessWall = wall
        return (Array(groups.values), found, wallDelta > 0 ? delta : [:], byPID)
    }

    private func toSeconds(_ machTicks: UInt64) -> Double {
        Double(machTicks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    private static let friendlyNames = [
        "node": "Node.js", "python": "Python", "python3": "Python", "java": "Java", "ruby": "Ruby",
        "bun": "Bun", "deno": "Deno", "php": "PHP", "go": "Go",
    ]

    /// Groups helpers under their app bundle, and system binaries under "macOS".
    static func appName(path: String, command: String) -> String {
        if let range = path.range(of: ".app/") {
            let bundle = path[..<range.lowerBound].split(separator: "/").last.map(String.init)
            if let bundle, !bundle.isEmpty { return bundle }
        }
        let isLocal = path.hasPrefix("/usr/local/") || path.hasPrefix("/opt/")
        if !isLocal, ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/"].contains(where: path.hasPrefix) {
            return "macOS"
        }
        let base = command.isEmpty ? (path as NSString).lastPathComponent : command
        let key = base.lowercased()
        if key.hasPrefix("python") { return "Python" }
        return friendlyNames[key] ?? base
    }

    // MARK: Dev servers

    private static let devCommands = ["node", "bun", "deno", "python", "ruby", "java", "php", "uvicorn", "gunicorn",
                                      "puma", "rails", "next-server", "vite", "esbuild", "hugo", "jekyll", "dotnet", "beam.smp"]

    /// Local servers the user started, found via lsof's listening TCP sockets.
    private func scanDevServers(processes: [Int32: ProcessSample]) -> [DevServer] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn", "+c", "0"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var servers: [Int32: DevServer] = [:]
        var pid: Int32 = 0, command = ""
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": command = value
            case "n":
                let lower = command.lowercased()
                guard Sampler.devCommands.contains(where: { lower.hasPrefix($0) }),
                      let port = value.split(separator: ":").last.flatMap({ Int($0) }) else { continue }
                var server = servers[pid] ?? DevServer(pid: pid, name: Sampler.appName(path: "", command: command),
                                                       folder: Sampler.workingFolder(pid), ports: [],
                                                       cpu: processes[pid]?.cpu ?? 0, memory: processes[pid]?.memory ?? 0)
                if !server.ports.contains(port) { server.ports.append(port) }
                servers[pid] = server
            default: break
            }
        }
        return servers.values.sorted { ($0.ports.first ?? 0) < ($1.ports.first ?? 0) }
    }

    private static func workingFolder(_ pid: Int32) -> String {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return "" }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return (path as NSString).lastPathComponent
    }

    // MARK: Audio and accessories

    private func readAudio() -> (playing: Bool, device: String?) {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            return (false, nil)
        }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running)
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
        return (running != 0, name?.takeRetainedValue() as String?)
    }

    /// Battery levels that Apple keyboards, mice and trackpads publish in the I/O Registry.
    private func readAccessoryBatteries() -> [(name: String, percent: Int)] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [String: Int] = [:]
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let percent = IORegistryEntryCreateCFProperty(entry, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int,
               let product = IORegistryEntryCreateCFProperty(entry, "Product" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                found[product] = percent
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return found.map { ($0.key, $0.value) }.sorted { $0.name < $1.name }
    }

    // MARK: sysctl

    static func sysctlInt64(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
