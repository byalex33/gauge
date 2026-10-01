import SwiftUI

enum SheetKind: String, Identifiable {
    case processes, privacy
    var id: String { rawValue }
}

struct SheetView: View {
    var kind: SheetKind
    @Environment(Monitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 18, weight: .semibold))
                Text(kicker).font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }
            .padding(.bottom, 14)
            Hairline()
            content.padding(.top, 16)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(QuietButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 20)
        }
        .padding(24)
        .frame(width: 560)
        .background(Theme.raise)
        .onExitCommand { dismiss() }
    }

    private var title: String {
        switch kind {
        case .processes: "Processes"
        case .privacy: "Privacy"
        }
    }

    private var kicker: String {
        switch kind {
        case .processes: "Right now · your apps"
        case .privacy: "Gauge"
        }
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .processes: ProcessesView(apps: monitor.apps)
        case .privacy:
            Text("Gauge reads system counters on this Mac, such as CPU load, memory, disk and network activity. Readings are saved to a history file in ~/Library/Application Support/Gauge. Nothing is uploaded: Gauge makes no network connections, has no analytics and no account. You can change how long history is kept, or clear it, in Settings.")
                .font(.system(size: 13.5)).foregroundStyle(Theme.soft).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ProcessesView: View {
    var apps: [AppUsage]
    @State private var query = ""
    @State private var order = [KeyPathComparator(\AppUsage.cpu, order: .reverse)]

    private var rows: [AppUsage] {
        apps.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.sorted(using: order)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Find a process", text: $query).textFieldStyle(.roundedBorder)
            Table(rows, sortOrder: $order) {
                TableColumn("App", value: \.name)
                TableColumn("CPU", value: \.cpu) { Text(String(format: "%.1f%%", $0.cpu)).font(Theme.mono(12)) }
                    .width(80)
                TableColumn("Memory", value: \.memory) { Text(Fmt.memoryText($0.memory)).font(Theme.mono(12)) }
                    .width(96)
            }
            .frame(height: 320)
            .overlay { if rows.isEmpty { Text("No matching processes.").foregroundStyle(Theme.muted) } }
            Text("Apps group their helper processes. CPU percentages are per core. Processes owned by other users need administrator access, so they appear only in the memory total as \"Other & system\".")
                .font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ProjectsView: View {
    var servers: [DevServer]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if servers.isEmpty {
                Text("No local dev servers are listening right now. Gauge looks for Node, Python, Ruby, Bun, Deno and similar processes with open TCP ports.")
                    .font(.system(size: 13.5)).foregroundStyle(Theme.soft).fixedSize(horizontal: false, vertical: true)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        Text("Server"); Text("Folder"); Text("Port").gridColumnAlignment(.trailing)
                        Text("Memory").gridColumnAlignment(.trailing); Text("State").gridColumnAlignment(.trailing)
                    }
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(servers) { server in
                        GridRow {
                            Text(server.name)
                            Text(server.folder.isEmpty ? "–" : server.folder).foregroundStyle(Theme.soft).lineLimit(1)
                            Text(server.ports.map(String.init).joined(separator: ", ")).font(Theme.mono(12.5))
                            Text(Fmt.memoryText(server.memory)).font(Theme.mono(12.5))
                            Text(server.idle ? "Idle" : "Active").foregroundStyle(server.idle ? Theme.muted : Theme.ink)
                        }
                        .font(.system(size: 13))
                    }
                }
            }
            Text("Gauge only lists these servers. It doesn't stop or change them.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
        }
    }
}
