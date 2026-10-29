import CoreGraphics
import Foundation
import LabelKit
import LabelizeCore

public enum Layout {
    /// --size, --fit, --crop, --pad, --rotate, --ink, --cutoff, --tone-gamma, --nudge and --no-snap, as overrides.
    /// Values are checked against `Limits` when they're applied.
    public static func overrides(_ inv: Invocation) throws -> OptionOverrides {
        var o = OptionOverrides(size: inv["size"], fit: inv["fit"], ink: inv["ink"], crop: inv["crop"], rotation: inv["rotate"])
        if let v = inv["pad"] {
            guard let mm = Double(v), Limits.paddingMM.contains(mm) else { throw CLIError.usage("--pad needs millimetres, like 2") }
            o.paddingMM = mm
        }
        if let v = inv["cutoff"] {
            let lo = Int(Limits.cutoff.lowerBound * 100), hi = Int(Limits.cutoff.upperBound * 100)
            guard let pct = Double(v.replacingOccurrences(of: "%", with: "")), Limits.cutoff.contains(pct / 100) else {
                throw CLIError.usage("--cutoff needs a percentage from \(lo) to \(hi)", hint: "50 is the middle; lower prints lighter.")
            }
            o.cutoff = pct / 100
        }
        if let v = inv["tone-gamma"] {
            guard let g = Double(v), Limits.toneGamma.contains(g) else {
                throw CLIError.usage("--tone-gamma needs a number from \(LabelSize.format(Limits.toneGamma.lowerBound)) to \(LabelSize.format(Limits.toneGamma.upperBound)), like 0.65",
                                     hint: "1 turns tone correction off.")
            }
            o.toneGamma = g
        }
        if let v = inv["nudge"] {
            let parts = v.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2, let x = parts[0], let y = parts[1], Limits.nudgeMM.contains(x), Limits.nudgeMM.contains(y) else {
                throw CLIError.usage("--nudge needs X,Y in mm, each from \(Int(Limits.nudgeMM.lowerBound)) to \(Int(Limits.nudgeMM.upperBound))",
                                     hint: "For example --nudge 1.5,-0.5 moves right 1.5 mm and up 0.5 mm.")
            }
            o.nudgeMM = CGPoint(x: x, y: y)
        }
        if inv.has("no-snap") { o.snapCodes = false }
        return o
    }

    /// The command line's options on top of `base`. With a printer, a --size it can't take is an error
    /// (a saved size it can't take falls back instead: see `AppSettings.options(for:)`).
    public static func apply(_ inv: Invocation, to base: LabelOptions, on printer: PrinterInfo? = nil, tool: String = Manual.tool) throws -> LabelOptions {
        let overrides = try overrides(inv)
        do {
            return try overrides.apply(to: base, on: printer)
        } catch let e as OptionError {
            if e.isUnsupported, let printer {
                throw CLIError(e.message.hasSuffix(".") ? String(e.message.dropLast()) : e.message,
                               hint: "`\(tool) sizes \(printer.name)` lists the sizes it takes.", code: .printer)
            }
            throw CLIError.usage(e.code == "invalid_size" ? "can't read size \(inv["size"] ?? "")" : e.message, hint: e.hint)
        }
    }

    /// --copies, within `Limits.copies`.
    public static func copies(_ inv: Invocation) throws -> Int {
        guard let v = inv["copies"] else { return 1 }
        guard let n = Int(v), Limits.copies.contains(n) else {
            throw CLIError.usage("--copies needs a whole number from \(Limits.describe(Limits.copies))")
        }
        return n
    }
}
