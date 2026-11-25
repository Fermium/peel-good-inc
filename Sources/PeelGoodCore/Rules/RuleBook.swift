import Foundation
import LabelKit

// MARK: Matching

extension RuleCondition {
    public func matches(_ c: RuleContext) -> Bool {
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
            guard !c.unread.contains(RuleContext.unreadCodes) else { return false }   // unread: neither includes nor doesn't
            let kind = CodeKind(rawValue: value) ?? .any
            let hit = (c.codes ?? []).contains { kind.matches($0.symbology) }
            return op == .includes ? hit : !hit
        case .pageText:
            guard !c.unread.contains(RuleContext.unreadText) else { return false }
            let text = (c.pageText ?? "").lowercased()
            let hit = tokens.contains { text.contains($0.lowercased()) }
            return op == .contains ? hit : !hit
        case .codeText:
            guard !c.unread.contains(RuleContext.unreadCodes) else { return false }
            let t = tokens.map { $0.lowercased() }
            let hit = (c.codes ?? []).contains { code in t.contains { code.payload.lowercased().contains($0) } }
            return op == .contains ? hit : !hit
        }
    }
}

extension Rule {
    /// A rule with no complete conditions never matches, so a half-made rule can't swallow every file.
    public func matches(_ c: RuleContext) -> Bool {
        guard isEnabled, !conditions.isEmpty else { return false }
        return matchAll ? conditions.allSatisfy { $0.matches(c) } : conditions.contains { $0.matches(c) }
    }
}

// MARK: Decision

/// A rule's outcome made concrete for the printers that are actually connected.
public struct RuleDecision {
    /// The matching rule, or the "Everything else" rule.
    public var rule: Rule
    public var isFallback: Bool
    public var printer: PrinterInfo
    public var options: LabelOptions
    /// Never `.ask` for files someone handed over; those get `.review` instead.
    public var action: RuleAction
    public var copies: Int
    /// "Everything else" is always `.general`.
    public var tag: RuleTag
    /// Why something differs from the rule, e.g. its printer isn't connected.
    public var notes: [String]

    /// "Everything else", or the rule's name.
    public var ruleName: String { isFallback ? "Everything else" : rule.displayName }
}

// MARK: Rule book

/// The rule list and "Everything else", as saved in rules.json, and how a file is matched against them.
/// The app's `RuleEngine` edits one; `peelgood print` reads one.
public struct RuleBook: Codable {
    /// 2 since placements were renamed (fit → fill, fill → cover); older files are read with the old names.
    public static let currentVersion = 2
    public var version = RuleBook.currentVersion
    public var rules: [Rule]
    /// "Everything else": always last, never deleted, has no conditions. Its saved outcome is ignored.
    public var fallback: Rule

    public static let defaultFallback = Rule(name: "Everything else", conditions: [])

    public init(rules: [Rule] = [], fallback: Rule = RuleBook.defaultFallback) {
        self.rules = rules
        self.fallback = fallback
    }

    enum CodingKeys: String, CodingKey { case version, rules, fallback }

    /// The saved rules. A file that won't decode is set aside (rules.json.broken) when `setAsideBroken`,
    /// rather than overwritten later; readers that must not write (the CLI) leave it.
    public static func load(from url: URL, setAsideBroken: Bool = true) -> RuleBook? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let book = try? decode(data) { return book }
        if setAsideBroken {
            let aside = url.appendingPathExtension("broken")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
        }
        return nil
    }

    /// A rules.json, reading files older than version 2 with 0.5.4's placement names. The result is always
    /// the current version, so the next save writes today's names (the one-time migration).
    public static func decode(_ data: Data) throws -> RuleBook {
        struct Header: Decodable { var version: Int? }
        let version = (try? JSONDecoder().decode(Header.self, from: data))?.version ?? 1
        let decoder = JSONDecoder()
        decoder.userInfo[RuleOutcome.legacyNames] = version < 2
        var book = try decoder.decode(RuleBook.self, from: data)
        book.version = currentVersion
        return book
    }

    /// True when the file on disk predates version 2 and should be saved again with today's names.
    public static func needsMigration(_ url: URL) -> Bool {
        struct Header: Decodable { var version: Int? }
        guard let data = try? Data(contentsOf: url), let h = try? JSONDecoder().decode(Header.self, from: data) else { return false }
        return (h.version ?? 1) < currentVersion
    }

    public func save(to url: URL) throws {
        var book = self
        book.version = Self.currentVersion
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(book)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// True if any enabled rule looks at codes, so `RuleContext.inspect` should run detection.
    public var needsCodes: Bool {
        rules.contains { $0.isEnabled && $0.conditions.contains { $0.field == .code || $0.field == .codeText } }
    }

    public var needsText: Bool {
        rules.contains { $0.isEnabled && $0.conditions.contains { $0.field == .pageText } }
    }

    /// The first enabled rule that matches, else "Everything else".
    public func match(_ context: RuleContext) -> Rule {
        rules.first { $0.matches(context) } ?? fallback
    }

    /// Picks printer and options for a file.
    /// - Parameters:
    ///   - printers: the printers a rule may name (eligible ones); matched like everywhere else (`PrinterResolver.match`).
    ///   - current: the default printer, used when the rule doesn't name one or its printer is missing.
    ///   - defaults: the remembered options for a printer (`AppSettings.options(for:)`).
    ///   - forcedPrinter: the printer tile the file was dropped on, or the API's printer; it wins over the rule's.
    ///   - unattended: what a rule without an action does with files from watched folders (Rules > New files).
    /// - Returns: nil only when there's no printer at all.
    /// "Everything else" always uses the default printer and its settings; its saved outcome is ignored.
    public func decide(_ context: RuleContext, printers: [PrinterInfo], current: PrinterInfo?,
                       defaults: (PrinterInfo) -> LabelOptions, forcedPrinter: PrinterInfo? = nil,
                       unattended: RuleAction = .ask) -> RuleDecision? {
        let rule = match(context)
        let isFallback = rule.id == fallback.id
        let o = isFallback ? RuleOutcome() : rule.outcome
        var notes: [String] = []

        var printer = current
        if let name = o.printer {
            if let p = PrinterResolver.match(name, in: printers) { printer = p }
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
        if let scale = o.scale { options.scalePercent = min(max(scale, Limits.scalePercent.lowerBound), Limits.scalePercent.upperBound) }
        if let ink = o.ink { options.ink = ink }
        if let snap = o.snap { options.snapCodes = snap }

        var action = o.action ?? (context.trigger.isUnattended ? unattended : .print)
        if action == .ask && !context.trigger.isUnattended { action = .review }

        return RuleDecision(rule: rule, isFallback: isFallback, printer: printer, options: options,
                            action: action, copies: max(1, o.copies), tag: isFallback ? .general : o.tag, notes: notes)
    }
}
