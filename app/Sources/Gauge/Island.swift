import SwiftUI

/// Floating category navigation, centred above the status bar. ⌘1–⌘8 select tabs.
struct Island: View {
    var selection: String
    var select: (String) -> Void
    var compact: Bool
    @Namespace private var namespace

    static func symbol(_ tab: String) -> String {
        switch tab {
        case "CPU": "cpu"
        case "Memory": "memorychip"
        case "Disk": "internaldrive"
        case "Network": "network"
        case "GPU": "square.stack.3d.up"
        case "Battery": "battery.75percent"
        case "Projects": "folder"
        default: "square.grid.2x2"
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(Monitor.tabs.enumerated()), id: \.element) { index, tab in
                let selected = tab == selection
                Button { select(tab) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: Self.symbol(tab)).font(.system(size: 13.5))
                        if selected && !compact {
                            Text(tab).font(.system(size: 13, weight: .medium)).fixedSize()
                                .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .leading)))
                        }
                    }
                    .padding(.horizontal, compact ? 9 : 11)
                    .frame(height: 36)
                    .foregroundStyle(selected ? Theme.bg : Theme.muted)
                    .background {
                        if selected { Capsule().fill(Theme.tone(tab)).matchedGeometryEffect(id: "pill", in: namespace) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .help("\(tab)  ⌘\(index + 1)")
                .accessibilityLabel(tab)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Capsule().fill(Color(hex: 0x1A1A18)))
        .overlay(Capsule().strokeBorder(Theme.line2))
        .shadow(color: .black.opacity(0.5), radius: 16, y: 12)
        .animation(.spring(duration: 0.38, bounce: 0.12), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("System categories")
    }
}

struct StatusBar: View {
    var monitor: Monitor
    var showPrivacy: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 12) {
                Text("\(monitor.appCount) apps · \(monitor.processCount) processes")
                Button("Privacy", action: showPrivacy).buttonStyle(.plain).foregroundStyle(Theme.muted)
                Spacer()
                HStack(spacing: 7) {
                    Circle().fill(monitor.ready ? Theme.ink : Theme.faint).frame(width: 5, height: 5)
                    Text(monitor.ready ? "Live" : "Starting")
                }
                Text("·")
                Text("History stays on your Mac")
            }
            .font(Theme.mono(11))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 32)
            .padding(.vertical, 7)
        }
        .background(Theme.bg)
    }
}
