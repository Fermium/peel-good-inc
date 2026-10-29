import CoreGraphics
import Foundation
import LabelKit

/// The app's saved choices, read without ever writing: CFPreferences on the app's domain.
public struct AppDefaults: Sendable {
    public static let domain = "com.fermiumlabs.labelize"

    private let lookup: @Sendable (String) -> Any?
    public let source: String

    public init(source: String, lookup: @escaping @Sendable (String) -> Any?) {
        self.source = source
        self.lookup = lookup
    }

    /// LABELIZE_DEFAULTS_DOMAIN picks another domain; "none" reads nothing.
    public static func system(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppDefaults {
        let domain = environment["LABELIZE_DEFAULTS_DOMAIN"] ?? Self.domain
        if domain == "none" || domain.isEmpty { return .empty }
        return AppDefaults(source: domain) { key in
            CFPreferencesCopyAppValue(key as CFString, domain as CFString)
        }
    }

    public static let empty = AppDefaults(source: "none") { _ in nil }

    public func string(_ key: String) -> String? { lookup(key) as? String }
    public func double(_ key: String) -> Double? { (lookup(key) as? NSNumber)?.doubleValue }

    /// The printer chosen in the app's menu or Settings.
    public var printerName: String? { string("printer") }

    /// The app's options for a printer, like Store.options(for:): size, fit, ink, cutoff, nudge.
    public func options(for printer: String) -> (options: LabelOptions, fromApp: Set<String>) {
        var o = LabelOptions(), from: Set<String> = []
        if let size = string("size.\(printer)").flatMap(LabelSize.init(parsing:)) { o.size = size; from.insert("size") }
        if let fit = (string("fit.\(printer)") ?? string("fit")).flatMap(FitMode.init(rawValue:)) { o.fit = fit; from.insert("fit") }
        if let ink = (string("ink.\(printer)") ?? string("ink")).flatMap(InkMode.init(rawValue:)) { o.ink = ink; from.insert("ink") }
        if let cutoff = double("cutoff.\(printer)") { o.cutoff = cutoff; from.insert("cutoff") }
        let x = double("nudgeX.\(printer)"), y = double("nudgeY.\(printer)")
        if x != nil || y != nil { o.nudgeMM = CGPoint(x: x ?? 0, y: y ?? 0); from.insert("nudge") }
        return (o, from)
    }
}

public enum Layout {
    /// Applies --size, --fit, --crop, --pad, --rotate, --ink, --cutoff, --nudge and --no-snap.
    public static func apply(_ inv: Invocation, to base: LabelOptions) throws -> LabelOptions {
        var o = base
        if let v = inv["size"] {
            guard let size = LabelSize(parsing: v) else {
                throw CLIError.usage("can't read size \(v)", hint: "Use inches like 4x6 or 2.25x1.25, or millimetres like 100x150mm.")
            }
            o.size = size
        }
        if let v = inv["fit"] { o.fit = FitMode(rawValue: v)! }
        if let v = inv["crop"] { o.crop = CropMode(rawValue: v)! }
        if let v = inv["rotate"] { o.rotation = RotationMode(rawValue: v)! }
        if let v = inv["ink"] { o.ink = InkMode(rawValue: v)! }
        if let v = inv["pad"] {
            guard let mm = Double(v), mm >= 0 else { throw CLIError.usage("--pad needs millimetres, like 2") }
            o.paddingMM = mm
        }
        if let v = inv["cutoff"] {
            guard let pct = Double(v.replacingOccurrences(of: "%", with: "")), (0...100).contains(pct) else {
                throw CLIError.usage("--cutoff needs a percentage from 0 to 100", hint: "50 is the middle; lower prints lighter.")
            }
            o.cutoff = pct / 100
        }
        if let v = inv["tone-gamma"] {
            guard let g = Double(v), g > 0, g <= 2 else { throw CLIError.usage("--tone-gamma needs a number above 0, like 0.65", hint: "1 turns tone correction off.") }
            o.toneGamma = g
        }
        if let v = inv["nudge"] {
            let parts = v.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2, let x = parts[0], let y = parts[1] else {
                throw CLIError.usage("--nudge needs X,Y in mm", hint: "For example --nudge 1.5,-0.5 moves right 1.5 mm and up 0.5 mm.")
            }
            o.nudgeMM = CGPoint(x: x, y: y)
        }
        if inv.has("no-snap") { o.snapCodes = false }
        return o
    }

    /// --copies, at least 1.
    public static func copies(_ inv: Invocation) throws -> Int {
        guard let v = inv["copies"] else { return 1 }
        guard let n = Int(v), n >= 1, n <= 999 else { throw CLIError.usage("--copies needs a whole number from 1 to 999") }
        return n
    }
}
