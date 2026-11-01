import CoreGraphics
import Foundation

/// A label size in inches. `width` runs across the print head, `height` along the feed.
public struct LabelSize: Hashable, Sendable, CustomStringConvertible {
    public var width: Double
    public var height: Double
    /// The printer's own media keyword, when the printer reports this size as a preset.
    public var mediaName: String?

    public init(width: Double, height: Double, mediaName: String? = nil) {
        self.width = width
        self.height = height
        self.mediaName = mediaName
    }

    /// Parses "4x6", "2.25x1.25", "4x6in" or "100x150mm".
    public init?(parsing text: String) {
        var t = text.lowercased().trimmingCharacters(in: .whitespaces)
        var unit = 1.0
        if t.hasSuffix("mm") {
            unit = 1 / 25.4
            t.removeLast(2)
        } else if t.hasSuffix("in") {
            t.removeLast(2)
        }
        let parts = t.split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 else { return nil }
        self.init(width: w * unit, height: h * unit)
    }

    /// The size a PWG media name describes by its last field: "oe_4x6-label_4x6in", "custom_min_1x0.5in".
    public init?(pwgMedia name: String) {
        guard let dims = name.split(separator: "_").last else { return nil }
        self.init(parsing: String(dims))
    }

    public static let fourBySix = LabelSize(width: 4, height: 6)

    public var points: CGSize { CGSize(width: width * 72, height: height * 72) }

    /// "4x6", or "100x150mm" for metric rolls.
    public var description: String {
        isMetric ? "\(Self.millimetres(width))x\(Self.millimetres(height))mm" : "\(Self.format(width))x\(Self.format(height))"
    }

    /// The media keyword to hand CUPS: the printer's preset name, or a PWG custom size.
    public var cupsMedia: String {
        if let mediaName { return mediaName }
        if isMetric { return "custom_\(description)_\(description)" }
        return "custom_\(description)in_\(description)in"
    }

    /// Whole millimetres that aren't tidy inch fractions (100 × 150 mm rather than 4 × 6 in).
    public var isMetric: Bool {
        func tidyInches(_ v: Double) -> Bool { abs(v * 20 - (v * 20).rounded()) < 0.02 }
        func wholeMM(_ v: Double) -> Bool { abs(v * 25.4 - (v * 25.4).rounded()) < 0.05 }
        return !(tidyInches(width) && tidyInches(height)) && wholeMM(width) && wholeMM(height)
    }

    public static func millimetres(_ inches: Double) -> Int { Int((inches * 25.4).rounded()) }

    public func matches(_ other: LabelSize, tolerance: Double = 0.03) -> Bool {
        abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }

    public static func format(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%g", rounded)
    }

    /// Equality ignores the media keyword so a parsed "4x6" equals the printer's preset.
    public static func == (a: LabelSize, b: LabelSize) -> Bool { a.matches(b, tolerance: 0.005) }

    public func hash(into hasher: inout Hasher) {
        hasher.combine((width * 100).rounded())
        hasher.combine((height * 100).rounded())
    }
}
