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

    public static let fourBySix = LabelSize(width: 4, height: 6)

    public var points: CGSize { CGSize(width: width * 72, height: height * 72) }

    public var description: String { "\(Self.format(width))x\(Self.format(height))" }

    /// The media keyword to hand CUPS: the printer's preset name, or a PWG custom size.
    public var cupsMedia: String { mediaName ?? "custom_\(description)in_\(description)in" }

    public func matches(_ other: LabelSize, tolerance: Double = 0.03) -> Bool {
        abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }

    static func format(_ value: Double) -> String {
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
