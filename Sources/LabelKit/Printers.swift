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
    /// Dots per inch, when the printer says. Labels are composed at this resolution.
    public var dpi: Double?
    /// The ways to reach a Zebra directly, preferred first. Empty for the Mac's own print queues.
    public var zebraLinks: [Zebra.Link]
    /// A Zebra with a USB connection that's plugged in now.
    public var zebraUSBAttached: Bool
    /// Why the printer can't print right now ("the print head is open"), when it says.
    public var problem: String?

    /// Takes ZPL: the label is sent as the printer's own dots, not as a PDF for a driver.
    public var speaksZPL: Bool { !zebraLinks.isEmpty }

    /// The connection to use.
    public var zebraLink: Zebra.Link? { zebraLinks.first }

    /// Its address on the network, when it has one.
    public var zebraHost: String? {
        zebraLinks.lazy.compactMap(\.host).first
    }

    public init(name: String, makeAndModel: String = "", isDefault: Bool = false, state: State = .unknown,
                presets: [LabelSize], customMin: LabelSize? = nil, customMax: LabelSize? = nil,
                dpi: Double? = nil, zebraLinks: [Zebra.Link] = [], zebraUSBAttached: Bool = false, problem: String? = nil) {
        self.name = name
        self.makeAndModel = makeAndModel
        self.isDefault = isDefault
        self.state = state
        self.presets = presets
        self.customMin = customMin
        self.customMax = customMax
        self.dpi = dpi
        self.zebraLinks = zebraLinks
        self.zebraUSBAttached = zebraUSBAttached
        self.problem = problem
    }

    /// A ZPL printer, or one whose widest media is about 4 inches and that can print 4x6.
    public var isLabelPrinter: Bool {
        if speaksZPL { return resolve(.fourBySix) != nil }
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
    /// "zebra://192.168.1.216" names a Zebra on the network that isn't remembered, for the command line.
    /// "zebra://usb" is the one attached over USB, and "zebra://usb/ID" one of several.
    public static let zebraScheme = "zebra://"

    public static func zebraHost(_ name: String) -> String? {
        guard name.lowercased().hasPrefix(zebraScheme) else { return nil }
        let host = name.dropFirst(zebraScheme.count).trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return host.isEmpty ? nil : host
    }

    /// The connection a "zebra://" name means, or nil for any other name or no such USB printer.
    public static func zebraLink(_ name: String) -> Zebra.Link? {
        zebraHost(name).flatMap { try? link(forZebraHost: $0) }
    }

    private static func link(forZebraHost host: String) throws -> Zebra.Link {
        let parts = host.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.first?.lowercased() == "usb" else { return .network(host) }
        if parts.count == 2 { return .usb(id: parts[1]) }
        let attached = Zebra.usbPrinters()
        guard attached.count == 1 else {
            throw Zebra.Failed(description: attached.isEmpty ? "no Zebra is connected over USB"
                : "several Zebras are connected over USB: \(attached.joined(separator: ", ")). Use zebra://usb/ID")
        }
        return .usb(id: attached[0])
    }

    /// Asks a Zebra what it is, for a printer named by its address ("zebra://host").
    public static func zebra(host: String) throws -> PrinterInfo {
        let d = try Zebra.describe(try link(forZebraHost: host))
        return d.profile.printer(name: zebraScheme + host, status: d.status)
    }

    /// The queue Peel Good Inc. adds so any app can print to it. Never a printer it prints to.
    public static let virtualQueue = "Peel_Good_Inc"

    public static func all() -> [PrinterInfo] {
        var dests: UnsafeMutablePointer<cups_dest_t>?
        let count = cupsGetDests2(nil, &dests)
        guard let dests, count > 0 else { return [] }
        defer { cupsFreeDests(count, dests) }

        return (0..<Int(count)).map { info(for: dests + $0) }.filter { $0.name != virtualQueue }
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
                        customMin = LabelSize(pwgMedia: keyword)
                    } else if keyword.hasPrefix("custom_max_") {
                        customMax = LabelSize(pwgMedia: keyword)
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
