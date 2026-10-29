import AppKit
import SwiftUI

@MainActor
enum LogWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: LogView()))
            w.title = "Peel Good Inc. Logs"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.setContentSize(NSSize(width: 900, height: 520))
            w.isReleasedWhenClosed = false
            w.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { AppWindows.settingsClosed() }
            }
            window = w
        }
        AppWindows.bringToFront(window)
    }
}

/// The log file as a live, filterable table.
struct LogView: View {
    @State private var entries: [Log.Entry] = []
    @State private var search = ""
    @State private var minimum: Log.Level = .info
    @State private var category = "all"
    @State private var follow = true
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var shown: [Log.Entry] {
        entries.filter { e in
            e.level >= minimum && (category == "all" || e.category == category)
                && (search.isEmpty || e.message.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Level", selection: $minimum) {
                    ForEach(Log.Level.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .fixedSize()
                Picker("Category", selection: $category) {
                    Text("All").tag("all")
                    ForEach(Log.Category.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0.rawValue) }
                }
                .fixedSize()
                Toggle("Follow", isOn: $follow).toggleStyle(.checkbox)
                Spacer()
                Button("Copy") {
                    let text = shown.map { "\($0.time)  \($0.level.tag)  \($0.category)  \($0.message)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL]) }
                Button("Clear") { Log.clear(); entries = [] }
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                List(shown) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(e.time.dropFirst(11)).foregroundStyle(.secondary)
                        Text(e.level.tag.trimmingCharacters(in: .whitespaces))
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(color(e.level).opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(color(e.level))
                            .frame(width: 58, alignment: .leading)
                        Text(e.category).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                        Text(e.message).textSelection(.enabled)
                    }
                    .font(.system(.callout, design: .monospaced))
                    .id(e.id)
                }
                .listStyle(.plain)
                .onChange(of: entries.count) {
                    if follow, let last = shown.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .searchable(text: $search, placement: .toolbar)
        .onAppear { entries = Log.readEntries() }
        .onReceive(timer) { _ in
            let fresh = Log.readEntries()
            if fresh.count != entries.count || fresh.last?.message != entries.last?.message { entries = fresh }
        }
    }

    private func color(_ level: Log.Level) -> Color {
        switch level {
        case .debug: .gray
        case .info: .blue
        case .notice: .teal
        case .warning: .orange
        case .error: .red
        }
    }
}
