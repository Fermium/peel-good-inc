import Foundation
import LabelKit

// MARK: Matching

extension RuleCondition {
    func matches(_ c: RuleContext) -> Bool {
        guard isComplete else { return false }
        let tokens = values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let value = tokens.first ?? ""
        switch field {
        case .source:
            let hosts = c.sourceHosts
            if op == .isUnknown { return hosts.isEmpty }
            let domains = tokens.map(RuleContext.normalizedDomain)
            let hit = hosts.contains { h in domains.contains { h == $0 || h.hasSuffix("." + $0) } }
            return op == .is ? hit : !hit
        case .name:
            let full = c.fileName.lowercased(), stem = (c.fileName as NSString).deletingPathExtension.lowercased()
            let t = tokens.map { $0.lowercased() }
            switch op {
            case .contains: return t.contains { full.contains($0) }
            case .doesNotContain: return !t.contains { full.contains($0) }
            case .beginsWith: return t.contains { full.hasPrefix($0) }
            case .endsWith: return t.contains { full.hasSuffix($0) || stem.hasSuffix($0) }
            default: return t.contains { full == $0 || stem == $0 }
            }
        case .kind:
            let hit: Bool = switch FileKind(rawValue: value) {
            case .screenshot: c.isScreenshot
            case .image: c.kind == .image || c.kind == .screenshot
            case let k?: c.kind == k
            case nil: false
            }
            return op == .is ? hit : !hit
        case .folder:
            guard let folder = c.folder?.resolvingSymlinksInPath().standardizedFileURL.path else { return op == .isNotInside }
            let inside = tokens.contains { t in
                let base = URL(fileURLWithPath: (t as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL.path
                return folder == base || folder.hasPrefix(base.hasSuffix("/") ? base : base + "/")
            }
            return op == .isInside ? inside : !inside
        case .trigger:
            let hit = c.trigger.rawValue == value
            return op == .is ? hit : !hit
        case .pageSize:
            // Screenshots and photos have no physical size, so they never count as a page size.
            let hit = !c.isRaster && c.firstPageSize.map { PageShape(rawValue: value)?.matches($0) ?? false } ?? false
            return op == .is ? hit : !hit
        case .pageCount:
            switch op {
            case .isMoreThan: return c.pageCount > number
            case .isFewerThan: return c.pageCount < number
            default: return c.pageCount == number
            }
        case .code:
            let kind = CodeKind(rawValue: value) ?? .any
            let hit = (c.codes ?? []).contains { kind.matches($0.symbology) }
            return op == .includes ? hit : !hit
        case .pageText:
            let text = (c.pageText ?? "").lowercased()
            let hit = tokens.contains { text.contains($0.lowercased()) }
            return op == .contains ? hit : !hit
        case .codeText:
            let t = tokens.map { $0.lowercased() }
            let hit = (c.codes ?? []).contains { code in t.contains { code.payload.lowercased().contains($0) } }
            return op == .contains ? hit : !hit
        }
    }
}

extension Rule {
    /// A rule with no complete conditions never matches, so a half-made rule can't swallow every file.
    func matches(_ c: RuleContext) -> Bool {
        guard isEnabled, !conditions.isEmpty else { return false }
        return matchAll ? conditions.allSatisfy { $0.matches(c) } : conditions.contains { $0.matches(c) }
    }
}

// MARK: Decision

/// A rule's outcome made concrete for the printers that are actually connected.
struct RuleDecision {
    /// The matching rule, or the "Everything else" rule.
    var rule: Rule
    var isFallback: Bool
    var printer: PrinterInfo
    var options: LabelOptions
    /// Never `.ask` for files the user handed over directly; those get `.review` instead.
    var action: RuleAction
    var copies: Int
    var tag: FinderTag?
    var playSound: Bool
    /// Why something differs from the rule, e.g. its printer isn't connected.
    var notes: [String]
}

// MARK: Engine

/// The rule list, its persistence, and evaluation. One shared instance backs both the Settings pane and printing.
@MainActor
final class RuleEngine: ObservableObject {
    static let shared = RuleEngine()

    @Published var rules: [Rule] { didSet { scheduleSave() } }
    /// "Everything else": always last, never deleted, has no conditions.
    @Published var fallback: Rule { didSet { scheduleSave() } }

    let fileURL: URL?
    private var saveTask: Task<Void, Never>?

    /// `fileURL: nil` keeps rules in memory only (previews, tests).
    init(fileURL: URL? = RuleEngine.defaultFileURL) {
        self.fileURL = fileURL
        let loaded = fileURL.flatMap(Self.load)
        rules = loaded?.rules ?? []
        fallback = loaded?.fallback ?? Self.defaultFallback
    }

    static let defaultFallback = Rule(name: "Everything else", conditions: [])

    nonisolated static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Labelize/rules.json")
    }

    /// True if any enabled rule looks at codes, so `RuleContext.inspect` should run detection.
    var needsCodes: Bool {
        rules.contains { $0.isEnabled && $0.conditions.contains { $0.field == .code || $0.field == .codeText } }
    }

    var needsText: Bool {
        rules.contains { $0.isEnabled && $0.conditions.contains { $0.field == .pageText } }
    }

    /// The first enabled rule that matches, else "Everything else".
    func match(_ context: RuleContext) -> Rule {
        rules.first { $0.matches(context) } ?? fallback
    }

    /// Picks printer and options for a file.
    /// - Parameters:
    ///   - current: the printer selected in the menu, used when the rule doesn't name one or its printer is missing.
    ///   - defaults: the remembered options for a printer (`Store.options(for:)`).
    ///   - forcedPrinter: the printer tile the file was dropped on; it wins over the rule's printer.
    /// - Returns: nil only when there's no printer at all.
    func decide(_ context: RuleContext, printers: [PrinterInfo], current: PrinterInfo?,
                defaults: (PrinterInfo) -> LabelOptions, forcedPrinter: PrinterInfo? = nil) -> RuleDecision? {
        let rule = match(context)
        let o = rule.outcome
        var notes: [String] = []

        var printer = current
        if let name = o.printer {
            if let p = printers.first(where: { $0.name == name }) { printer = p }
            else if let current { notes.append("The rule's printer isn't connected, so this uses \(current.displayName).") }
        }
        if let forcedPrinter { printer = forcedPrinter }
        guard let printer else { return nil }

        var options = defaults(printer)
        if let size = o.labelSize {
            if let resolved = printer.resolve(size) { options.size = resolved }
            else { notes.append("\(printer.displayName) can't take \(size.display) labels, so this uses \(options.size.display).") }
        }
        if let fit = o.fit { options.fit = fit }
        if let ink = o.ink { options.ink = ink }

        var action = o.action ?? (context.trigger.isUnattended ? .ask : .print)
        if action == .ask && !context.trigger.isUnattended { action = .review }

        return RuleDecision(rule: rule, isFallback: rule.id == fallback.id, printer: printer, options: options,
                            action: action, copies: max(1, o.copies), tag: o.tag, playSound: o.playSound, notes: notes)
    }

    // MARK: Editing

    func add(_ rule: Rule) { rules.append(rule) }

    func duplicate(_ id: Rule.ID) {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
        var copy = rules[i]
        copy.id = UUID()
        copy.name += " copy"
        copy.conditions = copy.conditions.map { var c = $0; c.id = UUID(); return c }
        rules.insert(copy, at: i + 1)
    }

    func remove(_ ids: Set<Rule.ID>) { rules.removeAll { ids.contains($0.id) } }

    func update(_ rule: Rule) {
        if rule.id == fallback.id { fallback = rule }
        else if let i = rules.firstIndex(where: { $0.id == rule.id }) { rules[i] = rule }
    }

    // MARK: Persistence

    private struct File: Codable {
        var version = 1
        var rules: [Rule]
        var fallback: Rule
    }

    /// A file that won't decode is set aside (rules.json.broken) rather than overwritten.
    private static func load(_ url: URL) -> File? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let file = try? JSONDecoder().decode(File.self, from: data) { return file }
        let aside = url.appendingPathExtension("broken")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
        return nil
    }

    private func scheduleSave() {
        guard fileURL != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        saveTask?.cancel()
        do {
            let data = try encoder.encode(File(rules: rules, fallback: fallback))
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error(.rules, "couldn't save rules: \(error.localizedDescription)")
        }
    }
}

// MARK: Templates

enum RuleTemplate: CaseIterable, Identifiable {
    case amazonReturns, royalMail, letterLabels, photosToColor
    var id: Self { self }

    var title: String {
        switch self {
        case .amazonReturns: "Amazon returns"
        case .royalMail: "Royal Mail / Click & Drop"
        case .letterLabels: "Shipping labels from Letter pages"
        case .photosToColor: "Photos to the color printer"
        }
    }

    var symbol: String {
        switch self {
        case .amazonReturns: "qrcode"
        case .royalMail: "shippingbox"
        case .letterLabels: "doc.text"
        case .photosToColor: "photo"
        }
    }

    func make(printers: [PrinterInfo]) -> Rule {
        let label = Printers.defaultLabelPrinter(in: printers)?.name
        let color = printers.first { !$0.isLabelPrinter && $0.resolve(.fourBySix) != nil }?.name
        func c(_ field: RuleCondition.Field, _ op: RuleCondition.Op, _ values: String...) -> RuleCondition {
            RuleCondition(field: field, op: op, values: values)
        }
        var o = RuleOutcome()
        o.printer = label
        switch self {
        case .amazonReturns:
            // Return codes arrive as screenshots with no source website; Amazon's return QR text starts with "Amazon ".
            o.ink = .crisp
            return Rule(name: title, conditions: [c(.code, .includes, CodeKind.qr.rawValue), c(.codeText, .contains, "Amazon ")], outcome: o)
        case .royalMail:
            // Click & Drop PDFs have no source website; the label text and the Mailmark code ("JGB …") identify them.
            o.ink = .crisp
            return Rule(name: title, matchAll: false,
                        conditions: [c(.pageText, .contains, "Click & Drop", "Royal Mail"), c(.codeText, .contains, "JGB "),
                                     c(.source, .is, "royalmail.com", "parcel.royalmail.com")], outcome: o)
        case .letterLabels:
            o.ink = .crisp
            o.action = .review
            return Rule(name: title, conditions: [c(.kind, .is, FileKind.pdf.rawValue), c(.pageSize, .is, PageShape.letter.rawValue),
                                                  c(.code, .includes, CodeKind.any.rawValue)], outcome: o)
        case .photosToColor:
            o.printer = color
            o.size = "4x6"
            o.fit = .fill
            o.ink = .photo
            o.action = .review
            let name = printers.first { $0.name == color }.map { "Photos to \($0.displayName)" } ?? title
            return Rule(name: name, conditions: [c(.kind, .is, FileKind.image.rawValue), c(.kind, .isNot, FileKind.screenshot.rawValue),
                                                  c(.code, .doesNotInclude, CodeKind.any.rawValue)], outcome: o)
        }
    }
}
