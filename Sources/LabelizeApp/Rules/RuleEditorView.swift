import AppKit
import LabelKit
import SwiftUI

/// The sheet for one rule: "If [all] of these are true … Then print it on …". Edits a copy; OK commits.
struct RuleEditorView: View {
    let printers: [PrinterInfo]
    /// The default printer, whose sizes apply when the rule doesn't pick a printer.
    let current: PrinterInfo?
    /// A printer's own settings, shown as "Default (…)".
    let defaults: (PrinterInfo) -> LabelOptions
    let onCommit: (Rule) -> Void
    @State private var draft: Rule
    @Environment(\.dismiss) private var dismiss

    init(rule: Rule, printers: [PrinterInfo], current: PrinterInfo?,
         defaults: @escaping (PrinterInfo) -> LabelOptions = { _ in LabelOptions() }, onCommit: @escaping (Rule) -> Void) {
        _draft = State(initialValue: rule)
        self.printers = printers
        self.current = current
        self.defaults = defaults
        self.onCommit = onCommit
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text(suggestedName))
                }
                conditionsSection
                OutcomeSections(outcome: $draft.outcome, printers: printers, current: current, defaults: defaults)
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if !draft.incompleteConditions.isEmpty {
                    Label("Fill in or remove the marked conditions.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    var rule = draft
                    if rule.name.trimmingCharacters(in: .whitespaces).isEmpty { rule.name = suggestedName }
                    onCommit(rule)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.incompleteConditions.isEmpty || draft.conditions.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 600, height: 700)
    }

    /// "Comes from amazon.com", from the first condition.
    private var suggestedName: String {
        guard let first = draft.conditions.first, first.isComplete else { return "Untitled Rule" }
        let p = RuleSummary.phrase(first)
        return p.prefix(1).uppercased() + p.dropFirst()
    }

    private var conditionsSection: some View {
        Section {
            ForEach($draft.conditions) { $condition in
                ConditionRow(condition: $condition, canRemove: draft.conditions.count > 1,
                             onAdd: { insert(after: condition.id) },
                             onRemove: { draft.conditions.removeAll { $0.id == condition.id } })
            }
        } header: {
            HStack(spacing: 6) {
                Text("If")
                Picker("Match", selection: $draft.matchAll) {
                    Text("all").tag(true)
                    Text("any").tag(false)
                }
                .labelsHidden().fixedSize()
                .accessibilityLabel("Match all or any conditions")
                Text("of these are true:")
            }
            .font(.body).foregroundStyle(.primary)
            .textCase(nil)
        }
    }

    private func insert(after id: RuleCondition.ID) {
        let i = (draft.conditions.firstIndex { $0.id == id } ?? draft.conditions.count - 1) + 1
        // A new row starts on a field the rule doesn't use yet.
        let used = Set(draft.conditions.map(\.field))
        let field = RuleCondition.Field.allCases.first { !used.contains($0) } ?? .name
        draft.conditions.insert(field.starter, at: i)
    }
}

/// "[Source website] [is] [amazon.com ×]  (−)(+)"
struct ConditionRow: View {
    @Binding var condition: RuleCondition
    let canRemove: Bool
    let onAdd: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("Field", selection: Binding(get: { condition.field }, set: { condition.change(to: $0) })) {
                ForEach(RuleCondition.Field.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().fixedSize()

            if condition.field.ops.count > 1 {
                Picker("Comparison", selection: $condition.op) {
                    ForEach(condition.field.ops, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
            } else {
                Text(condition.op.title)
            }

            value.frame(maxWidth: .infinity, alignment: .leading)

            if !condition.isComplete {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help(condition.field == .folder ? "Choose a folder" : "Add at least one value")
                    .accessibilityLabel("Incomplete condition")
            }
            Button(action: onRemove) { Image(systemName: "minus.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .disabled(!canRemove)
                .help("Remove condition").accessibilityLabel("Remove condition")
            Button(action: onAdd) { Image(systemName: "plus.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Add condition").accessibilityLabel("Add condition")
        }
    }

    @ViewBuilder private var value: some View {
        let field = condition.field
        if !condition.op.takesValue {
            EmptyView()
        } else if field.usesTokens {
            TokenField(tokens: $condition.values, placeholder: field.tokenPlaceholder,
                       normalize: field == .source ? RuleContext.normalizedDomain : { $0.trimmingCharacters(in: .whitespaces) })
                .accessibilityLabel(field.title)
        } else if field == .pageCount {
            HStack(spacing: 4) {
                TextField("Pages", value: $condition.number, format: .number)
                    .labelsHidden().frame(width: 44).multilineTextAlignment(.trailing)
                Stepper("Pages", value: $condition.number, in: 0...999).labelsHidden()
                Text(condition.number == 1 ? "page" : "pages")
            }
        } else if field == .folder {
            HStack(spacing: 6) {
                if let path = condition.values.first, !path.isEmpty {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 16, height: 16)
                    Text((path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        .help(path)
                }
                Button("Choose…") { chooseFolder() }
            }
        } else {
            Picker(field.title, selection: Binding(get: { condition.values.first ?? "" }, set: { condition.values = [$0] })) {
                ForEach(field.choices, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden().fixedSize()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        if let path = condition.values.first { panel.directoryURL = URL(fileURLWithPath: path) }
        if panel.runModal() == .OK, let url = panel.url { condition.values = [url.path] }
    }
}

/// "Then print it": printer, size, scaling, ink, what happens, copies; then the Finder tag.
/// Every field starts at Default and says what it inherits.
struct OutcomeSections: View {
    @Binding var outcome: RuleOutcome
    let printers: [PrinterInfo]
    let current: PrinterInfo?
    let defaults: (PrinterInfo) -> LabelOptions

    private var targetPrinter: PrinterInfo? {
        outcome.printer.flatMap { name in printers.first { $0.name == name } } ?? (outcome.printer == nil ? current : nil)
    }

    private var sizes: [LabelSize] {
        guard let p = targetPrinter else { return SizeCatalog.munbyn.filter { $0.width >= 2 } }
        return SizeCatalog.entries(for: p).filter(\.isSupported).map(\.size)
    }

    /// "Default (4 × 6 in)", from the target printer's settings.
    private func inherited(_ value: (LabelOptions) -> String) -> String {
        targetPrinter.map { "Default (\(value(defaults($0))))" } ?? "Default"
    }

    var body: some View {
        Section("Then print it") {
            Picker("Printer", selection: $outcome.printer) {
                Text(current.map { "Default printer (\($0.displayName))" } ?? "Default printer").tag(String?.none)
                Divider()
                ForEach(printers, id: \.name) { p in
                    Label(p.displayName, systemImage: p.isLabelPrinter ? "printer.dotmatrix" : "photo").tag(Optional(p.name))
                }
                if let name = outcome.printer, !printers.contains(where: { $0.name == name }) {
                    Text(RuleSummary.printerName(name, printers: printers)).tag(Optional(name))
                }
            }

            Picker("Label size", selection: $outcome.size) {
                Text(inherited { $0.size.display }).tag(String?.none)
                Divider()
                ForEach(sizes, id: \.self) { Text($0.display).tag(Optional($0.description)) }
                if let s = outcome.labelSize, !sizes.contains(s) {
                    Text("\(s.display) (not supported by this printer)").tag(Optional(s.description))
                }
            }

            Picker("Scaling", selection: $outcome.fit) {
                Text(inherited { $0.fit == .fit ? "Fit" : "Fill" }).tag(FitMode?.none)
                Divider()
                Text("Fit").tag(Optional(FitMode.fit))
                Text("Fill").tag(Optional(FitMode.fill))
            }

            Picker("Ink", selection: $outcome.ink) {
                Text(inherited { $0.ink.rawValue.capitalized }).tag(InkMode?.none)
                Divider()
                Text("Auto").tag(Optional(InkMode.auto))
                Text("Crisp").tag(Optional(InkMode.crisp))
                Text("Photo").tag(Optional(InkMode.photo))
                Text("Halftone").tag(Optional(InkMode.halftone))
            }
            .disabled(targetPrinter.map { !$0.isLabelPrinter } ?? false)
            .help("Label printers only")

            VStack(alignment: .leading, spacing: 4) {
                Picker("When a file matches", selection: $outcome.action) {
                    Text("Default").tag(RuleAction?.none)
                    Divider()
                    ForEach(RuleAction.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }
                Text(actionNote).font(.caption).foregroundStyle(.secondary)
            }

            LabeledContent("Copies") {
                HStack(spacing: 4) {
                    Text("\(outcome.copies)").monospacedDigit()
                    Stepper("Copies", value: $outcome.copies, in: 1...20).labelsHidden()
                }
            }
        }

        Section("After printing") {
            Toggle("Add Finder tag", isOn: Binding(get: { outcome.tag != nil }, set: { outcome.tag = $0 ? FinderTag() : nil }))
            if let tag = outcome.tag {
                HStack {
                    TextField("Tag", text: Binding(get: { tag.name }, set: { outcome.tag?.name = $0 }))
                    TagColorDots(color: Binding(get: { tag.color }, set: { outcome.tag?.color = $0 }))
                }
                .padding(.leading, 20)
            }
        }
    }

    private var actionNote: String {
        switch outcome.action {
        case nil: "Follows Before printing in General. Files in watched folders follow New files."
        case .print?: "You can still cancel during the countdown."
        case .review?: "Check the labels, then click Print."
        case .ask?: "Files in watched folders send a notification. Other files show the preview."
        }
    }
}

extension FinderTag.Color {
    var swatch: SwiftUI.Color {
        switch self {
        case .none: .secondary
        case .gray: .gray
        case .green: .green
        case .purple: .purple
        case .blue: .blue
        case .yellow: .yellow
        case .red: .red
        case .orange: .orange
        }
    }
}

/// `NSTokenField` for domains, names and code text. Commas or Return finish a token.
struct TokenField: NSViewRepresentable {
    @Binding var tokens: [String]
    var placeholder: String
    var normalize: (String) -> String

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.tokenStyle = .rounded
        field.objectValue = tokens
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.parent = self
        guard field.currentEditor() == nil, (field.objectValue as? [String]) != tokens else { return }
        field.objectValue = tokens
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: TokenField
        init(_ parent: TokenField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) { sync(note) }
        func controlTextDidEndEditing(_ note: Notification) { sync(note) }

        func tokenField(_ tokenField: NSTokenField, shouldAdd tokens: [Any], at index: Int) -> [Any] {
            tokens.compactMap { ($0 as? String).map(parent.normalize) }.filter { !$0.isEmpty }
        }

        private func sync(_ note: Notification) {
            guard let field = note.object as? NSTokenField else { return }
            let values = (field.objectValue as? [String] ?? []).map(parent.normalize).filter { !$0.isEmpty }
            if values != parent.tokens { parent.tokens = values }
        }
    }
}
