import Foundation
import LabelKit

/// Which printers the app offers and which one a print goes to, the same way for drops, the API,
/// MCP, rules and the command line.
///
/// - Eligible printers take a 4x6 label or smaller and aren't hidden, label printers first.
/// - The default: the printer chosen in the app if it's eligible, else the system's label printer
///   (among eligible ones), else the first eligible printer. Hidden printers are never picked.
/// - A printer asked for by name is matched by `match(_:in:)`; naming a hidden printer still finds it.
public struct PrinterResolver: Sendable {
    public var printers: [PrinterInfo]
    public var hidden: Set<String>
    public var chosen: String?

    public init(printers: [PrinterInfo], hidden: [String] = [], chosen: String? = nil) {
        self.printers = printers
        self.hidden = Set(hidden)
        self.chosen = chosen
    }

    public init(printers: [PrinterInfo], settings: AppSettings) {
        self.init(printers: printers, hidden: settings.hiddenPrinters, chosen: settings.printerName)
    }

    public var eligible: [PrinterInfo] {
        printers.filter { $0.resolve(.fourBySix) != nil && !hidden.contains($0.name) }
            .sorted { ($0.isLabelPrinter ? 0 : 1, $0.name) < ($1.isLabelPrinter ? 0 : 1, $1.name) }
    }

    /// Why the default printer was picked.
    public enum Source: String, Sendable {
        case chosen = "app"
        case labelPrinter = "label printer"
        case firstEligible = "first printer that takes 4x6"
    }

    public var defaultChoice: (printer: PrinterInfo, source: Source)? {
        let eligible = eligible
        if let chosen, let p = eligible.first(where: { $0.name == chosen }) { return (p, .chosen) }
        if let p = Printers.defaultLabelPrinter(in: eligible) { return (p, .labelPrinter) }
        return eligible.first.map { ($0, .firstEligible) }
    }

    public var defaultPrinter: PrinterInfo? { defaultChoice?.printer }

    public enum Scope: Sendable { case eligible, all }

    /// A printer by queue or display name, among eligible printers or all of them.
    public func find(_ name: String, in scope: Scope = .all) -> PrinterInfo? {
        Self.match(name, in: scope == .all ? printers : eligible)
    }

    /// Printers whose queue, display name or model contains `name`, for "did you mean".
    public func candidates(_ name: String) -> [PrinterInfo] { Self.partial(name, in: printers) }

    /// Exact queue name, then queue name or display name ignoring case, then the one printer whose
    /// queue, display name or model contains the text.
    public static func match(_ name: String, in printers: [PrinterInfo]) -> PrinterInfo? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if let p = printers.first(where: { $0.name == name }) { return p }
        if let p = printers.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return p }
        if let p = printers.first(where: { $0.displayName.caseInsensitiveCompare(name) == .orderedSame }) { return p }
        let partial = partial(name, in: printers)
        return partial.count == 1 ? partial[0] : nil
    }

    private static func partial(_ name: String, in printers: [PrinterInfo]) -> [PrinterInfo] {
        printers.filter {
            $0.name.localizedCaseInsensitiveContains(name) || $0.displayName.localizedCaseInsensitiveContains(name)
                || $0.makeAndModel.localizedCaseInsensitiveContains(name)
        }
    }
}
