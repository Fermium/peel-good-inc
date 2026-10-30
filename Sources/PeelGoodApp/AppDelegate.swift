import AppKit
import LabelKit
import PeelGoodCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, JobPresenter, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, NSDraggingDestination {
    let store = Store()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var job: PrintJob?
    private var dropZoneWatch: Timer?
    private var dragEnteredAt: Date?
    private lazy var settings = SettingsWindowController(store: store, testLabel: { [weak self] printer in self?.startTestLabel(on: printer, review: false) })

    /// Hovering this long over the icon with a file brings up the printer choice.
    static let holdForPrinterChoice: TimeInterval = 0.8

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Screenshots.runIfRequested(store: store) { return }
        Log.notice(.app, "Peel Good Inc. \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") started, \(store.printers.count) printers, default \(store.printer?.name ?? "none")")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.wantsLayer = true
        setIcon(filled: false)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Two drop targets: a view over the icon (the usual way), and the status bar window,
        // which forwards drags to its delegate. Whichever AppKit picks calls the same methods.
        if let button = statusItem.button {
            let target = StatusDropView(frame: button.bounds)
            target.autoresizingMask = [.width, .height]
            target.delegate = self
            target.registerForDraggedTypes(Intake.pasteboardTypes)
            button.addSubview(target)
            button.window?.registerForDraggedTypes(Intake.pasteboardTypes)
            button.window?.delegate = self
            Log.info(.drop, "drop targets registered for \(Intake.pasteboardTypes.count) types")
        } else {
            Log.error(.drop, "status item has no button; drops won't work")
        }

        popover.behavior = .transient
        popover.animates = true

        History.prune(keepingDays: store.historyDays)
        Notifier.shared.setUp()
        Notifier.shared.onAction = { [weak self] url, print in
            self?.printOnDefault([url], trigger: .watchedFolder, override: print ? .print : .review)
        }
        FolderWatcher.shared.onFile = { [weak self] url in self?.printOnDefault([url], trigger: .watchedFolder) }
        FolderWatcher.shared.start()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        let api = AppLabelService(store: store)
        api.presenter = self
        APIController.shared.attach(api)

        if CommandLine.arguments.contains("-previewTestLabel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { self.startTestLabel(on: self.store.printer, review: true) } }
        }
        if let i = CommandLine.arguments.firstIndex(of: "-showSettings") {
            let tab = CommandLine.arguments.dropFirst(i + 1).first.flatMap { $0.hasPrefix("-") ? nil : $0 }
            settings.show(tab: tab)
        }
        if CommandLine.arguments.contains("-showLogs") { LogWindow.show() }

    }

    func applicationWillTerminate(_ notification: Notification) {
        RuleEngine.shared.save()
    }

    /// Open With, dropping on the app icon, `open -a "Peel Good Inc." file.pdf`.
    func application(_ application: NSApplication, open urls: [URL]) {
        Log.info(.intake, "asked to open \(urls.map(\.lastPathComponent).joined(separator: ", "))")
        printOnDefault(urls.filter(Intake.isSupported), trigger: .openWith)
    }

    // MARK: Icon

    /// The printer glyph drawn by scripts/make-menubar-icon.swift, outline normally and solid while a
    /// file hovers. Falls back to an SF Symbol when the PDFs are missing (e.g. `swift run`).
    /// The app's own printer artwork, in color, at menu bar height (vector, so sharp at any scale).
    private lazy var menuBarIcon: NSImage? = {
        guard let image = Bundle.main.url(forResource: "icon", withExtension: "svg").flatMap(NSImage.init(contentsOf:)) else {
            let symbol = NSImage(systemSymbolName: "printer", accessibilityDescription: "Peel Good Inc.")
            symbol?.isTemplate = true
            return symbol
        }
        let height: CGFloat = 18
        image.size = NSSize(width: height * image.size.width / image.size.height, height: height)
        image.isTemplate = false
        image.accessibilityDescription = "Peel Good Inc."
        return image
    }()

    /// Hover is shown with the bounce and a slight dim, so the icon itself stays the same.
    private func setIcon(filled: Bool) {
        statusItem.button?.image = menuBarIcon
        statusItem.button?.alphaValue = filled ? 0.75 : 1
    }

    /// A small lift-and-settle when a file hovers over the icon.
    private func bounceIcon() {
        guard let layer = statusItem.button?.layer else { return }
        let bounce = CAKeyframeAnimation(keyPath: "transform.translation.y")
        bounce.values = [0, 3, -1, 0]
        bounce.duration = 0.35
        layer.add(bounce, forKey: "bounce")
    }

    private func shake() {
        guard let layer = statusItem.button?.layer else { return }
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -4, 4, -3, 3, 0]
        shake.duration = 0.3
        layer.add(shake, forKey: "shake")
    }

    // MARK: Dragging onto the icon

    /// A plain drop prints on the default printer. Holding over the icon, or pressing ⌘,
    /// brings up a tile per printer to drop on instead.
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let types = sender.draggingPasteboard.types?.map(\.rawValue).joined(separator: ", ") ?? "none"
        guard Intake.canRead(sender.draggingPasteboard) else {
            Log.warning(.drop, "drag entered, nothing printable: \(types)")
            shake()
            return []
        }
        // Both drop targets see the same drag; react once.
        if let entered = dragEnteredAt, Date().timeIntervalSince(entered) < 0.5 { return .copy }
        Log.info(.drop, "drag entered: \(types)")
        setIcon(filled: true)
        bounceIcon()
        dragEnteredAt = Date()
        if NSEvent.modifierFlags.contains(.command) { showDropZones() }
        return .copy
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let enteredAt = dragEnteredAt else { return [] }
        if NSEvent.modifierFlags.contains(.command) || Date().timeIntervalSince(enteredAt) >= Self.holdForPrinterChoice {
            showDropZones()
        }
        return .copy
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        // The second target's "entered" can follow the first one's "exited" immediately;
        // keep the hover state briefly so the pair reads as one hover.
        let entered = dragEnteredAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.dragEnteredAt == entered, entered != nil else { return }
            Log.debug(.drop, "drag exited")
            self.dragEnteredAt = nil
            self.setIcon(filled: false)
        }
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragEnteredAt = nil
        setIcon(filled: false)
        let review = NSEvent.modifierFlags.contains(.option)
        Log.info(.drop, "dropped\(review ? " with ⌥" : "")")
        Task {
            let files = await Intake.files(from: sender.draggingPasteboard, name: "Dropped")
            Log.info(.drop, "drop gave \(files.count) file(s): \(files.map(\.lastPathComponent).joined(separator: ", "))")
            if files.isEmpty { shake() } else { printOnDefault(files, review: review) }
        }
        return true
    }

    // MARK: Drop zones

    private func showDropZones() {
        store.refresh()
        let printers = store.eligiblePrinters
        guard printers.count > 1, job == nil, !popover.isShown else { return }
        let view = DropZonesView(printers: printers, current: store.printer?.name, sizeFor: { [store] in store.size(for: $0) }) { [weak self] files, printer in
            self?.printOnDefault(files, forcedPrinter: printer)
        }
        show(NSHostingController(rootView: view))
        // Close the zones once the drag ends without a drop.
        dropZoneWatch?.invalidate()
        dropZoneWatch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                if NSEvent.pressedMouseButtons == 0 {
                    timer.invalidate()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if self.job == nil { self.popover.performClose(nil) }
                    }
                }
            }
        }
    }

    // MARK: Jobs

    /// Files handed over by drop, clipboard, Open With, Services or Share, and files from watched folders:
    /// the first file's matching rule picks printer, size, fit, ink, copies and whether to review first (`JobFlow.plan`).
    private func printOnDefault(_ files: [URL], review: Bool = false, trigger: RuleTrigger = .drop, forcedPrinter: PrinterInfo? = nil,
                                override: RuleAction? = nil) {
        guard let first = files.first else { return }
        store.refresh()
        Task {
            guard let plan = try? await JobFlow.plan(files, trigger: trigger, store: store, engine: .shared, forcedPrinter: forcedPrinter,
                                                     review: review, action: override) else {
                Log.error(.rules, "no printer for \(first.lastPathComponent)")
                NSAlert(error: NSError(domain: "PeelGood", code: 1, userInfo: [NSLocalizedDescriptionKey: "No label printer found."])).runModal()
                return
            }
            // Files that turn up on their own ask first, with a notification.
            if plan.action == .ask {
                Notifier.shared.ask(first, detail: "Print on \(plan.printer.displayName) at \(plan.options.size.display)?")
                return
            }
            present(JobFlow.makeJob(plan, store: store))
        }
    }

    /// Shows a job in the popover and starts it. Drops come here through `start`, API prints directly.
    func present(_ job: PrintJob) {
        dropZoneWatch?.invalidate()
        if let current = self.job, current.phase != .done {
            Log.warning(.job, "replacing an unfinished job (\(current.files.map(\.lastPathComponent).joined(separator: ", ")))")
        }
        Sounds.play(Sounds.dropped, if: store.playSounds)
        job.onFinish = { [weak self, weak job] in
            guard let self, self.job === job else { return }
            self.popover.performClose(nil)
            self.job = nil
        }
        self.job = job
        Log.info(.job, "start: \(job.files.map(\.lastPathComponent).joined(separator: ", ")) on \(job.printer.name) at \(job.options.size), \(job.reviewFirst ? "review first" : "countdown \(job.countdownSeconds)s")")
        let sizes = SizeCatalog.entries(for: job.printer).filter(\.isSupported).map(\.size)
        show(NSHostingController(rootView: JobView(job: job, sizes: sizes)))
        NSApp.activate()
        job.start()
    }

    /// Shows the popover under the icon at its final size, so it never resizes (and drifts) after appearing.
    private func show(_ controller: NSViewController) {
        guard let button = statusItem.button else { return }
        popover.contentViewController = controller
        popover.contentSize = controller.view.fittingSize
        if !popover.isShown { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }

    /// Menu actions run while the menu is still closing; anchor the popover once it has.
    private func afterMenuCloses(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }

    // MARK: Services ("Print as Label" in Finder's context menu and the Services menu)

    @objc func printAsLabel(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        Task {
            let files = await Intake.files(from: pboard, name: "Service")
            Log.info(.intake, "service gave \(files.count) file(s)")
            if files.isEmpty { shake() } else { printOnDefault(files, trigger: .openWith) }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        store.refresh()
        menu.removeAllItems()
        let current = store.printer


        for p in store.eligiblePrinters {
            let state = p.state == .stopped ? " (offline)" : ""
            let item = item("\(p.displayName)\(state)", #selector(choosePrinter(_:)), "")
            item.representedObject = p.name
            item.state = p.name == current?.name ? .on : .off
            item.image = NSImage(systemSymbolName: p.isLabelPrinter ? "printer.dotmatrix" : "photo", accessibilityDescription: nil)
            item.badge = NSMenuItemBadge(string: store.size(for: p).display)
            menu.addItem(item)
        }

        if let current {
            let sizes = NSMenu()
            let supported = SizeCatalog.entries(for: current).filter(\.isSupported).map(\.size)
            for (s, title) in zip(supported, SizeMenu.titles(supported, fontSize: NSFont.menuFont(ofSize: 0).pointSize)) {
                let item = SizeMenu.item(s, title, action: #selector(chooseSize(_:)))
                item.target = self
                item.state = s == store.size(for: current) ? .on : .off
                sizes.addItem(item)
            }
            let size = item("Label Size", #selector(noop), "")
            size.submenu = sizes
            menu.addItem(size)
        }

        menu.addItem(.separator())
        let clipboard = item("Print Clipboard", #selector(printClipboard), "", symbol: "doc.on.clipboard")
        clipboard.isEnabled = Intake.canRead(.general)
        menu.addItem(clipboard)
        menu.addItem(item("Print File…", #selector(openFile), "o", symbol: "folder"))
        let reprint = item("Reprint Last Label", #selector(reprintLast), "r", symbol: "arrow.clockwise")
        reprint.isEnabled = store.lastPrint != nil
        menu.addItem(reprint)
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings), ",", symbol: "gearshape"))
        // Hold ⌥ to swap Settings for Logs.
        let logs = item("Logs…", #selector(showLogs), ",", symbol: "list.bullet.rectangle")
        logs.keyEquivalentModifierMask = [.command, .option]
        logs.isAlternate = true
        menu.addItem(logs)
        menu.addItem(item("Quit Peel Good Inc.", #selector(NSApplication.terminate(_:)), "q", target: NSApp, symbol: "power"))
    }

    private func item(_ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    /// Target for items that only open a submenu.
    @objc private func noop() {}

    @objc private func choosePrinter(_ sender: NSMenuItem) {
        store.printer = store.eligiblePrinters.first { $0.name == sender.representedObject as? String }
    }

    @objc private func chooseSize(_ sender: NSMenuItem) {
        guard let p = store.printer, let s = sender.representedObject as? LabelSize else { return }
        store.setSize(s, for: p)
    }

    @objc private func printClipboard() {
        afterMenuCloses {
            Task {
                let files = await Intake.files(from: .general, name: "Clipboard")
                if files.isEmpty { self.shake() } else { self.printOnDefault(files, trigger: .clipboard) }
            }
        }
    }

    @objc private func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Intake.fileTypes
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        afterMenuCloses { self.printOnDefault(urls, trigger: .openWith) }
    }

    /// The saved label PDF is already label-sized, so it prints 1:1 (`JobFlow.reprintPlan`, as for MCP).
    @objc private func reprintLast() {
        let review = NSEvent.modifierFlags.contains(.option)
        guard let plan = try? JobFlow.reprintPlan(store: store, review: review) else { return }
        afterMenuCloses { self.present(JobFlow.makeJob(plan, store: self.store)) }
    }

    @objc private func showLogs() {
        afterMenuCloses { LogWindow.show() }
    }

    @objc private func showSettings() {
        afterMenuCloses { self.settings.show() }
    }

    // MARK: Test label

    /// Prints the test pattern on a printer at its size. The default printer stays as it is.
    func startTestLabel(on printer: PrinterInfo?, review: Bool) {
        guard let printer, let plan = JobFlow.testLabelPlan(printer: printer, store: store, review: review) else { return }
        present(JobFlow.makeJob(plan, store: store))
    }
}

/// Sits over the menu bar icon and receives drags; clicks pass through to the button.
final class StatusDropView: NSView {
    weak var delegate: NSDraggingDestination?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { delegate?.draggingEntered?(sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { delegate?.draggingUpdated?(sender) ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { delegate?.draggingExited?(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { delegate?.performDragOperation?(sender) ?? false }
}
