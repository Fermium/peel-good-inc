import AppKit
import LabelKit
import PeelGoodCore
import SwiftUI

/// Size lists as a table: "4 × 6 in" on the left, the other unit right-aligned and dimmed.
@MainActor
enum SizeMenu {
    /// One title per size, with a right tab stop just past the widest row.
    static func titles(_ sizes: [LabelSize], fontSize: CGFloat) -> [NSAttributedString] {
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        func width(_ s: String) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: font]).width) }
        let style = NSMutableParagraphStyle()
        let tab = (sizes.map { width($0.primary) }.max() ?? 0) + 28 + (sizes.map { width($0.secondary) }.max() ?? 0)
        style.tabStops = [NSTextTab(textAlignment: .right, location: tab)]
        return sizes.map { s in
            let title = NSMutableAttributedString(string: "\(s.primary)\t", attributes: [.font: font, .paragraphStyle: style])
            title.append(NSAttributedString(string: s.secondary, attributes: [.font: font, .paragraphStyle: style,
                                                                             .foregroundColor: NSColor.secondaryLabelColor]))
            return title
        }
    }

    /// A menu item for one row; the tooltip and VoiceOver get the full "4 × 6 in (102 × 152 mm)".
    static func item(_ size: LabelSize, _ title: NSAttributedString, action: Selector?, note: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: size.display, action: action, keyEquivalent: "")
        item.attributedTitle = title
        item.subtitle = note
        item.representedObject = size
        let full = [size.display, note].compactMap { $0 }.joined(separator: ", ")
        item.toolTip = full
        item.setAccessibilityLabel(full)
        return item
    }
}

/// A size picker whose menu is a table (see `SizeMenu`); closed, it shows just "4 × 6 in".
/// SwiftUI's Picker flattens menu items to plain strings, hence the NSPopUpButton.
struct SizePopUp: NSViewRepresentable {
    @Binding var selection: LabelSize?
    var sizes: [LabelSize]
    /// A first "Default (…)" item, which picks nil.
    var defaultTitle: String?
    /// Shown disabled with a note, e.g. a rule's size the printer can't take.
    var unsupported: (size: LabelSize, note: String)?

    init(selection: Binding<LabelSize?>, sizes: [LabelSize], defaultTitle: String? = nil, unsupported: (LabelSize, String)? = nil) {
        _selection = selection
        self.sizes = sizes
        self.defaultTitle = defaultTitle
        self.unsupported = unsupported
    }

    init(selection: Binding<LabelSize>, sizes: [LabelSize]) {
        self.init(selection: Binding(get: { selection.wrappedValue }, set: { $0.map { selection.wrappedValue = $0 } }), sizes: sizes)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.autoenablesItems = false
        (button.cell as? NSPopUpButtonCell)?.usesItemFromMenu = false
        button.target = context.coordinator
        button.action = #selector(Coordinator.picked(_:))
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        let menu = button.menu ?? NSMenu()
        menu.removeAllItems()
        if let defaultTitle {
            let item = NSMenuItem(title: defaultTitle, action: nil, keyEquivalent: "")
            item.toolTip = defaultTitle
            menu.addItem(item)
            menu.addItem(.separator())
        }
        let all = sizes + (unsupported.map { [$0.size] } ?? [])
        for (size, title) in zip(all, SizeMenu.titles(all, fontSize: button.font?.pointSize ?? NSFont.systemFontSize)) {
            let isExtra = size == unsupported?.size && !sizes.contains(size)
            let item = SizeMenu.item(size, title, action: nil, note: isExtra ? unsupported?.note : nil)
            item.isEnabled = !isExtra
            menu.addItem(item)
        }
        let selected = menu.items.first { !$0.isSeparatorItem && $0.representedObject as? LabelSize == selection }
        for item in menu.items { item.state = item === selected ? .on : .off }
        button.select(selected)
        let full = selected?.toolTip ?? ""
        (button.cell as? NSPopUpButtonCell)?.menuItem = NSMenuItem(title: selection?.primary ?? defaultTitle ?? "", action: nil, keyEquivalent: "")
        button.toolTip = full
        button.setAccessibilityValue(full)
        button.invalidateIntrinsicContentSize()
    }

    @MainActor final class Coordinator: NSObject {
        var selection: Binding<LabelSize?>?
        @objc func picked(_ sender: NSPopUpButton) { selection?.wrappedValue = sender.selectedItem?.representedObject as? LabelSize }
    }
}
