import Foundation
import LabelKit

/// "When a file [conditions] → print it like [outcome]". Rules are tried top to bottom; the first match wins.
struct Rule: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var isEnabled = true
    /// All conditions must hold, or any one of them.
    var matchAll = true
    var conditions: [RuleCondition]
    var outcome = RuleOutcome()

    /// Shown when the name is left blank.
    var displayName: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled Rule" : name }

    /// Conditions whose value is still blank; they never match, so the editor flags them.
    var incompleteConditions: [RuleCondition] { conditions.filter { !$0.isComplete } }
}

// MARK: Conditions

/// One sentence fragment: "[Source website] [is] [amazon.com, amazon.co.uk]".
/// Kept flat (rather than an enum with payloads) so pop-ups can bind straight to it and the JSON stays readable.
struct RuleCondition: Codable, Identifiable, Hashable {
    var id = UUID()
    var field: Field
    var op: Op
    /// Tokens (domains, names, code text), or a single choice/path, depending on the field.
    var values: [String] = []
    /// For page count.
    var number = 1

    enum Field: String, Codable, CaseIterable, Identifiable {
        case source, name, kind, folder, trigger, pageSize, pageCount, pageText, code, codeText
        var id: Self { self }

        var title: String {
            switch self {
            case .source: "Source website"
            case .name: "File name"
            case .kind: "File type"
            case .folder: "Folder"
            case .trigger: "How it arrives"
            case .pageSize: "Page size"
            case .pageCount: "Number of pages"
            case .pageText: "Text on the page"
            case .code: "Codes on the page"
            case .codeText: "Code text"
            }
        }

        var ops: [Op] {
            switch self {
            case .source: [.is, .isNot, .isUnknown]
            case .name: [.contains, .doesNotContain, .beginsWith, .endsWith, .is]
            case .kind, .trigger, .pageSize: [.is, .isNot]
            case .folder: [.isInside, .isNotInside]
            case .pageCount: [.isMoreThan, .isFewerThan, .is]
            case .code: [.includes, .doesNotInclude]
            case .codeText, .pageText: [.contains, .doesNotContain]
            }
        }

        /// Choices for pop-up fields, as (stored value, title).
        var choices: [(String, String)] {
            switch self {
            case .kind: FileKind.allCases.map { ($0.rawValue, $0.title) }
            case .trigger: RuleTrigger.allCases.map { ($0.rawValue, $0.title) }
            case .pageSize: PageShape.allCases.map { ($0.rawValue, $0.title) }
            case .code: CodeKind.allCases.map { ($0.rawValue, $0.title) }
            default: []
            }
        }

        var usesTokens: Bool { [.source, .name, .pageText, .codeText].contains(self) }

        var tokenPlaceholder: String {
            switch self {
            case .source: "amazon.com, royalmail.com"
            case .name: "label, return"
            case .codeText: "1Z, JD0"
            case .pageText: "Click & Drop, Royal Mail"
            default: ""
            }
        }

        /// A sensible starting condition when the user picks this field.
        var starter: RuleCondition {
            var c = RuleCondition(field: self, op: ops[0])
            switch self {
            case .folder: c.values = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path]
            case .pageCount: c.number = 1
            default: if let first = choices.first { c.values = [first.0] }
            }
            return c
        }
    }

    enum Op: String, Codable {
        case `is`, isNot, isUnknown, contains, doesNotContain, beginsWith, endsWith
        case isInside, isNotInside, isMoreThan, isFewerThan, includes, doesNotInclude

        var title: String {
            switch self {
            case .is: "is"
            case .isNot: "is not"
            case .isUnknown: "is unknown"
            case .contains: "contains"
            case .doesNotContain: "doesn't contain"
            case .beginsWith: "begins with"
            case .endsWith: "ends with"
            case .isInside: "is inside"
            case .isNotInside: "is not inside"
            case .isMoreThan: "is more than"
            case .isFewerThan: "is fewer than"
            case .includes: "include"
            case .doesNotInclude: "don't include"
            }
        }

        var takesValue: Bool { self != .isUnknown }
    }

    var isComplete: Bool {
        guard op.takesValue, field != .pageCount else { return true }
        return values.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The field moved to a new kind: keep the id, reset what no longer makes sense.
    mutating func change(to field: Field) {
        guard field != self.field else { return }
        let id = id
        self = field.starter
        self.id = id
    }
}

enum FileKind: String, Codable, CaseIterable {
    case pdf, image, svg, screenshot
    var title: String {
        switch self {
        case .pdf: "PDF"
        case .image: "Image"
        case .svg: "SVG"
        case .screenshot: "Screenshot"
        }
    }
}

/// How a file reached Labelize.
enum RuleTrigger: String, Codable, CaseIterable {
    case drop, clipboard, openWith, watchedFolder, api
    var title: String {
        switch self {
        case .drop: "Dropped on the icon"
        case .clipboard: "From the clipboard"
        case .openWith: "Opened in Finder"
        case .watchedFolder: "In a watched folder"
        case .api: "From another app"
        }
    }
    /// Unattended triggers have nobody looking at the screen when the file arrives.
    var isUnattended: Bool { self == .watchedFolder || self == .api }
}

/// Page sizes worth recognising, in either orientation.
enum PageShape: String, Codable, CaseIterable {
    case fourBySix, letter, a4
    var title: String {
        switch self {
        case .fourBySix: "4 × 6 in label"
        case .letter: "US Letter"
        case .a4: "A4"
        }
    }
    /// Width × height in millimetres.
    var mm: (Double, Double) {
        switch self {
        case .fourBySix: (101.6, 152.4)
        case .letter: (215.9, 279.4)
        case .a4: (210, 297)
        }
    }
    /// True if a page of this size in points is this shape, within 3 mm (Royal Mail's 101 × 152 counts as 4 × 6).
    func matches(_ points: CGSize) -> Bool {
        let w = points.width / 72 * 25.4, h = points.height / 72 * 25.4
        let (a, b) = (min(w, h), max(w, h)), (x, y) = (min(mm.0, mm.1), max(mm.0, mm.1))
        return abs(a - x) <= 3 && abs(b - y) <= 3
    }
}

enum CodeKind: String, Codable, CaseIterable {
    case any, qr, dataMatrix, pdf417, aztec, barcode
    var title: String {
        switch self {
        case .any: "any code"
        case .qr: "a QR code"
        case .dataMatrix: "a Data Matrix code"
        case .pdf417: "a PDF417 code"
        case .aztec: "an Aztec code"
        case .barcode: "a barcode (1D)"
        }
    }
    /// Does a Vision symbology name ("QR", "Code128", "DataMatrix"…) count as this kind?
    func matches(_ symbology: String) -> Bool {
        let s = symbology.lowercased()
        switch self {
        case .any: return true
        case .qr: return s.contains("qr")
        case .dataMatrix: return s.contains("datamatrix")
        case .pdf417: return s.contains("pdf417")
        case .aztec: return s.contains("aztec")
        case .barcode: return !["qr", "datamatrix", "pdf417", "aztec"].contains { s.contains($0) }
        }
    }
}

// MARK: Outcome

/// What to do with a matching file. Every field left nil falls back to the printer's remembered settings.
/// There is deliberately no way to skip or drop pages: every page of every file always prints.
struct RuleOutcome: Codable, Hashable {
    /// CUPS queue name; nil means the default printer.
    var printer: String?
    /// "4x6"; nil means that printer's label size.
    var size: String?
    var fit: FitMode?
    var ink: InkMode?
    /// nil follows General > Before printing for files you hand over, Rules > New files for watched folders.
    var action: RuleAction?
    var copies = 1
    var tag: FinderTag? = FinderTag()

    var labelSize: LabelSize? { size.flatMap(LabelSize.init(parsing:)) }

    init() {}

    /// Older files also have `playSound`; it's ignored, since sounds follow General.
    enum CodingKeys: String, CodingKey { case printer, size, fit, ink, action, copies, tag }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        printer = try c.decodeIfPresent(String.self, forKey: .printer)
        size = try c.decodeIfPresent(String.self, forKey: .size)
        fit = try c.decodeIfPresent(String.self, forKey: .fit).flatMap(FitMode.init(rawValue:))
        ink = try c.decodeIfPresent(String.self, forKey: .ink).flatMap(InkMode.init(rawValue:))
        action = try c.decodeIfPresent(RuleAction.self, forKey: .action)
        copies = max(1, try c.decodeIfPresent(Int.self, forKey: .copies) ?? 1)
        tag = try c.decodeIfPresent(FinderTag.self, forKey: .tag)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(printer, forKey: .printer)
        try c.encodeIfPresent(size, forKey: .size)
        try c.encodeIfPresent(fit?.rawValue, forKey: .fit)
        try c.encodeIfPresent(ink?.rawValue, forKey: .ink)
        try c.encodeIfPresent(action, forKey: .action)
        try c.encode(copies, forKey: .copies)
        try c.encodeIfPresent(tag, forKey: .tag)
    }
}

enum RuleAction: String, Codable, CaseIterable {
    /// Print after the short cancel countdown.
    case print
    /// Show the preview with Print / Cancel.
    case review
    /// Post a notification with Print / Preview buttons; for files you dropped, this is the same as review.
    case ask

    var title: String {
        switch self {
        case .print: "Print"
        case .review: "Show preview"
        case .ask: "Ask"
        }
    }

    var shortTitle: String {
        switch self {
        case .print: "prints"
        case .review: "shows preview"
        case .ask: "asks"
        }
    }
}

/// A Finder tag, written with its colour so "Printed" can be green.
struct FinderTag: Codable, Hashable {
    var name = "Printed"
    var color: Color = .green

    /// Finder's label numbers.
    enum Color: Int, Codable, CaseIterable {
        case none = 0, gray, green, purple, blue, yellow, red, orange
        var title: String { "\(self)".capitalized }
    }

    /// Adds the tag, keeping the file's other tags. Files that are gone or read-only are left alone.
    func apply(to url: URL) {
        let key = "com.apple.metadata:_kMDItemUserTags"
        var tags: [String] = []
        let size = getxattr(url.path, key, nil, 0, 0, 0)
        if size > 0 {
            var data = Data(count: size)
            _ = data.withUnsafeMutableBytes { getxattr(url.path, key, $0.baseAddress, size, 0, 0) }
            tags = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String] ?? []
        }
        tags.removeAll { $0.split(separator: "\n").first.map(String.init) == name }
        tags.append(color == .none ? name : "\(name)\n\(color.rawValue)")
        guard let data = try? PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0) else { return }
        _ = data.withUnsafeBytes { setxattr(url.path, key, $0.baseAddress, data.count, 0, 0) }
    }
}
