import AppKit
import LabelKit
import SwiftUI
import UniformTypeIdentifiers

/// The Rules tab of Settings: an ordered list of rules (first match wins), "Everything else" last,
/// and a test well that shows what a file would do without printing it.
struct RulesSettingsView: View {
    @ObservedObject var engine: RuleEngine
    /// Supplies printers, the current printer and its remembered options. Created on appear when nil.
    private let providedStore: Store?
    /// Fixed printers for previews; skips CUPS.
    private let previewPrinters: [PrinterInfo]?

    @State private var store: Store?
    @State private var printers: [PrinterInfo] = []
    @State private var selection = Set<Rule.ID>()
    @State private var editing: EditRequest?
    @State private var test: TestResult?

    @MainActor
    init(engine: RuleEngine? = nil, store: Store? = nil, previewPrinters: [PrinterInfo]? = nil) {
        self.engine = engine ?? .shared
        self.providedStore = store
        self.previewPrinters = previewPrinters
    }

    private struct EditRequest: Identifiable {
        var rule: Rule
        var isNew: Bool
        var id: Rule.ID { rule.id }
    }

    private var current: PrinterInfo? {
        store?.printer ?? Printers.defaultLabelPrinter(in: printers) ?? printers.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The first rule that matches, from the top, decides how a file prints.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            WatchedFoldersRow()

            VStack(spacing: 0) {
                list
                Divider()
                FallbackRow(summary: RuleSummary.outcome(engine.fallback.outcome, printers: printers),
                            matched: test?.ruleID == engine.fallback.id) { edit(engine.fallback.id) }
                Divider()
                toolbar
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))

            TestFileBox(result: $test, engine: engine, printers: printers, current: current, decide: decide)
        }
        .padding(20)
        .frame(width: 680, height: 600)
        .onAppear(perform: loadPrinters)
        .sheet(item: $editing) { request in
            RuleEditorView(rule: request.rule, isFallback: request.rule.id == engine.fallback.id,
                           printers: printers, current: current) { rule in
                if request.isNew { engine.add(rule); selection = [rule.id] } else { engine.update(rule) }
            }
        }
    }

    // MARK: List

    private var list: some View {
        List(selection: $selection) {
            ForEach($engine.rules) { $rule in
                RuleRow(rule: $rule, summary: summary(rule), matched: test?.ruleID == rule.id)
                    .tag(rule.id)
            }
            .onMove { engine.rules.move(fromOffsets: $0, toOffset: $1) }

            if engine.rules.isEmpty {
                Text("No rules. Click + to add one.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                    .selectionDisabled()
            }

        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .frame(minHeight: 200, maxHeight: .infinity)
        .contextMenu(forSelectionType: Rule.ID.self) { ids in
            if ids.count == 1, let id = ids.first {
                Button("Edit…") { edit(id) }
                if id != engine.fallback.id {
                    Button("Duplicate") { engine.duplicate(id) }
                    Button("Move to Top") { moveToTop(id) }
                }
            }
            if !ids.subtracting([engine.fallback.id]).isEmpty {
                Divider()
                Button("Delete", role: .destructive) { delete(ids) }
            }
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first { edit(id) }
        }
        .onDeleteCommand { delete(selection) }
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            Menu {
                Button("New Rule…") { newRule() }
                Divider()
                Section("Start from a template") {
                    ForEach(RuleTemplate.allCases) { t in
                        Button { addTemplate(t) } label: { Label(t.title, systemImage: t.symbol) }
                    }
                }
            } label: {
                Image(systemName: "plus").frame(width: 24, height: 20)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Add a rule").accessibilityLabel("Add Rule")

            Divider().frame(height: 16)

            Button { delete(selection) } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                .buttonStyle(.borderless)
                .disabled(selection.subtracting([engine.fallback.id]).isEmpty)
                .help("Delete the selected rule").accessibilityLabel("Delete Rule")

            Spacer()

            Text("Drag to reorder.").font(.caption).foregroundStyle(.tertiary)
                .padding(.trailing, 8)
            Button("Edit…") { selection.first.map(edit) }
                .disabled(selection.count != 1)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
    }

    private func summary(_ rule: Rule) -> String {
        "If it \(RuleSummary.conditions(rule)) → \(RuleSummary.outcome(rule.outcome, printers: printers))"
    }

    // MARK: Actions

    private func loadPrinters() {
        if let previewPrinters { printers = previewPrinters; return }
        let s = providedStore ?? store ?? Store()
        s.refresh()
        store = s
        printers = s.eligiblePrinters
    }

    private func decide(_ ctx: RuleContext) -> RuleDecision? {
        engine.decide(ctx, printers: printers, current: current, defaults: { p in store?.options(for: p) ?? LabelOptions() })
    }

    private func edit(_ id: Rule.ID) {
        if id == engine.fallback.id { editing = EditRequest(rule: engine.fallback, isNew: false) }
        else if let rule = engine.rules.first(where: { $0.id == id }) { editing = EditRequest(rule: rule, isNew: false) }
    }

    private func newRule() {
        editing = EditRequest(rule: Rule(name: "", conditions: [RuleCondition.Field.source.starter]), isNew: true)
    }

    /// Templates open in the editor so the user sees exactly what they're adding.
    private func addTemplate(_ t: RuleTemplate) {
        editing = EditRequest(rule: t.make(printers: printers), isNew: true)
    }

    private func delete(_ ids: Set<Rule.ID>) {
        let ids = ids.subtracting([engine.fallback.id])
        guard !ids.isEmpty else { return }
        engine.remove(ids)
        selection.subtract(ids)
    }

    private func moveToTop(_ id: Rule.ID) {
        guard let i = engine.rules.firstIndex(where: { $0.id == id }) else { return }
        engine.rules.move(fromOffsets: [i], toOffset: 0)
    }
}

// MARK: Rows

private struct RuleRow: View {
    @Binding var rule: Rule
    let summary: String
    let matched: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle("Enabled", isOn: $rule.isEnabled)
                .toggleStyle(.checkbox).labelsHidden()
                .accessibilityLabel("Use “\(rule.displayName)”")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rule.displayName).fontWeight(.medium)
                    if !rule.incompleteConditions.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).imageScale(.small)
                            .help("Has blank conditions, so it never matches.")
                    }
                }
                Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            .opacity(rule.isEnabled ? 1 : 0.5)
            Spacer(minLength: 8)
            if matched { MatchBadge() }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// Pinned under the list so it's always visible and can't be moved or deleted.
private struct FallbackRow: View {
    let summary: String
    let matched: Bool
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary).frame(width: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Everything else").fontWeight(.medium)
                Text("Any other file: \(summary)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if matched { MatchBadge() }
            Button("Edit…", action: onEdit).controlSize(.small)
                .accessibilityLabel("Edit Everything else")
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
        .help("Applies when no rule above matches.")
        .accessibilityElement(children: .combine)
    }
}

private struct MatchBadge: View {
    var body: some View {
        Label("Matches", systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(.green)
            .accessibilityLabel("Matches the test file")
    }
}

// MARK: Test a file

struct TestResult {
    var url: URL
    var context: RuleContext
    var ruleID: Rule.ID?
}

/// Drop or choose a file; shows the matching rule and the settings it would print with. Never prints.
private struct TestFileBox: View {
    @Binding var result: TestResult?
    @ObservedObject var engine: RuleEngine
    let printers: [PrinterInfo]
    let current: PrinterInfo?
    let decide: (RuleContext) -> RuleDecision?

    @State private var trigger: RuleTrigger = .drop
    @State private var targeted = false
    @State private var inspecting = false
    @State private var highlightToken = UUID()

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 14) {
                well
                VStack(alignment: .leading, spacing: 6) {
                    details
                    Spacer(minLength: 0)
                    Picker("Test as", selection: $trigger) {
                        ForEach(RuleTrigger.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                    .font(.callout)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(6)
            .frame(height: 112)
        } label: {
            Text("Test a File")
        }
        .onChange(of: trigger) { refresh() }
        .onChange(of: engine.rules) { refresh() }
        .onChange(of: engine.fallback) { refresh() }
    }

    private var well: some View {
        VStack(spacing: 6) {
            if let url = result?.url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 36, height: 36)
            } else {
                Image(systemName: "doc.viewfinder").font(.system(size: 26)).foregroundStyle(.secondary)
            }
            Button("Choose…", action: choose).controlSize(.small)
        }
        .frame(width: 104, height: 100)
        .background(RoundedRectangle(cornerRadius: 8).fill(targeted ? Color.accentColor.opacity(0.15) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL) else { return false }
            inspect(url)
            return true
        } isTargeted: { targeted = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop a file to test")
    }

    @ViewBuilder private var details: some View {
        if inspecting {
            HStack { ProgressView().controlSize(.small); Text("Reading file…").foregroundStyle(.secondary) }
        } else if let result, let d = decide(result.context) {
            Text(result.url.lastPathComponent).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
            Group {
                if d.isFallback {
                    Text("Matches **Everything else**.")
                } else {
                    Text("Matches **\(d.rule.displayName)**.")
                }
            }
            Text("\(d.printer.displayName) · \(d.options.size.display) · \(d.options.fit == .fit ? "Fit" : "Fill") · "
                 + "\(d.printer.isLabelPrinter ? d.options.ink.rawValue.capitalized + " · " : "")\(d.action.title)"
                 + (d.copies > 1 ? " · \(d.copies) copies" : ""))
                .font(.callout)
            ForEach(d.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            Text(RuleSummary.facts(result.context)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .help(RuleSummary.facts(result.context))
        } else if result != nil {
            Text("No printer is connected.").foregroundStyle(.secondary)
        } else {
            Text("Drop a file to see which rule it matches. Nothing prints.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .svg, .image]
        panel.prompt = "Test"
        if panel.runModal() == .OK, let url = panel.url { inspect(url) }
    }

    private func inspect(_ url: URL) {
        inspecting = true
        let trigger = trigger
        Task {
            let ctx = await Task.detached(priority: .userInitiated) {
                RuleContext.inspect(url, trigger: trigger, detectCodes: true, readText: true)
            }.value
            result = TestResult(url: url, context: ctx, ruleID: nil)
            inspecting = false
            refresh()
        }
    }

    /// Re-evaluates the same file after the trigger or the rules change; no need to re-read it.
    private func refresh() {
        guard var r = result else { return }
        r.context.trigger = trigger
        r.ruleID = engine.match(r.context).id
        result = r
        // The highlight on the matching rule fades after a few seconds; the details stay.
        let token = UUID()
        highlightToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            guard highlightToken == token else { return }
            withAnimation(.easeOut(duration: 0.4)) { result?.ruleID = nil }
        }
    }
}

#Preview("Rules") {
    RulesSettingsView(engine: RulesPreviewData.engine(), previewPrinters: RulesPreviewData.printers)
}
