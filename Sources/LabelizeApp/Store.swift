import AppKit
import Combine
import LabelKit

/// Remembered choices: the default printer, app behaviour, and per printer the label size,
/// scaling, ink and calibration. Observable so the Settings window stays in sync with the menu.
@MainActor
final class Store: ObservableObject {
    private let defaults = UserDefaults.standard
    @Published private(set) var printers: [PrinterInfo] = []

    private var refreshing = false

    /// The first list is read synchronously so the app starts with printers.
    init() { printers = Printers.all() }

    /// Asking CUPS can take seconds (it contacts each printer), so refresh in the background
    /// and keep showing the last list meanwhile.
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            let fresh = await Task.detached(priority: .userInitiated) { Printers.all() }.value
            refreshing = false
            if fresh.map(\.name) != printers.map(\.name) || fresh.map(\.state) != printers.map(\.state)
                || fresh.map(\.presets.count) != printers.map(\.presets.count) {
                printers = fresh
            }
        }
    }

    /// Printers that can take a 4x6 or smaller label and aren't hidden: label printers first.
    var eligiblePrinters: [PrinterInfo] {
        printers.filter { $0.resolve(.fourBySix) != nil && !hiddenPrinters.contains($0.name) }
            .sorted { ($0.isLabelPrinter ? 0 : 1, $0.name) < ($1.isLabelPrinter ? 0 : 1, $1.name) }
    }

    /// The printer plain drops go to: the one chosen in the menu or Settings, else the
    /// system default label printer.
    var printer: PrinterInfo? {
        get {
            let name = defaults.string(forKey: "printer")
            return eligiblePrinters.first { $0.name == name } ?? Printers.defaultLabelPrinter(in: printers) ?? eligiblePrinters.first
        }
        set { set(newValue?.name, "printer") }
    }

    // MARK: Behaviour

    /// Seconds between dropping and printing; 0 prints immediately.
    var countdown: Double {
        get { defaults.object(forKey: "countdown") as? Double ?? 1.5 }
        set { set(newValue, "countdown") }
    }

    /// General > Before printing: Show preview.
    var alwaysReview: Bool {
        get { defaults.bool(forKey: "alwaysReview") }
        set { set(newValue, "alwaysReview") }
    }

    /// Rules > New files: what happens to files that turn up in a watched folder when no rule
    /// says otherwise. Ask posts a notification with Print and Preview.
    var newFilesAction: RuleAction {
        get { RuleAction(rawValue: defaults.string(forKey: "newFilesAction") ?? "") ?? .ask }
        set { set(newValue.rawValue, "newFilesAction") }
    }

    var playSounds: Bool {
        get { defaults.object(forKey: "playSounds") as? Bool ?? true }
        set { set(newValue, "playSounds") }
    }

    /// Printers removed from Labelize's lists (they stay installed on the Mac).
    var hiddenPrinters: [String] {
        get { defaults.stringArray(forKey: "hiddenPrinters") ?? [] }
        set { set(newValue, "hiddenPrinters") }
    }

    // MARK: Files

    /// Days to keep saved prints; 0 keeps them forever.
    var historyDays: Int {
        get { defaults.object(forKey: "historyDays") as? Int ?? 30 }
        set { set(newValue, "historyDays") }
    }

    var tagAfterPrint: Bool {
        get { defaults.object(forKey: "tagAfterPrint") as? Bool ?? true }
        set { set(newValue, "tagAfterPrint") }
    }

    var tagName: String {
        get { defaults.string(forKey: "tagName") ?? "Printed" }
        set { set(newValue, "tagName") }
    }

    var tagColor: FinderTag.Color {
        get { FinderTag.Color(rawValue: defaults.object(forKey: "tagColor") as? Int ?? FinderTag.Color.green.rawValue) ?? .green }
        set { set(newValue.rawValue, "tagColor") }
    }

    var afterPrintAction: AfterPrintAction {
        get { AfterPrintAction(rawValue: defaults.string(forKey: "afterPrintAction") ?? "") ?? .leave }
        set { set(newValue.rawValue, "afterPrintAction") }
    }

    var renameSuffix: String {
        get { defaults.string(forKey: "renameSuffix") ?? " (printed)" }
        set { set(newValue, "renameSuffix") }
    }

    var moveFolder: URL? {
        get { defaults.string(forKey: "moveFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { set(newValue?.path, "moveFolder") }
    }

    // MARK: Per printer

    func size(for p: PrinterInfo) -> LabelSize {
        let saved = defaults.string(forKey: "size.\(p.name)").flatMap(LabelSize.init(parsing:)) ?? .fourBySix
        return p.resolve(saved) ?? p.resolve(.fourBySix) ?? saved
    }

    func setSize(_ size: LabelSize, for p: PrinterInfo) { set(size.description, "size.\(p.name)") }

    func fit(for p: PrinterInfo) -> FitMode {
        FitMode(rawValue: defaults.string(forKey: "fit.\(p.name)") ?? defaults.string(forKey: "fit") ?? "") ?? .fit
    }

    func setFit(_ fit: FitMode, for p: PrinterInfo) { set(fit.rawValue, "fit.\(p.name)") }

    func ink(for p: PrinterInfo) -> InkMode {
        InkMode(rawValue: defaults.string(forKey: "ink.\(p.name)") ?? defaults.string(forKey: "ink") ?? "") ?? .auto
    }

    func setInk(_ ink: InkMode, for p: PrinterInfo) { set(ink.rawValue, "ink.\(p.name)") }

    /// 0...1 black/white cutoff.
    func cutoff(for p: PrinterInfo) -> Double { defaults.object(forKey: "cutoff.\(p.name)") as? Double ?? 0.5 }

    func setCutoff(_ v: Double, for p: PrinterInfo) { set(v, "cutoff.\(p.name)") }

    /// Calibration shift in mm (+x right, +y down).
    func nudge(for p: PrinterInfo) -> CGPoint {
        CGPoint(x: defaults.double(forKey: "nudgeX.\(p.name)"), y: defaults.double(forKey: "nudgeY.\(p.name)"))
    }

    func setNudge(_ v: CGPoint, for p: PrinterInfo) {
        set(v.x, "nudgeX.\(p.name)")
        set(v.y, "nudgeY.\(p.name)")
    }

    func options(for p: PrinterInfo) -> LabelOptions {
        var o = LabelOptions()
        o.size = size(for: p)
        o.fit = fit(for: p)
        o.ink = ink(for: p)
        o.cutoff = cutoff(for: p)
        o.nudgeMM = nudge(for: p)
        return o
    }

    // MARK: Last print

    struct LastPrint {
        var file: URL
        var printer: String
        var size: LabelSize
    }

    var lastPrint: LastPrint? {
        get {
            guard let path = defaults.string(forKey: "last.file"), FileManager.default.fileExists(atPath: path),
                  let printer = defaults.string(forKey: "last.printer"),
                  let size = defaults.string(forKey: "last.size").flatMap(LabelSize.init(parsing:)) else { return nil }
            return LastPrint(file: URL(fileURLWithPath: path), printer: printer, size: size)
        }
        set {
            set(newValue?.file.path, "last.file")
            set(newValue?.printer, "last.printer")
            set(newValue?.size.description, "last.size")
        }
    }

    private func set(_ value: Any?, _ key: String) {
        objectWillChange.send()
        defaults.set(value, forKey: key)
    }

    /// Where printed labels are kept, for reprinting later.
    nonisolated static var historyFolder: URL {
        let url = AppPaths.support.appendingPathComponent("History", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
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

extension LabelSize {
    /// "4 × 6 in (102 × 152 mm)", or "100 × 150 mm (3.94 × 5.91 in)" for metric rolls.
    var display: String {
        let inches = "\(LabelSize.format(width)) × \(LabelSize.format(height)) in"
        let mm = "\(LabelSize.millimetres(width)) × \(LabelSize.millimetres(height)) mm"
        return isMetric ? "\(mm) (\(inches))" : "\(inches) (\(mm))"
    }
}

extension PrinterInfo {
    /// "MUNBYN ITPP941AP" rather than the queue name.
    var displayName: String {
        let model = makeAndModel.replacingOccurrences(of: "-AirPrint", with: "")
        return model.isEmpty ? name.replacingOccurrences(of: "_", with: " ") : model
    }
}
