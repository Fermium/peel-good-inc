import CoreGraphics
import Foundation
import LabelKit

/// A problem with a requested option. `isUnsupported` means the value is fine but the printer can't do it.
public struct OptionError: Error, Equatable, CustomStringConvertible {
    public var code: String
    public var message: String
    public var hint: String?
    public var isUnsupported = false

    public init(code: String, message: String, hint: String? = nil, isUnsupported: Bool = false) {
        self.code = code
        self.message = message
        self.hint = hint
        self.isUnsupported = isUnsupported
    }

    public var description: String { message }
}

/// Options asked for on top of a printer's or a rule's: from the API/MCP request or the command line.
/// Values are validated against `Limits`; text values ignore case.
public struct OptionOverrides: Sendable, Equatable {
    public var size: String?
    public var fit: String?
    public var ink: String?
    /// 0...1
    public var cutoff: Double?
    public var toneGamma: Double?
    public var nudgeMM: CGPoint?
    public var crop: String?
    public var rotation: String?
    public var paddingMM: Double?
    public var snapCodes: Bool?

    public init(size: String? = nil, fit: String? = nil, ink: String? = nil, cutoff: Double? = nil, toneGamma: Double? = nil,
                nudgeMM: CGPoint? = nil, crop: String? = nil, rotation: String? = nil, paddingMM: Double? = nil, snapCodes: Bool? = nil) {
        self.size = size
        self.fit = fit
        self.ink = ink
        self.cutoff = cutoff
        self.toneGamma = toneGamma
        self.nudgeMM = nudgeMM
        self.crop = crop
        self.rotation = rotation
        self.paddingMM = paddingMM
        self.snapCodes = snapCodes
    }

    /// Which options were given, by their settings names ("size", "ink"...).
    public var given: Set<String> {
        var s: Set<String> = []
        if size != nil { s.insert("size") }
        if fit != nil { s.insert("fit") }
        if ink != nil { s.insert("ink") }
        if cutoff != nil { s.insert("cutoff") }
        if toneGamma != nil { s.insert("toneGamma") }
        if nudgeMM != nil { s.insert("nudge") }
        return s
    }

    /// The overrides on top of `base`. With a printer, a size it can't take is an error.
    public func apply(to base: LabelOptions, on printer: PrinterInfo?) throws -> LabelOptions {
        var o = base
        if let size { o.size = try Self.size(size, on: printer) }
        if let fit { o.fit = try Self.fit(fit) }
        if let ink { o.ink = try Self.ink(ink) }
        if let crop { o.crop = try Self.choice(crop, "crop", CropMode.self) }
        if let rotation { o.rotation = try Self.choice(rotation, "rotate", RotationMode.self) }
        if let cutoff { o.cutoff = try Self.number(cutoff, "cutoff", Limits.cutoff) }
        if let toneGamma { o.toneGamma = try Self.number(toneGamma, "toneGamma", Limits.toneGamma) }
        if let paddingMM { o.paddingMM = try Self.number(paddingMM, "pad", Limits.paddingMM) }
        if let nudgeMM {
            _ = try Self.number(Double(nudgeMM.x), "nudge", Limits.nudgeMM)
            _ = try Self.number(Double(nudgeMM.y), "nudge", Limits.nudgeMM)
            o.nudgeMM = nudgeMM
        }
        if let snapCodes { o.snapCodes = snapCodes }
        return o
    }

    // MARK: Single values

    public static func size(_ text: String, on printer: PrinterInfo?) throws -> LabelSize {
        guard let wanted = LabelSize(parsing: text) else {
            throw OptionError(code: "invalid_size", message: "Size \(text) isn't valid. Use a size like 4x6 or 100x150mm.",
                              hint: "Use inches like 4x6 or 2.25x1.25, or millimetres like 100x150mm.")
        }
        guard let printer else { return wanted }
        guard let size = printer.resolve(wanted) else {
            let reason = SizeCatalog.entries(for: printer).first { $0.size == wanted }?.unsupportedReason
            throw OptionError(code: "unsupported_size", message: "\(printer.displayName) can't print \(wanted) labels\(reason.map { ": \($0)" } ?? "").",
                              isUnsupported: true)
        }
        return size
    }

    public static func fit(_ text: String) throws -> FitMode { try choice(text, "fit", FitMode.self) }
    public static func ink(_ text: String) throws -> InkMode { try choice(text, "ink", InkMode.self) }

    public static func copies(_ n: Int?) throws -> Int {
        let n = n ?? 1
        guard Limits.copies.contains(n) else {
            throw OptionError(code: "invalid_copies", message: "Copies must be \(Limits.describe(Limits.copies)).")
        }
        return n
    }

    static func choice<T: RawRepresentable & CaseIterable>(_ text: String, _ name: String, _: T.Type) throws -> T where T.RawValue == String {
        if let v = T(rawValue: text.trimmingCharacters(in: .whitespaces).lowercased()) { return v }
        let all = T.allCases.map(\.rawValue)
        let list = all.count == 2 ? "\(all[0]) or \(all[1])" : all.dropLast().joined(separator: ", ") + " or " + all.last!
        throw OptionError(code: "invalid_\(name)", message: "\(name.prefix(1).uppercased() + name.dropFirst()) must be \(list).")
    }

    static func number(_ v: Double, _ name: String, _ range: ClosedRange<Double>) throws -> Double {
        guard range.contains(v) else {
            throw OptionError(code: "invalid_\(name)", message: "\(name) must be a number from \(LabelSize.format(range.lowerBound)) to \(LabelSize.format(range.upperBound)).")
        }
        return v
    }
}
