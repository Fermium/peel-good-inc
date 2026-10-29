import AppKit
import LabelKit
import ServiceManagement
import SwiftUI

/// A standard toolbar-style Settings window: one tab per pane, title follows the tab.
@MainActor
final class SettingsWindowController {
    private let store: Store
    private let testLabel: () -> Void
    private var window: NSWindow?

    init(store: Store, testLabel: @escaping () -> Void) {
        self.store = store
        self.testLabel = testLabel
    }

    /// Opens Settings, optionally on a tab by its title ("API").
    func show(tab title: String? = nil) {
        if window == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            tabs.addTabViewItem(tab("General", "gearshape", GeneralPane(store: store)))
            tabs.addTabViewItem(tab("Printers", "printer", PrintersPane(store: store, testLabel: testLabel)))
            tabs.addTabViewItem(tab("Rules", "list.bullet.rectangle", RulesSettingsView(store: store)))
            tabs.addTabViewItem(tab("Files", "doc", FilesPane(store: store)))
            tabs.addTabViewItem(tab("API", "point.3.connected.trianglepath.dotted", APIPane(api: .shared)))
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            window.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { AppWindows.settingsClosed() }
            }
            self.window = window
        }
        store.refresh()
        if let title, let tabs = window?.contentViewController as? NSTabViewController,
           let index = tabs.tabViewItems.firstIndex(where: { $0.label == title }) {
            tabs.selectedTabViewItemIndex = index
        }
        AppWindows.bringToFront(window)
    }

    private func tab<V: View>(_ title: String, _ symbol: String, _ view: V) -> NSTabViewItem {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize   // each tab sizes the window to fit
        let item = NSTabViewItem(viewController: host)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }
}

/// A menu bar app can't reliably come to the front, so it acts as a regular app
/// while any of its windows is open.
@MainActor
enum AppWindows {
    static func bringToFront(_ window: NSWindow?) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    static func settingsClosed() {
        DispatchQueue.main.async {
            let visible = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
            if !visible { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

// MARK: General

struct GeneralPane: View {
    @ObservedObject var store: Store
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Picker("Default printer", selection: Binding(
                    get: { store.printer?.name ?? "" },
                    set: { name in store.printer = store.eligiblePrinters.first { $0.name == name } }
                )) {
                    ForEach(store.eligiblePrinters, id: \.name) { p in
                        Text("\(p.displayName) · \(store.size(for: p).display)").tag(p.name)
                    }
                }
                Picker("Print after drop", selection: Binding(get: { store.alwaysReview ? -1 : store.countdown },
                                                              set: { v in store.alwaysReview = v < 0; if v >= 0 { store.countdown = v } })) {
                    Text("Immediately").tag(0.0)
                    Text("After 1.5 seconds").tag(1.5)
                    Text("After 3 seconds").tag(3.0)
                    Text("Ask first").tag(-1.0)
                }
            } footer: {
                Text("Hold a file over the icon to pick another printer. Hold ⌥ to preview first.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: Binding(get: { store.playSounds }, set: { store.playSounds = $0 })) {
                    HStack(spacing: 6) {
                        Button {
                            Sounds.play(Sounds.dropped, if: true)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { Sounds.play(Sounds.sent, if: true) }
                        } label: {
                            Image(systemName: "play.circle.fill").font(.title3)
                        }
                        .buttonStyle(.borderless)
                        .help("Play sounds")
                        Text("Play sounds")
                    }
                }
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                            NSAlert(error: error).runModal()
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 330)
    }
}

// MARK: Printers

struct PrintersPane: View {
    @ObservedObject var store: Store
    let testLabel: () -> Void
    @State private var selection: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(store.eligiblePrinters, id: \.name, selection: $selection) { p in
                    HStack {
                        Image(systemName: p.isLabelPrinter ? "printer.dotmatrix" : "photo").frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.displayName).lineLimit(1)
                            Text(p.name == store.printer?.name ? "Default · \(stateText(p))" : stateText(p))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(p.name)
                }
                Divider()
                HStack(spacing: 0) {
                    Button { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Print-Scan-Settings.extension")!) } label: {
                        Image(systemName: "plus").frame(width: 24, height: 20)
                    }
                    .help("Add a printer in System Settings")
                    Button { removeSelected() } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                        .disabled(selection == nil)
                        .help("Remove printer")
                    Spacer()
                    if !store.hiddenPrinters.isEmpty {
                        Button("Show Hidden") { store.hiddenPrinters = [] }.font(.caption)
                    }
                }
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(width: 210)
            Divider()
            if let p = store.eligiblePrinters.first(where: { $0.name == selection }) {
                PrinterDetail(store: store, printer: p, testLabel: testLabel).id(p.name)
            } else {
                Text("No printer selected").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 680, height: 500)
        .onAppear { selection = selection ?? store.printer?.name }
    }

    private func stateText(_ p: PrinterInfo) -> String {
        switch p.state {
        case .idle: "Ready"
        case .printing: "Printing"
        case .stopped: "Offline"
        case .unknown: "Unknown"
        }
    }

    /// Hide it from Labelize, or delete the print queue from the Mac.
    private func removeSelected() {
        guard let name = selection, let p = store.printers.first(where: { $0.name == name }) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(p.displayName)?"
        alert.informativeText = "Hiding keeps the printer on your Mac. Removing deletes it from every app."
        alert.addButton(withTitle: "Hide")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove from Mac…")
        alert.buttons[2].hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            store.hiddenPrinters.append(name)
        case .alertThirdButtonReturn:
            Task {
                do {
                    try await Task.detached { try PrinterRemoval.removeFromMac(name) }.value
                    Log.notice(.app, "removed printer \(name)")
                    store.refresh()
                    selection = store.printer?.name
                } catch {
                    Log.error(.app, "couldn't remove printer \(name): \(error.localizedDescription)")
                    NSAlert(error: error).runModal()
                }
            }
            return
        default:
            return
        }
        selection = store.printer?.name
    }
}

struct PrinterDetail: View {
    @ObservedObject var store: Store
    let printer: PrinterInfo
    let testLabel: () -> Void
    @State private var preview: NSImage?

    var body: some View {
        Form {
            Section {
                Picker("Label size", selection: Binding(get: { store.size(for: printer) }, set: { store.setSize($0, for: printer); refreshPreview() })) {
                    ForEach(SizeCatalog.entries(for: printer).filter(\.isSupported).map(\.size), id: \.self) { Text($0.display).tag($0) }
                }
                Picker("Scaling", selection: Binding(get: { store.fit(for: printer) }, set: { store.setFit($0, for: printer) })) {
                    Text("Fit").tag(FitMode.fit)
                    Text("Fill").tag(FitMode.fill)
                }
                .pickerStyle(.segmented)
            }
            if printer.isLabelPrinter {
                Section {
                    LabeledContent("Ink") {
                        HStack {
                            Picker("Ink", selection: Binding(get: { store.ink(for: printer) }, set: { store.setInk($0, for: printer); refreshPreview() })) {
                                Text("Auto").tag(InkMode.auto)
                                Text("Crisp").tag(InkMode.crisp)
                                Text("Photo").tag(InkMode.photo)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            HelpButton { InkCompareWindow.show(store: store, printer: printer) }
                        }
                    }
                    LabeledContent("Threshold") {
                        HStack {
                            Slider(value: Binding(get: { store.cutoff(for: printer) }, set: { store.setCutoff($0, for: printer) }),
                                   in: 0.2...0.8) { editing in if !editing { refreshPreview() } }
                            Text("\(Int(store.cutoff(for: printer) * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                    }
                    if let preview {
                        HStack {
                            Spacer()
                            ZoomablePreview(image: preview, title: "\(printer.displayName) · \(store.size(for: printer).display)")
                                .frame(height: 120)
                            Spacer()
                        }
                    }
                }
            }
            Section("Alignment") {
                LabeledContent("Horizontal offset") { mmField(\.x) }
                LabeledContent("Vertical offset") { mmField(\.y) }
                HStack {
                    Spacer()
                    Button("Print Test Label") {
                        store.printer = printer
                        testLabel()
                    }
                }
            }
            if printer.name != store.printer?.name {
                Button("Use as Default") { store.printer = printer }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshPreview)
    }

    private func mmField(_ axis: WritableKeyPath<CGPoint, CGFloat>) -> some View {
        let binding = Binding<Double>(
            get: { Double(store.nudge(for: printer)[keyPath: axis]) },
            set: { v in var n = store.nudge(for: printer); n[keyPath: axis] = CGFloat(v); store.setNudge(n, for: printer) }
        )
        return HStack(spacing: 4) {
            TextField("", value: binding, format: .number.precision(.fractionLength(1))).frame(width: 56).multilineTextAlignment(.trailing)
            Stepper("", value: binding, in: -10...10, step: 0.1).labelsHidden()
            Text("mm").foregroundStyle(.secondary)
        }
    }

    /// The sample label converted with this printer's settings.
    private func refreshPreview() {
        guard printer.isLabelPrinter else { return }
        var o = store.options(for: printer)
        o.crop = .none
        let size = o.size
        let page = InkSample.page(size: size, title: printer.displayName)
        Task.detached {
            let label = LabelComposer.compose(page, o)
            let image = label.bitmap.cgImage().map { NSImage(cgImage: $0, size: size.points) }
            await MainActor.run { preview = image }
        }
    }
}

// MARK: Files

struct FilesPane: View {
    @ObservedObject var store: Store
    @State private var historySummary = History.summary

    var body: some View {
        Form {
            Section("After printing") {
                Toggle("Add tag", isOn: Binding(get: { store.tagAfterPrint }, set: { store.tagAfterPrint = $0 }))
                if store.tagAfterPrint {
                    LabeledContent("Tag") {
                        HStack(spacing: 10) {
                            TextField("", text: Binding(get: { store.tagName }, set: { store.tagName = $0 })).frame(width: 120)
                            TagColorDots(color: Binding(get: { store.tagColor }, set: { store.tagColor = $0 }))
                        }
                    }
                }
                Picker("Then", selection: Binding(get: { store.afterPrintAction }, set: { store.afterPrintAction = $0 })) {
                    ForEach(AfterPrintAction.allCases) { Text($0.title).tag($0) }
                }
                switch store.afterPrintAction {
                case .rename:
                    LabeledContent("Suffix") {
                        TextField("", text: Binding(get: { store.renameSuffix }, set: { store.renameSuffix = $0 })).frame(width: 140)
                    }
                    LabeledContent("Example") {
                        Text("order-1459-label\(store.renameSuffix).pdf").foregroundStyle(.secondary)
                    }
                case .move:
                    LabeledContent("Folder") {
                        HStack {
                            Text(store.moveFolder?.lastPathComponent ?? "None").foregroundStyle(.secondary)
                            Button("Choose…", action: chooseFolder)
                        }
                    }
                case .leave, .trash:
                    EmptyView()
                }
            }
            Section {
                Picker("Keep printed labels", selection: Binding(get: { store.historyDays }, set: { store.historyDays = $0; History.prune(keepingDays: $0); historySummary = History.summary })) {
                    Text("1 day").tag(1)
                    Text("1 week").tag(7)
                    Text("1 month").tag(30)
                    Text("3 months").tag(90)
                    Text("1 year").tag(365)
                    Text("Forever").tag(0)
                }
                LabeledContent("Saved", value: historySummary)
                HStack {
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.open(Store.historyFolder) }
                    Button("Delete All…", role: .destructive, action: deleteHistory)
                }
            } footer: {
                Text("Copies of printed labels, used for Reprint Last Label.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 430)
        .onAppear { historySummary = History.summary }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK { store.moveFolder = panel.url }
    }

    private func deleteHistory() {
        let alert = NSAlert()
        alert.messageText = "Delete all printed labels?"
        alert.informativeText = "Reprint Last Label won't work until you print again."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        History.deleteAll()
        historySummary = History.summary
    }
}
