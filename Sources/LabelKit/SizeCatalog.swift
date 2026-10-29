import Foundation

public enum SizeCatalog {
    /// Standard MUNBYN direct-thermal roll sizes, width × height in inches.
    public static let munbyn: [LabelSize] = [
        (4, 6), (4, 8), (4, 4), (4, 3), (4, 2), (4, 1),
        (3, 5), (3, 3), (3, 2), (3, 1),
        (2.5, 1.5), (2.25, 2.25), (2.25, 1.25), (2, 2), (2, 1),
        (1.5, 1), (1.25, 1), (1, 1),
    ].map { LabelSize(width: $0.0, height: $0.1) }

    public struct Entry: Sendable {
        public enum Source: String, Sendable { case printer, catalog }
        public var size: LabelSize
        public var source: Source
        /// Why the printer can't take this size, or nil if it can.
        public var unsupportedReason: String?
        public var isSupported: Bool { unsupportedReason == nil }
    }

    /// The printer's presets plus every catalog size, each marked supported or not.
    public static func entries(for printer: PrinterInfo) -> [Entry] {
        var entries = printer.presets.map { Entry(size: $0, source: .printer) }
        for size in munbyn where printer.preset(matching: size) == nil {
            entries.append(Entry(size: size, source: .catalog, unsupportedReason: reason(size, printer)))
        }
        return entries.sorted {
            ($0.isSupported ? 0 : 1, -$0.size.width, -$0.size.height)
                < ($1.isSupported ? 0 : 1, -$1.size.width, -$1.size.height)
        }
    }

    private static func reason(_ size: LabelSize, _ printer: PrinterInfo) -> String? {
        if printer.fitsCustomRange(size) { return nil }
        guard let lo = printer.customMin, let hi = printer.customMax else {
            return "printer doesn't accept custom sizes"
        }
        if size.width < lo.width || size.height < lo.height { return "smaller than the printer's minimum \(lo)" }
        if size.width > hi.width || size.height > hi.height { return "larger than the printer's maximum \(hi)" }
        return "outside the printer's custom range"
    }
}
