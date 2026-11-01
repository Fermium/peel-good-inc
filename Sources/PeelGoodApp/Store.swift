import AppKit
import Combine
import LabelKit
import PeelGoodCore

/// Remembered choices: the default printer, app behaviour, and per printer the label size,
/// scaling, ink and calibration. Observable so the Settings window stays in sync with the menu.
/// The values live in `AppSettings` (PeelGoodCore), which the command line reads too; printer choice
/// is `PrinterResolver`'s, as it is for the API and the CLI.
@MainActor
final class Store: ObservableObject {
    let settings: AppSettings
    @Published private(set) var printers: [PrinterInfo] = []

    private var refreshing = false

    /// The first list is read synchronously so the app starts with printers.
    init(settings: AppSettings = .userDefaults(.standard)) {
        self.settings = settings
        printers = settings.printers()
    }

    /// Asking CUPS can take seconds (it contacts each printer), so refresh in the background
    /// and keep showing the last list meanwhile.
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            let settings = settings
            let fresh = await Task.detached(priority: .userInitiated) { settings.printers(zebraStatus: settings.zebraStatus()) }.value
            refreshing = false
            if fresh.map(\.name) != printers.map(\.name) || fresh.map(\.state) != printers.map(\.state)
                || fresh.map(\.presets.count) != printers.map(\.presets.count) || fresh.map(\.problem) != printers.map(\.problem)
                || fresh.map(\.zebraLinks) != printers.map(\.zebraLinks) || fresh.map(\.zebraUSBAttached) != printers.map(\.zebraUSBAttached) {
                printers = fresh
            }
        }
    }

    var resolver: PrinterResolver { PrinterResolver(printers: printers, settings: settings) }

    /// Printers that can take a 4x6 or smaller label and aren't hidden: label printers first.
    var eligiblePrinters: [PrinterInfo] { resolver.eligible }

    /// The printer plain drops go to: the one chosen in the menu or Settings, else the label printer,
    /// else the first that takes 4x6. Never a hidden one.
    var printer: PrinterInfo? {
        get { resolver.defaultPrinter }
        set { change { settings.printerName = newValue?.name } }
    }

    // MARK: Behaviour

    /// Seconds between dropping and printing; 0 prints immediately.
    var countdown: Double {
        get { settings.countdown }
        set { change { settings.countdown = newValue } }
    }

    /// General > Before printing: Show preview.
    var alwaysReview: Bool {
        get { settings.alwaysReview }
        set { change { settings.alwaysReview = newValue } }
    }

    /// Rules > New files: what happens to files that turn up in a watched folder when no rule
    /// says otherwise. Ask posts a notification with Print and Preview.
    var newFilesAction: RuleAction {
        get { settings.newFilesAction }
        set { change { settings.newFilesAction = newValue } }
    }

    var playSounds: Bool {
        get { settings.playSounds }
        set { change { settings.playSounds = newValue } }
    }

    /// Settings > General: the "Peel Good Inc." printer. Adding or removing its queue can fail
    /// (a standard user needs an administrator); the switch then goes back.
    var virtualPrinter: Bool {
        get { settings.virtualPrinter }
        set {
            change { settings.virtualPrinter = newValue }
            let done: @MainActor (Error?) -> Void = { [weak self] error in
                guard let error else { return }
                self?.change { self?.settings.virtualPrinter = !newValue }
                NSAlert(error: error).runModal()
            }
            if newValue { VirtualPrinterController.shared.start(done: done) } else { VirtualPrinterController.shared.stop(done: done) }
        }
    }

    /// Settings > General: "Print Label with Peel Good Inc." in the Print dialog's PDF menu.
    /// Lives in ~/Library/PDF Services, not in the settings.
    var showInPrintDialog: Bool {
        get { PDFServices.isInstalled() }
        set {
            change {
                do {
                    if newValue, let app = PDFServices.app { try PDFServices.install(app: app) } else if !newValue { try PDFServices.remove() }
                    Log.notice(.app, "\(newValue ? "added" : "removed") “\(PDFServices.title)” in the PDF menu")
                } catch {
                    Log.error(.app, "couldn't change the PDF menu item: \(error.localizedDescription)")
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    // MARK: Zebras

    /// Settings > General: look for Zebras on the network at launch.
    var scanForZebras: Bool {
        get { settings.scanForZebras }
        set { change { settings.scanForZebras = newValue } }
    }

    func addZebra(_ profile: Zebra.Profile) {
        change { settings.remember(profile) }
        printers = settings.printers(cups: printers.filter { !$0.speaksZPL })
        refresh()
    }

    func setZebraConnection(_ connection: Zebra.Connection, named name: String) {
        guard var zebra = settings.zebra(named: name) else { return }
        zebra.prefers = connection
        addZebra(zebra)
    }

    func forgetZebra(named name: String) {
        change { settings.forgetZebra(named: name) }
        printers.removeAll { $0.name == name }
    }

    func ignoreZebra(_ discoveryID: String) {
        change { settings.ignoredZebras.append(discoveryID) }
    }

    /// Printers removed from the app's lists (they stay installed on the Mac).
    var hiddenPrinters: [String] {
        get { settings.hiddenPrinters }
        set { change { settings.hiddenPrinters = newValue } }
    }

    // MARK: Files

    /// Days to keep saved prints; 0 keeps them forever.
    var historyDays: Int {
        get { settings.historyDays }
        set { change { settings.historyDays = newValue } }
    }

    var tagAfterPrint: Bool {
        get { settings.tagAfterPrint }
        set { change { settings.tagAfterPrint = newValue } }
    }

    var tagName: String {
        get { settings.tagName }
        set { change { settings.tagName = newValue } }
    }

    var tagColor: FinderTag.Color {
        get { settings.tagColor }
        set { change { settings.tagColor = newValue } }
    }

    var afterPrintAction: AfterPrintAction {
        get { settings.afterPrintAction }
        set { change { settings.afterPrintAction = newValue } }
    }

    var renameSuffix: String {
        get { settings.renameSuffix }
        set { change { settings.renameSuffix = newValue } }
    }

    var moveFolder: URL? {
        get { settings.moveFolder }
        set { change { settings.moveFolder = newValue } }
    }

    // MARK: Per printer

    /// The saved size if the printer takes it, else 4x6 (see `AppSettings.options(for:)`).
    func size(for p: PrinterInfo) -> LabelSize { settings.options(for: p).options.size }
    func setSize(_ size: LabelSize, for p: PrinterInfo) { change { settings.setSize(size, for: p.name) } }

    func fit(for p: PrinterInfo) -> FitMode { settings.savedFit(p.name) ?? .fit }
    func setFit(_ fit: FitMode, for p: PrinterInfo) { change { settings.setFit(fit, for: p.name) } }

    func ink(for p: PrinterInfo) -> InkMode { settings.savedInk(p.name) ?? .auto }
    func setInk(_ ink: InkMode, for p: PrinterInfo) { change { settings.setInk(ink, for: p.name) } }

    /// 0...1 black/white cutoff.
    func cutoff(for p: PrinterInfo) -> Double { settings.savedCutoff(p.name) ?? AppSettings.Default.cutoff }
    func setCutoff(_ v: Double, for p: PrinterInfo) { change { settings.setCutoff(v, for: p.name) } }

    /// Calibration shift in mm (+x right, +y down).
    func nudge(for p: PrinterInfo) -> CGPoint { settings.savedNudge(p.name) ?? .zero }
    func setNudge(_ v: CGPoint, for p: PrinterInfo) { change { settings.setNudge(v, for: p.name) } }

    /// Dot gain for photo and halftone; LabelKit's default unless set.
    func toneGamma(for p: PrinterInfo) -> Double { settings.savedToneGamma(p.name) ?? LabelOptions().toneGamma }
    func setToneGamma(_ v: Double, for p: PrinterInfo) { change { settings.setToneGamma(v, for: p.name) } }

    func options(for p: PrinterInfo) -> LabelOptions { settings.options(for: p).options }

    // MARK: Last print

    typealias LastPrint = AppSettings.LastPrint

    var lastPrint: LastPrint? {
        get { settings.lastPrint }
        set { change { settings.lastPrint = newValue } }
    }

    private func change(_ apply: () -> Void) {
        objectWillChange.send()
        apply()
    }

    /// Where printed labels are kept, for reprinting later.
    nonisolated static var historyFolder: URL { History.folder }
}

/// A soft pop when a file lands, a two-note chirp when the label is sent.
@MainActor
enum Sounds {
    static let dropped = load("pop")
    static let sent = load("sent")

    static func play(_ sound: NSSound?, if enabled: Bool) {
        guard enabled, let sound else { return }
        sound.stop()
        sound.play()
    }

    private static func load(_ name: String) -> NSSound? {
        Bundle.main.url(forResource: name, withExtension: "wav").flatMap { NSSound(contentsOf: $0, byReference: true) }
    }
}
