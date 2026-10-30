import CoreGraphics
import Foundation
import LabelKit
import PeelGoodShared

/// The app's settings keys. Per-printer keys are "<key>.<queue name>".
public enum SettingsKey: String, CaseIterable, Sendable {
    case printer, countdown, alwaysReview, newFilesAction, playSounds, hiddenPrinters
    case historyDays, tagAfterPrint, tagName, tagColor, afterPrintAction, renameSuffix, moveFolder
    case watchedFolders, watchedSeen
    case lastFile = "last.file", lastPrinter = "last.printer", lastSize = "last.size"
    /// Older versions saved fit and ink once for every printer; still read as a fallback.
    case legacyFit = "fit", legacyInk = "ink"
}

public enum PrinterSettingsKey: String, CaseIterable, Sendable {
    case size, fit, ink, cutoff, nudgeX, nudgeY, toneGamma
    public func key(_ printer: String) -> String { "\(rawValue).\(printer)" }
}

/// What happens to the original file after its labels print.
public enum AfterPrintAction: String, CaseIterable, Identifiable, Sendable {
    case leave, rename, move, trash
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .leave: "Leave it"
        case .rename: "Add suffix"
        case .move: "Move to folder"
        case .trash: "Move to Trash"
        }
    }
}

/// The app's settings over its UserDefaults domain, typed. The app reads and writes them (`Store`);
/// the command line reads them through CFPreferences and only ever writes Reprint Last Label (`lastPrint`).
public struct AppSettings: @unchecked Sendable {
    private let read: (String) -> Any?
    private let write: ((String, Any?) -> Void)?
    /// The domain read ("com.fermium.peelgood"), "none", or a test name.
    public let source: String

    public init(source: String, read: @escaping (String) -> Any?, write: ((String, Any?) -> Void)? = nil) {
        self.source = source
        self.read = read
        self.write = write
    }

    public var isWritable: Bool { write != nil }

    /// The app's own defaults (`UserDefaults.standard` inside the app; a suite in tests).
    public static func userDefaults(_ d: UserDefaults, source: String = AppIdentity.bundleID) -> AppSettings {
        AppSettings(source: source, read: { d.object(forKey: $0) }, write: { k, v in
            if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) }
        })
    }

    /// Another process's view of a domain through CFPreferences: read only unless `writable`.
    public static func preferences(domain: String, writable: Bool = false) -> AppSettings {
        let write: ((String, Any?) -> Void)? = writable ? { k, v in
            CFPreferencesSetAppValue(k as CFString, v as CFPropertyList?, domain as CFString)
            CFPreferencesAppSynchronize(domain as CFString)
        } : nil
        return AppSettings(source: domain, read: { CFPreferencesCopyAppValue($0 as CFString, domain as CFString) }, write: write)
    }

    /// For the command line: PEELGOOD_DEFAULTS_DOMAIN picks another domain; "none" reads nothing.
    /// Without it, the app's domain, or the old bundle ID's domain while the app hasn't copied it over yet.
    public static func system(environment: [String: String] = ProcessInfo.processInfo.environment, writable: Bool = false) -> AppSettings {
        let domain = environment["PEELGOOD_DEFAULTS_DOMAIN"] ?? defaultDomain()
        if domain == "none" || domain.isEmpty { return .empty }
        return .preferences(domain: domain, writable: writable)
    }

    /// `current` when it has settings or `legacy` has none; otherwise `legacy`.
    public static func defaultDomain(current: String = AppIdentity.bundleID, legacy: String = AppIdentity.legacyBundleID) -> String {
        DefaultsMigration.keys(in: current).isEmpty && !DefaultsMigration.keys(in: legacy).isEmpty ? legacy : current
    }

    /// Settings held in memory, for tests and previews. Writable.
    public static func memory(_ initial: [String: Any] = [:], source: String = "memory") -> AppSettings {
        final class Box: @unchecked Sendable { var values: [String: Any] = [:] }
        let box = Box()
        box.values = initial
        return AppSettings(source: source, read: { box.values[$0] }, write: { k, v in box.values[k] = v })
    }

    public static let empty = AppSettings(source: "none", read: { _ in nil })

    // MARK: Raw access

    public func object(_ key: String) -> Any? { read(key) }
    public func string(_ key: String) -> String? { read(key) as? String }
    public func double(_ key: String) -> Double? { (read(key) as? NSNumber)?.doubleValue }
    public func int(_ key: String) -> Int? { read(key) as? Int ?? (read(key) as? NSNumber)?.intValue }
    public func bool(_ key: String) -> Bool? { read(key) as? Bool }
    public func strings(_ key: String) -> [String]? { read(key) as? [String] }
    public func set(_ value: Any?, _ key: String) { write?(key, value) }

    // MARK: Defaults

    public enum Default {
        public static let countdown = 1.5
        public static let historyDays = 30
        public static let tagName = "Printed"
        public static let tagColor = FinderTag.Color.green
        public static let renameSuffix = " (printed)"
        public static let cutoff = 0.5
        public static let newFilesAction = RuleAction.ask
    }

    // MARK: Behaviour

    /// The printer chosen in the menu or Settings (a queue name). `PrinterResolver` turns it into a printer.
    public var printerName: String? {
        get { string(SettingsKey.printer.rawValue) }
        nonmutating set { set(newValue, SettingsKey.printer.rawValue) }
    }

    /// Seconds between dropping and printing; 0 prints immediately.
    public var countdown: Double {
        get { double(SettingsKey.countdown.rawValue) ?? Default.countdown }
        nonmutating set { set(newValue, SettingsKey.countdown.rawValue) }
    }

    /// General > Before printing: Show preview.
    public var alwaysReview: Bool {
        get { bool(SettingsKey.alwaysReview.rawValue) ?? false }
        nonmutating set { set(newValue, SettingsKey.alwaysReview.rawValue) }
    }

    /// Rules > New files: what files in a watched folder do when no rule says otherwise.
    public var newFilesAction: RuleAction {
        get { RuleAction(rawValue: string(SettingsKey.newFilesAction.rawValue) ?? "") ?? Default.newFilesAction }
        nonmutating set { set(newValue.rawValue, SettingsKey.newFilesAction.rawValue) }
    }

    public var playSounds: Bool {
        get { bool(SettingsKey.playSounds.rawValue) ?? true }
        nonmutating set { set(newValue, SettingsKey.playSounds.rawValue) }
    }

    /// Printers removed from the app's lists (they stay installed on the Mac).
    public var hiddenPrinters: [String] {
        get { strings(SettingsKey.hiddenPrinters.rawValue) ?? [] }
        nonmutating set { set(newValue, SettingsKey.hiddenPrinters.rawValue) }
    }

    // MARK: Files

    /// Days to keep saved prints; 0 keeps them forever.
    public var historyDays: Int {
        get { int(SettingsKey.historyDays.rawValue) ?? Default.historyDays }
        nonmutating set { set(newValue, SettingsKey.historyDays.rawValue) }
    }

    public var tagAfterPrint: Bool {
        get { bool(SettingsKey.tagAfterPrint.rawValue) ?? true }
        nonmutating set { set(newValue, SettingsKey.tagAfterPrint.rawValue) }
    }

    public var tagName: String {
        get { string(SettingsKey.tagName.rawValue) ?? Default.tagName }
        nonmutating set { set(newValue, SettingsKey.tagName.rawValue) }
    }

    public var tagColor: FinderTag.Color {
        get { int(SettingsKey.tagColor.rawValue).flatMap(FinderTag.Color.init(rawValue:)) ?? Default.tagColor }
        nonmutating set { set(newValue.rawValue, SettingsKey.tagColor.rawValue) }
    }

    /// General > After Printing's tag, whether or not tagging is on (`RuleTag.resolve` checks that).
    public var generalTag: FinderTag { FinderTag(name: tagName, color: tagColor) }

    public var afterPrintAction: AfterPrintAction {
        get { AfterPrintAction(rawValue: string(SettingsKey.afterPrintAction.rawValue) ?? "") ?? .leave }
        nonmutating set { set(newValue.rawValue, SettingsKey.afterPrintAction.rawValue) }
    }

    public var renameSuffix: String {
        get { string(SettingsKey.renameSuffix.rawValue) ?? Default.renameSuffix }
        nonmutating set { set(newValue, SettingsKey.renameSuffix.rawValue) }
    }

    public var moveFolder: URL? {
        get { string(SettingsKey.moveFolder.rawValue).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        nonmutating set { set(newValue?.path, SettingsKey.moveFolder.rawValue) }
    }

    public var watchedFolders: [URL] {
        get { (strings(SettingsKey.watchedFolders.rawValue) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        nonmutating set { set(newValue.map(\.path), SettingsKey.watchedFolders.rawValue) }
    }

    public var watchedSeen: [String] {
        get { strings(SettingsKey.watchedSeen.rawValue) ?? [] }
        nonmutating set { set(newValue, SettingsKey.watchedSeen.rawValue) }
    }

    // MARK: Per printer (saved values; nil when never set)

    public func savedSize(_ printer: String) -> LabelSize? {
        string(PrinterSettingsKey.size.key(printer)).flatMap(LabelSize.init(parsing:))
    }

    public func savedFit(_ printer: String) -> FitMode? {
        (string(PrinterSettingsKey.fit.key(printer)) ?? string(SettingsKey.legacyFit.rawValue)).flatMap(FitMode.init(rawValue:))
    }

    public func savedInk(_ printer: String) -> InkMode? {
        (string(PrinterSettingsKey.ink.key(printer)) ?? string(SettingsKey.legacyInk.rawValue)).flatMap(InkMode.init(rawValue:))
    }

    /// 0...1 black/white cutoff.
    public func savedCutoff(_ printer: String) -> Double? { double(PrinterSettingsKey.cutoff.key(printer)) }

    /// Calibration shift in mm (+x right, +y down).
    public func savedNudge(_ printer: String) -> CGPoint? {
        let x = double(PrinterSettingsKey.nudgeX.key(printer)), y = double(PrinterSettingsKey.nudgeY.key(printer))
        guard x != nil || y != nil else { return nil }
        return CGPoint(x: x ?? 0, y: y ?? 0)
    }

    /// Dot gain for photo and halftone; nil uses LabelKit's default.
    public func savedToneGamma(_ printer: String) -> Double? { double(PrinterSettingsKey.toneGamma.key(printer)) }

    public func setSize(_ size: LabelSize, for printer: String) { set(size.description, PrinterSettingsKey.size.key(printer)) }
    public func setFit(_ fit: FitMode, for printer: String) { set(fit.rawValue, PrinterSettingsKey.fit.key(printer)) }
    public func setInk(_ ink: InkMode, for printer: String) { set(ink.rawValue, PrinterSettingsKey.ink.key(printer)) }
    public func setCutoff(_ v: Double, for printer: String) { set(v, PrinterSettingsKey.cutoff.key(printer)) }
    public func setToneGamma(_ v: Double?, for printer: String) { set(v, PrinterSettingsKey.toneGamma.key(printer)) }
    public func setNudge(_ v: CGPoint, for printer: String) {
        set(Double(v.x), PrinterSettingsKey.nudgeX.key(printer))
        set(Double(v.y), PrinterSettingsKey.nudgeY.key(printer))
    }

    /// A printer's options as the app prints them, and which came from saved settings.
    public struct PrinterOptions {
        public var options: LabelOptions
        /// "size", "fit", "ink", "cutoff", "nudge", "toneGamma": the ones that were saved.
        public var saved: Set<String>
        /// Set when the saved size doesn't fit the printer and another was used.
        public var note: String?
    }

    /// Size, fit, ink, cutoff, nudge and tone gamma for a printer.
    ///
    /// The size: the saved one if the printer takes it, else 4x6 if it takes that, else the saved size as is.
    /// A saved size the printer can't take never stops a print; `note` says what was used instead.
    /// (A size asked for explicitly, by `--size` or the API, is an error instead: see `OptionOverrides`.)
    public func options(for p: PrinterInfo) -> PrinterOptions {
        var o = LabelOptions(), saved: Set<String> = [], note: String?
        let wanted = savedSize(p.name)
        if wanted != nil { saved.insert("size") }
        let size = wanted ?? .fourBySix
        if let resolved = p.resolve(size) {
            o.size = resolved
        } else if let fallback = p.resolve(.fourBySix) {
            o.size = fallback
            note = "\(p.displayName) can't take \(size.primary) labels, so this uses \(fallback.primary)."
        } else {
            o.size = size
        }
        if let fit = savedFit(p.name) { o.fit = fit; saved.insert("fit") }
        if let ink = savedInk(p.name) { o.ink = ink; saved.insert("ink") }
        if let cutoff = savedCutoff(p.name) { o.cutoff = cutoff; saved.insert("cutoff") } else { o.cutoff = Default.cutoff }
        if let nudge = savedNudge(p.name) { o.nudgeMM = nudge; saved.insert("nudge") }
        if let g = savedToneGamma(p.name) { o.toneGamma = g; saved.insert("toneGamma") }
        return PrinterOptions(options: o, saved: saved, note: note)
    }

    // MARK: Last print

    /// Reprint Last Label: the saved label PDF and where it went.
    public struct LastPrint: Equatable, Sendable {
        public var file: URL
        public var printer: String
        public var size: LabelSize
        public init(file: URL, printer: String, size: LabelSize) {
            self.file = file
            self.printer = printer
            self.size = size
        }
    }

    public var lastPrint: LastPrint? {
        get {
            guard let path = string(SettingsKey.lastFile.rawValue), FileManager.default.fileExists(atPath: path),
                  let printer = string(SettingsKey.lastPrinter.rawValue),
                  let size = string(SettingsKey.lastSize.rawValue).flatMap(LabelSize.init(parsing:)) else { return nil }
            return LastPrint(file: URL(fileURLWithPath: path), printer: printer, size: size)
        }
        nonmutating set {
            set(newValue?.file.path, SettingsKey.lastFile.rawValue)
            set(newValue?.printer, SettingsKey.lastPrinter.rawValue)
            set(newValue?.size.description, SettingsKey.lastSize.rawValue)
        }
    }
}
