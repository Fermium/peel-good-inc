import AppKit
import LabelKit
import PeelGoodCore
import SwiftUI

/// Sample printers and rules for `#Preview`, screenshots and tests.
@MainActor
enum RulesPreviewData {
    static let printers: [PrinterInfo] = [
        PrinterInfo(name: "Label_Printer_ITPP941AP", makeAndModel: "Label Printer ITPP941AP", isDefault: true, state: .idle,
                    presets: SizeCatalog.standard.filter { $0.width >= 2 && $0.height >= 1.25 },
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
    RuleEditorView(rule: RuleTemplate.amazonReturns.make(printers: RulesPreviewData.printers),
                   printers: RulesPreviewData.printers, current: RulesPreviewData.printers[0]) { _ in }
}
