import CCups
import Foundation

public struct PrinterInfo: Sendable {
    public enum State: String, Sendable { case idle, printing, stopped, unknown }

    public var name: String
    public var makeAndModel: String
    public var isDefault: Bool
    public var state: State
    /// Sizes the printer reports as presets.
    public var presets: [LabelSize]
    /// Custom size range, when the printer accepts custom sizes.
    public var customMin: LabelSize?
    public var customMax: LabelSize?

    public init(name: String, makeAndModel: String = "", isDefault: Bool = false, state: State = .unknown,
                presets: [LabelSize], customMin: LabelSize? = nil, customMax: LabelSize? = nil) {
        self.name = name
        self.makeAndModel = makeAndModel
        self.isDefault = isDefault
        self.state = state
        self.presets = presets
        self.customMin = customMin
        self.customMax = customMax
    }

    /// A printer whose widest media is about 4 inches and that can print 4x6.
    public var isLabelPrinter: Bool {
        let widest = presets.map(\.width).max() ?? 0
        return widest > 0 && widest <= 4.3 && resolve(.fourBySix) != nil
    }

    public func preset(matching size: LabelSize) -> LabelSize? {
        presets.first { $0.matches(size) }
    }

    public func fitsCustomRange(_ size: LabelSize) -> Bool {
        guard let lo = customMin, let hi = customMax else { return false }
        let e = 0.005
        return size.width >= lo.width - e && size.width <= hi.width + e
            && size.height >= lo.height - e && size.height <= hi.height + e
    }

    /// The size as the printer should receive it: its preset if there is one, else a custom size.
    public func resolve(_ size: LabelSize) -> LabelSize? {
        if let preset = preset(matching: size) { return preset }
        if fitsCustomRange(size) { return LabelSize(width: size.width, height: size.height) }
        return nil
    }
}

public enum Printers {
    public static func all() -> [PrinterInfo] {
        var dests: UnsafeMutablePointer<cups_dest_t>?
        let count = cupsGetDests2(nil, &dests)
        guard let dests, count > 0 else { return [] }
        defer { cupsFreeDests(count, dests) }

        return (0..<Int(count)).map { info(for: dests + $0) }
    }

    /// The default printer if it's a label printer, else the first label printer.
    public static func defaultLabelPrinter(in printers: [PrinterInfo] = all()) -> PrinterInfo? {
        let labels = printers.filter(\.isLabelPrinter)
        return labels.first(where: \.isDefault) ?? labels.first
    }

    private static func info(for dest: UnsafeMutablePointer<cups_dest_t>) -> PrinterInfo {
        let d = dest.pointee
        func option(_ key: String) -> String? {
            cupsGetOption(key, d.num_options, d.options).map { String(cString: $0) }
        }
        let state: PrinterInfo.State = switch option("printer-state") {
        case "3": .idle
        case "4": .printing
        case "5": .stopped
        default: .unknown
        }

        var presets: [LabelSize] = []
        var customMin: LabelSize?
        var customMax: LabelSize?

        if let dinfo = cupsCopyDestInfo(nil, dest) {
            defer { cupsFreeDestInfo(dinfo) }
            let mediaCount = cupsGetDestMediaCount(nil, dest, dinfo, 0)
            for i in 0..<mediaCount {
                var size = cups_size_t()
                guard cupsGetDestMediaByIndex(nil, dest, dinfo, i, 0, &size) != 0 else { continue }
                let name = withUnsafeBytes(of: size.media) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                let label = LabelSize(width: Double(size.width) / 2540, height: Double(size.length) / 2540, mediaName: name)
                if !presets.contains(where: { $0.matches(label) }) { presets.append(label) }
            }
            if let attr = cupsFindDestSupported(nil, dest, dinfo, "media") {
                for i in 0..<ippGetCount(attr) {
                    guard let raw = ippGetString(attr, i, nil) else { continue }
                    let keyword = String(cString: raw)
                    if keyword.hasPrefix("custom_min_") {
                        customMin = LabelSize(parsing: String(keyword.dropFirst("custom_min_".count)))
                    } else if keyword.hasPrefix("custom_max_") {
                        customMax = LabelSize(parsing: String(keyword.dropFirst("custom_max_".count)))
                    }
                }
            }
        }

        return PrinterInfo(
            name: String(cString: d.name),
            makeAndModel: option("printer-make-and-model") ?? "",
            isDefault: d.is_default != 0,
            state: state,
            presets: presets,
            customMin: customMin,
            customMax: customMax
        )
    }
}
