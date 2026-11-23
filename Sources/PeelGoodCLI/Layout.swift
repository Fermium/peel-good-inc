import CoreGraphics
import Foundation
import LabelKit
import PeelGoodCore

public enum Layout {
    /// --size, --fit, --scale, --crop, --pad, --rotate, --ink, --cutoff, --tone-gamma, --nudge and --no-snap, as overrides.
    /// Values are checked against `Limits` when they're applied.
    public static func overrides(_ inv: Invocation) throws -> OptionOverrides {
        var o = OptionOverrides(size: inv["size"], fit: inv["fit"], ink: inv["ink"], crop: inv["crop"], rotation: inv["rotate"])
        if let v = inv["scale"] {
            guard let pct = Double(v.replacingOccurrences(of: "%", with: "")), Limits.scalePercent.contains(pct) else {
                throw CLIError.usage("--scale needs a percentage from \(Int(Limits.scalePercent.lowerBound)) to \(Int(Limits.scalePercent.upperBound))",
                                     hint: "100 is physical size; it applies with --fit direct.")
            }
            o.scalePercent = pct
        }
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

    /// A Zebra's darkness and speed: `base` (the app's for the printer) with --darkness and --print-speed
    /// on top. --darkness 0 and --print-speed printer go back to the printer's own.
    public static func tuning(_ inv: Invocation, base: ZPL.Tuning = .init()) throws -> ZPL.Tuning {
        var t = base
        if let v = inv["darkness"] {
            guard let d = Int(v), Limits.darkness.contains(d) else {
                throw CLIError.usage("--darkness needs a whole number from \(Limits.darkness.lowerBound) to \(Limits.darkness.upperBound)",
                                     hint: "It's added to the printer's own darkness: +5 is darker, 0 leaves it.")
            }
            t.darkness = d == 0 ? nil : d
        }
        if let v = inv["print-speed"] {
            if v.lowercased() == "printer" {
                t.speed = nil
            } else {
                guard let n = Int(v), Limits.printSpeed.contains(n) else {
                    throw CLIError.usage("--print-speed needs inches per second from \(Limits.printSpeed.lowerBound) to \(Limits.printSpeed.upperBound), or printer",
                                         hint: "Slower prints darker.")
                }
                t.speed = n
            }
        }
        return t
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
