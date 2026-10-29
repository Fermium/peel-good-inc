import AppKit
import LabelKit
import SwiftUI

/// Sample printers and rules for `#Preview` and the launch-argument harness.
@MainActor
enum RulesPreviewData {
    static let printers: [PrinterInfo] = [
        PrinterInfo(name: "Label_Printer_ITPP941AP", makeAndModel: "Label Printer ITPP941AP", isDefault: true, state: .idle,
                    presets: SizeCatalog.munbyn.filter { $0.width >= 2 && $0.height >= 1.25 },
                    customMin: LabelSize(width: 1, height: 1), customMax: LabelSize(width: 4.25, height: 11)),
        PrinterInfo(name: "Canon_TS9500_series", makeAndModel: "Canon TS9500 series", state: .idle,
                    presets: [LabelSize(width: 4, height: 6), LabelSize(width: 5, height: 7), LabelSize(width: 8.5, height: 11)]),
    ]

    static func engine() -> RuleEngine {
        let e = RuleEngine(fileURL: nil)
        e.rules = [RuleTemplate.royalMail, .amazonReturns, .letterLabels, .photosToColor].map { $0.make(printers: printers) }
        e.rules[2].isEnabled = false
        return e
    }
}

#Preview("Rule editor") {
    RuleEditorView(rule: RuleTemplate.amazonReturns.make(printers: RulesPreviewData.printers), isFallback: false,
                   printers: RulesPreviewData.printers, current: RulesPreviewData.printers[0]) { _ in }
}

/// Temporary: `LabelizeApp -showRules` opens the pane in a window;
/// `LabelizeApp -renderRules /tmp/rules` writes rules.png and editor.png offscreen and quits;
/// `LabelizeApp -matchRules file…` prints which sample rule each file matches.
@MainActor
enum RulesPreviewHarness {
    private static var window: NSWindow?

    /// Returns true when it handled the launch, so the caller should skip normal setup.
    static func handleLaunchArguments() -> Bool {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "-renderRules"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let suffix = appearance == .aqua ? "" : "-dark"
                render(RulesSettingsView(engine: RulesPreviewData.engine(), previewPrinters: RulesPreviewData.printers),
                       to: dir.appendingPathComponent("rules\(suffix).png"), appearance: appearance)
                render(RuleEditorView(rule: RuleTemplate.amazonReturns.make(printers: RulesPreviewData.printers), isFallback: false,
                                      printers: RulesPreviewData.printers, current: RulesPreviewData.printers[0]) { _ in },
                       to: dir.appendingPathComponent("editor\(suffix).png"), appearance: appearance)
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "-matchRules") {
            let engine = RulesPreviewData.engine()
            engine.rules[2].isEnabled = true
            for path in args[(i + 1)...] {
                let ctx = RuleContext.inspect(URL(fileURLWithPath: path), trigger: .drop, detectCodes: engine.needsCodes)
                let d = engine.decide(ctx, printers: RulesPreviewData.printers, current: RulesPreviewData.printers[0], defaults: { _ in LabelOptions() })
                print("\((path as NSString).lastPathComponent): \(d?.rule.displayName ?? "-") → \(d?.printer.displayName ?? "-") \(d?.options.size.display ?? "") \(d?.action.rawValue ?? "") | \(RuleSummary.facts(ctx))")
            }
            exit(0)
        }
        guard args.contains("-showRules") else { return false }
        let w = NSWindow(contentViewController: NSHostingController(rootView: RulesSettingsView()))
        w.title = "Rules"
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window = w
        return true
    }

    private static func render<V: View>(_ view: V, to url: URL, appearance: NSAppearance.Name) {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: appearance)
        w.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
