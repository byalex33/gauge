import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(Monitor.self) private var monitor
    @State private var sheet: SheetKind?
    /// The island's selected page: "Overview", a metric name, or "Projects".
    @State private var page = "Overview"
    @State private var width: CGFloat = 1200
    @State private var exporting = false
    @AppStorage("chartBars") private var bars = false

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        ZStack(alignment: .topLeading) {
                            Color.clear.frame(height: 0).id("top")
                            current
                                .id(page)
                                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 12)), removal: .opacity))
                        }
                        .frame(maxWidth: 1320, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                        .padding(.horizontal, width < 700 ? 20 : 40)
                        .padding(.bottom, 140)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollIndicators(.automatic)
                    .onChange(of: page) { proxy.scrollTo("top", anchor: .top) }
                }
                StatusBar(monitor: monitor) { sheet = .privacy }
            }
            Island(selection: page, select: select, compact: width < 600)
                .padding(.bottom, 44)
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.ink)
        .background {
            // Esc returns to the overview from any page.
            Button("Back to Overview") { select("Overview") }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .accessibilityHidden(true)
        }
        .sheet(item: $sheet) { SheetView(kind: $0) }
        .fileExporter(isPresented: $exporting, document: CSVDocument(text: monitor.csv()),
                      contentType: .commaSeparatedText, defaultFilename: "Gauge history") { _ in }
        .onReceive(NotificationCenter.default.publisher(for: .gaugeExport)) { _ in exporting = true }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 9) {
                    GaugeMark(size: 20)
                    Text("Gauge").font(.system(size: 14, weight: .semibold))
                    Rectangle().fill(Theme.line2).frame(width: 1, height: 14).padding(.horizontal, 6)
                    Text(monitor.ready ? "Live" : "Starting").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 4)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                SettingsLink { Image(systemName: "gearshape") }.help("Settings")
            }
        }
    }

    @ViewBuilder private var current: some View {
        switch page {
        case "Overview":
            OverviewPage(monitor: monitor, width: width, bars: $bars, export: { exporting = true },
                         open: { sheet = $0 }, select: select)
        case "Projects":
            ProjectsPage(monitor: monitor) { select("Overview") }
        default:
            DetailPage(name: page, monitor: monitor, width: width) { select("Overview") }
        }
    }

    private func select(_ name: String) {
        guard name != page else { return }
        withAnimation(.smooth(duration: 0.32)) { page = name }
    }
}


/// The overview content: title block and the five sections. Shared by the window and snapshots.
struct OverviewPage: View {
    var monitor: Monitor
    var width: CGFloat
    @Binding var bars: Bool
    var export: () -> Void
    var open: (SheetKind) -> Void
    var select: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            intro
            if monitor.ready {
                sections
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 300)
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Overview").font(.system(size: 30, weight: .semibold)).tracking(-0.75)
                    Text(monitor.machine).font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                Spacer()
                HStack(spacing: 8) {
                    Segmented(options: [(true, "Bar charts", "chart.bar"), (false, "Line charts", "chart.xyaxis.line")],
                              selection: $bars, accessibilityName: "Chart style")
                    Button(action: export) { Label("Export", systemImage: "square.and.arrow.up") }
                        .buttonStyle(QuietButtonStyle())
                        .help("Export history as CSV")
                }
            }
            HStack(spacing: 22) {
                ForEach(monitor.status) { item in
                    HStack(spacing: 8) { LED(on: item.on); Text(item.text) }
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.soft)
            .padding(.top, 14)
        }
        .padding(.top, 28)
        .padding(.bottom, 30)
    }

    @ViewBuilder private var sections: some View {
        VitalsSection(vitals: monitor.vitals, width: width, bars: bars) { select($0) }
        NoticesSection(monitor: monitor, width: width) { select($0) }
            .padding(.top, 64)
        BreakdownsSection(breakdowns: monitor.breakdowns, width: width) { open(.processes) }
            .padding(.top, 64)
        HardwareSection(cards: monitor.hardware, width: width)
            .padding(.top, 64)
        HistorySection(monitor: monitor, width: width, bars: bars)
            .padding(.top, 64)
    }

}

extension Notification.Name {
    static let gaugeExport = Notification.Name("GaugeExport")
}

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
