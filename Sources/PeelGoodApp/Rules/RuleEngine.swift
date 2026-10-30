import Foundation
import LabelKit
import PeelGoodCore
import PeelGoodShared

// MARK: Engine

/// The rule list, its persistence, and evaluation. One shared instance backs both the Settings pane and printing.
/// The model and the matching are PeelGoodCore's `RuleBook`, which `peelgood print` reads too.
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
        let loaded = fileURL.flatMap { RuleBook.load(from: $0) }
        rules = loaded?.rules ?? []
        fallback = loaded?.fallback ?? RuleBook.defaultFallback
    }

    nonisolated static var defaultFileURL: URL { AppPaths.rulesFile }

    var book: RuleBook { RuleBook(rules: rules, fallback: fallback) }

    /// True if any enabled rule looks at codes, so `RuleContext.inspect` should run detection.
    var needsCodes: Bool { book.needsCodes }
    var needsText: Bool { book.needsText }

    /// The first enabled rule that matches, else "Everything else".
    func match(_ context: RuleContext) -> Rule { book.match(context) }

    /// Picks printer and options for a file: see `RuleBook.decide`.
    func decide(_ context: RuleContext, printers: [PrinterInfo], current: PrinterInfo?,
                defaults: (PrinterInfo) -> LabelOptions, forcedPrinter: PrinterInfo? = nil,
                unattended: RuleAction = .ask) -> RuleDecision? {
        book.decide(context, printers: printers, current: current, defaults: defaults, forcedPrinter: forcedPrinter, unattended: unattended)
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
        saveTask?.cancel()
        do {
            try book.save(to: fileURL)
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
