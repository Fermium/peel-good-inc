import AppKit
import LabelKit
import PeelGoodCore
import ServiceManagement
import SwiftUI

/// A standard toolbar-style Settings window: one tab per pane, title follows the tab.
@MainActor
final class SettingsWindowController {
    private let store: Store
    private let testLabel: (PrinterInfo) -> Void
    private var window: NSWindow?

    init(store: Store, testLabel: @escaping (PrinterInfo) -> Void) {
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
            tabs.addTabViewItem(tab("API", "point.3.connected.trianglepath.dotted", APIPane(api: .shared)))
            tabs.addTabViewItem(tab("CLI", "terminal", CLIPane()))
            tabs.addTabViewItem(tab("About", "info.circle", AboutView()))
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
        host.title = title   // the window shows the selected tab's title
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

/// Default printer, what happens before and after printing, and the saved labels.
/// A text field that saves only what `tidy` allows (`Limits.tidyTagName`, `Limits.tidyRenameSuffix`), the same
/// rules MCP checks. While you type it shows your text; when you leave it, it shows what was saved.
struct TidyTextField: View {
    @Binding var value: String
    let tidy: (String) -> String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .focused($focused)
            .onAppear { text = value }
            .onChange(of: text) { _, new in
                let saved = tidy(new)
                if saved != value { value = saved }
                // Show at once what was dropped (a / or :, or past the length limit); a cleared field stays empty until you leave it.
                if !new.trimmingCharacters(in: .whitespaces).isEmpty, saved != new { text = saved }
            }
            .onChange(of: focused) { _, isFocused in if !isFocused { text = value } }
            .onChange(of: value) { _, new in if !focused { text = new } }
            .onSubmit { text = value }
    }
}

struct GeneralPane: View {
    @ObservedObject var store: Store
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var historySummary = History.summary()

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
                Picker("Before printing", selection: Binding(get: { store.alwaysReview ? -1 : store.countdown },
                                                             set: { v in store.alwaysReview = v < 0; if v >= 0 { store.countdown = v } })) {
                    // Limits' choices, plus a value MCP set that isn't one of them.
                    ForEach(Limits.choices(Limits.countdownChoices, including: store.countdown), id: \.self) { v in
                        Text(Limits.countdownTitle(v)).tag(v)
                    }
                    Text("Show preview").tag(-1.0)
                }
            } footer: {
                Text("Hold a file over the icon to pick another printer. Hold ⌥ to show the preview.")
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
                Toggle(isOn: Binding(get: { store.virtualPrinter }, set: { store.virtualPrinter = $0 })) {
                    Text("Add a Peel Good Inc. printer")
                    Text("Any app can print to it, and each document follows your rules. Works while Peel Good is open.")
                }
                Toggle(isOn: Binding(get: { store.showInPrintDialog }, set: { store.showInPrintDialog = $0 })) {
                    Text("Show in the Print dialog's PDF menu")
                    Text("Adds “\(PDFServices.title)” to the PDF menu.")
                }
                .disabled(PDFServices.app == nil)
                Toggle("Look for Zebra printers when Peel Good starts",
                       isOn: Binding(get: { store.scanForZebras }, set: { store.scanForZebras = $0 }))
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
            Section("After Printing") {
                Toggle("Add Finder tag", isOn: Binding(get: { store.tagAfterPrint }, set: { store.tagAfterPrint = $0 }))
                if store.tagAfterPrint {
                    LabeledContent("Tag") {
                        HStack(spacing: 10) {
                            TidyTextField(value: Binding(get: { store.tagName }, set: { store.tagName = $0 }),
                                          tidy: { Limits.tidyTagName($0, previous: store.tagName) })
                                .frame(width: 120)
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
                        TidyTextField(value: Binding(get: { store.renameSuffix }, set: { store.renameSuffix = $0 }), tidy: Limits.tidyRenameSuffix)
                            .frame(width: 140)
                    }
                    LabeledContent("Example") {
                        Text("order-1234-label\(store.renameSuffix).pdf").foregroundStyle(.secondary)
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
                Picker("Keep printed labels", selection: Binding(get: { store.historyDays }, set: { store.historyDays = $0; History.prune(keepingDays: $0); historySummary = History.summary() })) {
                    ForEach(Limits.choices(Limits.historyChoices, including: store.historyDays, keepLast: 0), id: \.self) { d in
                        Text(Limits.historyTitle(d)).tag(d)
                    }
                }
                LabeledContent("Saved", value: historySummary)
                HStack {
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.open(Store.historyFolder) }
                    Button("Delete All…", role: .destructive, action: deleteHistory)
                }
            } header: {
                Text("History")
            } footer: {
                Text("Copies of printed labels, used for Reprint Last Label.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 610)
        .onAppear { historySummary = History.summary() }
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
        historySummary = History.summary()
    }
}

// MARK: Printers

struct PrintersPane: View {
    @ObservedObject var store: Store
    let testLabel: (PrinterInfo) -> Void
    @State private var selection: String?
    @State private var addingZebra = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(store.eligiblePrinters, id: \.name, selection: $selection) { p in
                    HStack {
                        Image(systemName: p.isLabelPrinter ? "printer.dotmatrix" : "photo").frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.displayName).lineLimit(1)
                            Text(p.name == store.printer?.name ? "Default · \(p.statusText)" : p.statusText)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(p.name)
                }
                Divider()
                HStack(spacing: 0) {
                    Menu {
                        Button("Add Zebra Printer…") { addingZebra = true }
                        Button("Add Printer in System Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Print-Scan-Settings.extension")!)
                        }
                    } label: {
                        Image(systemName: "plus").frame(width: 24, height: 20)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add a printer")
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
        .sheet(isPresented: $addingZebra) {
            AddZebraSheet(store: store) { added in
                addingZebra = false
                if let added { selection = added.name }
            }
        }
    }

    /// Hide it from Peel Good Inc., or delete the print queue from the Mac.
    private func removeSelected() {
        guard let name = selection, let p = store.printers.first(where: { $0.name == name }) else { return }
        if p.zebraHost != nil {
            let alert = NSAlert()
            alert.messageText = "Forget \(p.displayName)?"
            alert.informativeText = "Peel Good Inc. stops printing to it and forgets its settings here. The printer isn't changed."
            alert.addButton(withTitle: "Forget")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            store.forgetZebra(named: name)
            selection = store.printer?.name
            return
        }
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
    let testLabel: (PrinterInfo) -> Void
    @State private var preview: NSImage?
    @State private var showAdvanced = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Label size") {
                    SizePopUp(selection: Binding(get: { store.size(for: printer) }, set: { store.setSize($0, for: printer); refreshPreview() }),
                              sizes: SizeCatalog.entries(for: printer).filter(\.isSupported).map(\.size))
                }
                Picker("Scaling", selection: Binding(get: { store.fit(for: printer) }, set: { store.setFit($0, for: printer) })) {
                    ForEach(FitMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if printer.isLabelPrinter {
                Section {
                    LabeledContent("Ink") {
                        HStack {
                            Picker("Ink", selection: Binding(get: { store.ink(for: printer) }, set: { store.setInk($0, for: printer); refreshPreview() })) {
                                ForEach(InkMode.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            HelpButton { InkCompareWindow.show(store: store, printer: printer) }
                        }
                    }
                    LabeledContent("Threshold") {
                        HStack {
                            Slider(value: Binding(get: { store.cutoff(for: printer) }, set: { store.setCutoff($0, for: printer) }),
                                   in: Limits.cutoff) { editing in if !editing { refreshPreview() } }
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
            if let host = printer.zebraHost {
                Section("Zebra") {
                    LabeledContent("Address") {
                        // The printer's own web page: its settings, status and configuration label.
                        if let url = URL(string: "http://\(host)") { Link(host, destination: url) } else { Text(host) }
                    }
                    if let dpi = printer.dpi { LabeledContent("Resolution", value: "\(Int(dpi.rounded())) dpi (\(Int((dpi / 25.4).rounded())) dots/mm)") }
                    LabeledContent("Status", value: printer.statusText)
                }
                ZebraSettingsSection(printer: printer, host: host)
            }
            Section(isExpanded: $showAdvanced) {
                LabeledContent("Horizontal offset") { mmField(\.x) }
                LabeledContent("Vertical offset") { mmField(\.y) }
                if printer.zebraHost != nil {
                    HStack {
                        Text("The offset applies to Peel Good's labels. The printer can store it for every app.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Move to Printer…") { ZebraSetup.moveCalibrationToPrinter(printer, store: store) }
                            .disabled(store.nudge(for: printer) == .zero)
                    }
                }
            } header: {
                Text("Advanced")
            }
            Section {
                HStack {
                    if printer.name != store.printer?.name {
                        Button("Use as Default") { store.printer = printer }
                    }
                    Spacer()
                    Button("Print Test Label") { testLabel(printer) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // A calibrated printer shows its offset (and, for a Zebra, the move to the printer).
            if store.nudge(for: printer) != .zero { showAdvanced = true }
            refreshPreview()
        }
    }

    private func mmField(_ axis: WritableKeyPath<CGPoint, CGFloat>) -> some View {
        NumberField(value: Binding(
            get: { Double(store.nudge(for: printer)[keyPath: axis]) },
            set: { v in var n = store.nudge(for: printer); n[keyPath: axis] = CGFloat(v); store.setNudge(Limits.clampNudge(n), for: printer) }
        ), range: Limits.nudgeMM, step: 0.1, decimals: 1, unit: "mm")
    }

    /// The sample label converted with this printer's settings.
    private func refreshPreview() {
        guard printer.isLabelPrinter else { return }
        var o = store.options(for: printer)
        o.crop = .none
        let size = o.size
        let page = TestLabel.inkSample.page(size: size, title: printer.displayName)
        Task.detached {
            let label = LabelComposer.compose(page, o)
            let image = label.bitmap.cgImage().map { NSImage(cgImage: $0, size: size.points) }
            await MainActor.run { preview = image }
        }
    }
}

/// Settings > Printers > + > Add Zebra Printer: the Zebras on the network, or one typed by address.
struct AddZebraSheet: View {
    @ObservedObject var store: Store
    let done: (PrinterInfo?) -> Void
    @State private var found: [ZebraCandidate] = []
    @State private var scanning = true
    @State private var host = ""
    @State private var adding = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Zebra Printer").font(.headline)
            Text("Peel Good Inc. prints to Zebras on your network directly, in ZPL.")
                .font(.callout).foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    if scanning {
                        HStack { ProgressView().controlSize(.small); Text("Looking on your network…").foregroundStyle(.secondary) }
                    } else if found.isEmpty {
                        Text("No Zebras answered. Type the printer's address below.").foregroundStyle(.secondary)
                    }
                    ForEach(found, id: \.found.host) { c in
                        let f = c.found, known = store.settings.knownZebra(for: f) != nil
                        HStack {
                            Image(systemName: "printer.dotmatrix")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.displayName)
                                Text("\(f.host) · \(f.systemName)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(known ? "Added" : "Add") { add(f.host, discoveryID: f.serial) }.disabled(known || adding)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                .padding(4)
            }
            HStack {
                TextField("Address, e.g. 192.168.1.50", text: $host).onSubmit { add(host) }
                Button("Add") { add(host) }.disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || adding)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                if adding { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { done(nil) }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task { await scan() }
    }

    private func scan() async {
        let settings = store.settings
        found = await Task.detached(priority: .userInitiated) { settings.scanZebras() }.value
        scanning = false
    }

    private func add(_ host: String, discoveryID: String? = nil) {
        adding = true
        error = nil
        Task {
            do {
                done(try await ZebraSetup.add(host: host, discoveryID: discoveryID, store: store))
            } catch {
                self.error = "\(error)"
            }
            adding = false
        }
    }
}

/// A number in Settings: an editable value, arrows and its unit, the same everywhere.
struct NumberField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step = 1.0
    var decimals = 0
    var unit: String?

    var body: some View {
        HStack(spacing: 4) {
            TextField("", value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) }),
                      format: .number.precision(.fractionLength(decimals)))
                .frame(width: 56).multilineTextAlignment(.trailing)
            Stepper("", value: $value, in: range, step: step).labelsHidden()
            // The unit column is kept even when empty, so arrows line up from row to row.
            Text(unit ?? "").foregroundStyle(.secondary).frame(minWidth: 28, alignment: .leading)
        }
    }
}
