import Foundation
import LabelKit

/// Plain-English rule descriptions for the list and the test result.
enum RuleSummary {
    /// "comes from amazon.com and includes a QR code"
    static func conditions(_ rule: Rule) -> String {
        let parts = rule.conditions.map(phrase)
        guard !parts.isEmpty else { return "no conditions yet" }
        return EnglishList.join(parts, conjunction: rule.matchAll ? "and" : "or")
    }

    /// "Label Printer ITPP941AP · 4 × 4 in · Crisp · shows preview". Fields left at Default aren't listed.
    static func outcome(_ o: RuleOutcome, printers: [PrinterInfo]) -> String {
        var parts = [printerName(o.printer, printers: printers)]
        if let size = o.labelSize { parts.append(size.display) }
        if let fit = o.fit { parts.append(fit == .fit ? "Fit" : "Fill") }
        if let ink = o.ink { parts.append(ink.rawValue.capitalized) }
        if let action = o.action { parts.append(action.shortTitle) }
        if o.copies > 1 { parts.append("\(o.copies) copies") }
        if let tag = o.tag { parts.append("tags “\(tag.name)”") }
        return parts.joined(separator: " · ")
    }

    static func printerName(_ name: String?, printers: [PrinterInfo]) -> String {
        guard let name else { return "Default printer" }
        return printers.first { $0.name == name }?.displayName ?? "\(name.replacingOccurrences(of: "_", with: " ")) (not connected)"
    }

    static func phrase(_ c: RuleCondition) -> String {
        let tokens = c.values.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let value = tokens.first ?? ""
        let quoted = EnglishList.join(tokens.map { "“\($0)”" }, conjunction: "or")
        let plain = EnglishList.join(tokens, conjunction: "or")
        let positive = c.op == .is || c.op == .includes || c.op == .contains || c.op == .isInside
        switch c.field {
        case .source:
            if c.op == .isUnknown { return "has no source website" }
            let what = plain.isEmpty ? "…" : plain
            return positive ? "comes from \(what)" : "doesn't come from \(what)"
        case .name:
            let what = quoted.isEmpty ? "…" : quoted
            return "name \(c.op.title) \(what)"
        case .kind:
            let kind = FileKind(rawValue: value) ?? .pdf
            let noun = kind == .image ? "an image" : kind == .svg ? "an SVG" : "a \(kind.title.lowercased())"
            return (positive ? "is " : "isn't ") + (kind == .pdf ? "a PDF" : noun)
        case .folder:
            let name = value.isEmpty ? "…" : (value as NSString).lastPathComponent
            return positive ? "is in \(name)" : "isn't in \(name)"
        case .trigger:
            let t = RuleTrigger(rawValue: value) ?? .drop
            let yes: String, no: String
            switch t {
            case .drop: (yes, no) = ("is dropped on the icon", "isn't dropped on the icon")
            case .clipboard: (yes, no) = ("comes from the clipboard", "doesn't come from the clipboard")
            case .openWith: (yes, no) = ("is opened from Finder", "isn't opened from Finder")
            case .watchedFolder: (yes, no) = ("turns up in a watched folder", "doesn't come from a watched folder")
            case .api: (yes, no) = ("is sent by another app", "isn't sent by another app")
            }
            return positive ? yes : no
        case .pageSize:
            let shape = PageShape(rawValue: value)?.title ?? "…"
            return positive ? "has \(shape) pages" : "doesn't have \(shape) pages"
        case .pageCount:
            let n = c.number, pages = n == 1 ? "page" : "pages"
            switch c.op {
            case .isMoreThan: return "has more than \(n) \(pages)"
            case .isFewerThan: return "has fewer than \(n) \(pages)"
            default: return "has exactly \(n) \(pages)"
            }
        case .code:
            let kind = CodeKind(rawValue: value) ?? .any
            if positive { return "includes \(kind.title)" }
            return kind == .any ? "has no codes" : "has no \(kind.title.replacingOccurrences(of: "^an? ", with: "", options: .regularExpression))"
        case .pageText:
            let what = quoted.isEmpty ? "…" : quoted
            return positive ? "says \(what)" : "doesn't say \(what)"
        case .codeText:
            let what = quoted.isEmpty ? "…" : quoted
            return positive ? "has a code containing \(what)" : "has no code containing \(what)"
        }
    }

    /// "From amazon.com · Screenshot · 1 page · 1170 × 2532 px · QR"
    static func facts(_ c: RuleContext) -> String {
        var parts: [String] = []
        parts.append(c.sourceHosts.first.map { "From \($0)" } ?? "No source website")
        if let kind = c.kind { parts.append(kind.title) }
        parts.append("\(c.pageCount) page\(c.pageCount == 1 ? "" : "s")")
        if let s = c.firstPageSize {
            if c.isRaster {
                parts.append("\(Int(s.width)) × \(Int(s.height)) px")
            } else {
                let shape = PageShape.allCases.first { $0.matches(s) }
                parts.append(shape?.title ?? String(format: "%.0f × %.0f mm", s.width / 72 * 25.4, s.height / 72 * 25.4))
            }
        }
        if let codes = c.codes {
            let kinds = Set(codes.map(\.symbology)).sorted()
            parts.append(kinds.isEmpty ? "No codes" : kinds.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }
}

private enum EnglishList {
    /// "a", "a or b", "a, b or c"
    static func join(_ items: [String], conjunction: String) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + " \(conjunction) " + items.last!
        }
    }
}
