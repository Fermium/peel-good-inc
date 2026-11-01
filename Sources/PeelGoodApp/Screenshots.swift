import AppKit
import LabelKit
import PeelGoodCore
import SwiftUI

/// `PeelGood -screenshots <dir>` renders every surface of the app into PNGs, light and dark, then quits.
///
/// Each surface is built in a real NSWindow parked far off every screen (never key, never activated,
/// so nothing appears or takes focus), drawn with `cacheDisplay(in:to:)` on the window's frame view
/// (title bar and toolbar included), and composited with rounded corners and a shadow.
/// No Screen Recording permission is needed and only the app's own views are drawn.
/// Nothing is printed: the job runs in review mode and is never sent.
/// Run it with `scripts/screenshots.sh`, which isolates the settings, history and log in a temporary home.
@MainActor
enum Screenshots {
    /// Returns true when it took over the launch; the caller should skip normal setup.
    static func runIfRequested(store: Store) -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-screenshots") else { return false }
        let dir = URL(fileURLWithPath: i + 1 < args.count ? args[i + 1] : "screenshots", isDirectory: true)
        Task {
            await run(store: store, dir: dir)
            exit(0)
        }
        return true
    }

    /// The real home when CFFIXED_USER_HOME isn't set; then the real log is left out.
    private static var isolated: Bool { ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil }

    private static func run(store: Store, dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        print(useWindowServer ? "capturing with the window server (own windows only)" : "capturing with cacheDisplay (no Screen Recording access)")
        if isolated { await seedLog() }
        let printers = RulesPreviewData.printers
        // A Zebra for its settings, only in a throwaway home: the GX420t this was built against.
        let zebra = Zebra.Profile(serial: "99J000000001", host: "192.168.1.216", product: "GX420t", dotsPerMM: 8,
                                  headDots: 832, maximumLength: 39, discoveryID: "123456")
        if isolated {
            store.addZebra(zebra)
            store.setNudge(CGPoint(x: 2, y: 0), for: zebra.printer())
            for _ in 0..<30 where store.printers.first(where: { $0.name == zebra.printerName })?.state == .unknown {
                try? await Task.sleep(for: .seconds(0.2))
            }
        }
        for (name, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let appearance = NSAppearance(named: name)!
            func file(_ base: String) -> URL { dir.appendingPathComponent("\(base)-\(suffix).png") }

            // Settings, one image per tab.
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            tabs.transitionOptions = []
            tabs.addTabViewItem(tab("General", "gearshape", GeneralPane(store: store)))
            tabs.addTabViewItem(tab("Printers", "printer", PrintersPane(store: store, testLabel: { _ in })))
            tabs.addTabViewItem(tab("Rules", "list.bullet.rectangle",
                                    RulesSettingsView(engine: RulesPreviewData.engine(), store: store, previewPrinters: printers,
                                                      folders: .preview(sampleFolders()))))
            tabs.addTabViewItem(tab("API", "point.3.connected.trianglepath.dotted", APIPane(api: .shared)))
            tabs.addTabViewItem(tab("CLI", "terminal", CLIPane(installer: .preview(), expanded: ["print"])))
            tabs.addTabViewItem(tab("About", "info.circle", AboutView()))
            let settings = window(tabs, style: [.titled, .closable], appearance: appearance)
            settings.toolbarStyle = .preference
            // Visit every tab once first, so lazily built content (the Printers preview) is ready.
            for i in tabs.tabViewItems.indices.reversed() {
                tabs.selectedTabViewItemIndex = i
                await settle(settings, 0.5)
            }
            for (i, item) in tabs.tabViewItems.enumerated() {
                tabs.selectedTabViewItemIndex = i
                settings.title = item.label
                await settle(settings, 1.0)
                save(windowImage(settings), file("settings-\(item.label.lowercased())"))
            }
            settings.close()

            // Zebra: its settings and the Add sheet (a live scan). The offer at launch is an NSAlert,
            // which can't be drawn offscreen.
            if isolated, let z = store.printers.first(where: { $0.name == zebra.printerName }) {
                let chosen = store.printer
                store.printer = z
                let pane = window(NSHostingController(rootView: active(PrintersPane(store: store, testLabel: { _ in }))),
                                  style: [.titled], appearance: appearance)
                pane.title = "Printers"
                await settle(pane, 1.0)
                save(windowImage(pane), file("settings-printers-zebra"))
                pane.close()
                store.printer = chosen

                // The whole detail, down to the Zebra section and the move to the printer.
                let detailHost = NSHostingController(rootView: active(PrinterDetail(store: store, printer: z, testLabel: { _ in })
                    .frame(width: 470, height: 1400)))
                let detail = window(detailHost, style: [.titled], appearance: appearance)
                detail.title = z.displayName
                await settle(detail, 1.0)
                save(windowImage(detail), file("settings-printer-zebra-detail"))
                detail.close()

                let add = window(NSHostingController(rootView: active(AddZebraSheet(store: store) { _ in })), style: [.titled], appearance: appearance)
                add.title = ""
                await settle(add, 6)
                save(windowImage(add), file("settings-add-zebra"))
                add.close()

            }

            // Sheets from the Rules and API tabs, as their own windows.
            let editor = RuleEditorView(rule: RuleTemplate.amazonReturns.make(printers: printers), printers: printers, current: printers[0],
                                        defaults: { [store] in store.options(for: $0) }, settings: store.settings) { _ in }
            for (name, title, view) in [("rule-editor", "Rule", AnyView(editor)),
                                        ("api-setup", "Set Up MCP", AnyView(MCPSetupSheet(port: APISettings.defaultPort))),
                                        ("api-reference", "API Reference", AnyView(APIReferenceSheet(api: .shared)))] {
                let sheet = window(NSHostingController(rootView: active(view)), style: [.titled], appearance: appearance)
                sheet.title = title
                await settle(sheet, 0.8)
                save(windowImage(sheet), file("settings-\(name)"))
                sheet.close()
            }

            // The popover after a drop, in review (never sent), and the printer tiles.
            let job = PrintJob(files: [sampleLabel()], printer: printers[0], options: LabelOptions(), reviewFirst: true, countdownSeconds: 0)
            let sizes = SizeCatalog.entries(for: printers[0]).filter(\.isSupported).map(\.size)
            let jobHost = NSHostingController(rootView: active(JobView(job: job, sizes: sizes)))
            let jobWindow = window(jobHost, style: [.borderless], appearance: appearance)
            job.start()
            for _ in 0..<50 where job.phase != .review { await settle(jobWindow, 0.1) }
            await settle(jobWindow, 0.8)
            save(popoverImage(jobWindow), file("popover-review"))
            jobWindow.close()

            let zones = NSHostingController(rootView: active(DropZonesView(printers: printers, current: printers[0].name,
                                                                            sizeFor: { [store] in store.size(for: $0) }, onDrop: { _, _ in })))
            let zonesWindow = window(zones, style: [.borderless], appearance: appearance)
            await settle(zonesWindow, 0.5)
            save(popoverImage(zonesWindow), file("popover-dropzones"))
            zonesWindow.close()

            // Ink Modes, with the built-in sample.
            let ink = window(NSHostingController(rootView: active(InkCompareView(store: store, printer: printers[0]))),
                             style: [.titled, .closable, .resizable], appearance: appearance)
            ink.title = "Ink Modes"
            await settle(ink, 1.5)
            save(windowImage(ink), file("ink-modes"))

            ink.close()

            // Logs: only the seeded sample, never the real log.
            if isolated {
                let logs = window(NSHostingController(rootView: active(LogView())), style: [.titled, .closable, .resizable, .miniaturizable],
                                  appearance: appearance)
                logs.title = "Peel Good Inc. Logs"
                logs.setContentSize(NSSize(width: 900, height: 520))
                await settle(logs, 1.5)
                save(windowImage(logs), file("logs"))
                logs.close()
            } else {
                print("skipped logs: run with CFFIXED_USER_HOME set (scripts/screenshots.sh) so the real log isn't shown")
            }
        }
        print("screenshots in \(dir.path)")
    }

    // MARK: Windows

    /// Never constrained to a screen, and drawn as the active window without becoming key.
    private final class ShotWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
        // AppKit's private "draw as active" checks, so accents and traffic lights aren't greyed out.
        @objc func _hasActiveAppearance() -> Bool { true }
        @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
        @objc func _hasKeyAppearance() -> Bool { true }
        @objc func _hasActiveControls() -> Bool { true }
        @objc func hasKeyAppearance() -> Bool { true }
    }

    private static func window(_ controller: NSViewController, style: NSWindow.StyleMask, appearance: NSAppearance) -> NSWindow {
        let w = ShotWindow(contentViewController: controller)
        w.styleMask = style
        w.appearance = appearance
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        if style.contains(.borderless) {
            w.isOpaque = false
            w.backgroundColor = .clear
            w.setContentSize(controller.view.fittingSize)
        }
        park(w)
        w.orderFrontRegardless()
        return w
    }

    /// SwiftUI controls drawn as in the frontmost window (accent colors, not inactive gray).
    private static func active<V: View>(_ view: V) -> some View {
        view.environment(\.controlActiveState, .key)
    }

    /// Far below and left of every display.
    private static func park(_ w: NSWindow) {
        w.setFrameTopLeftPoint(NSPoint(x: -20_000, y: -10_000))
    }

    private static func tab<V: View>(_ title: String, _ symbol: String, _ view: V) -> NSTabViewItem {
        let host = NSHostingController(rootView: active(view))
        host.sizingOptions = .preferredContentSize
        let item = NSTabViewItem(viewController: host)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    /// Lets SwiftUI lay out, load previews and resize the window.
    private static func settle(_ w: NSWindow, _ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
        park(w)
        w.contentView?.layoutSubtreeIfNeeded()
        w.displayIfNeeded()
    }

    // MARK: Capture

    /// Experiment: the window server's own image of one of our windows (CGWindowListCreateImage is
    /// unavailable to Swift since the macOS 15 SDK, so it's looked up at run time).
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let createImage: CreateImage? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")
        .map { unsafeBitCast($0, to: CreateImage.self) }

    /// Only when the process already has Screen Recording access (e.g. a terminal that has it), so it
    /// never prompts. Asks for this one window by ID, so nothing else on screen is read.
    static let useWindowServer = createImage != nil && CGPreflightScreenCaptureAccess()
        && !CommandLine.arguments.contains("-screenshotsOffscreenOnly")

    /// Our window as the window server composited it (glass, toolbar selection, corners), without its shadow.
    private static func serverImage(_ w: NSWindow) -> NSBitmapImageRep? {
        // kCGWindowListOptionIncludingWindow; kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution
        guard useWindowServer, let createImage,
              let cg = createImage(.null, 1 << 3, UInt32(w.windowNumber), 1 << 0 | 1 << 3)?.takeRetainedValue() else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = w.frame.size
        return rep
    }

    /// The window server's image when allowed, else AppKit's own drawing of the view tree.
    private static func image(_ w: NSWindow, view: NSView) -> NSBitmapImageRep? {
        serverImage(w) ?? draw(view)
    }

    private static let scale: CGFloat = 2

    /// Draws a view at 2x into a bitmap, whatever the window's backing scale.
    private static func draw(_ view: NSView) -> NSBitmapImageRep? {
        let bounds = view.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    /// The whole window, title bar and toolbar included, with rounded corners, a hairline and a shadow.
    private static func windowImage(_ w: NSWindow) -> NSBitmapImageRep? {
        guard let frameView = w.contentView?.superview, let content = image(w, view: frameView) else { return nil }
        let size = frameView.bounds.size
        let radius: CGFloat = w.toolbar == nil ? 16 : 26
        return composite(size: size, appearance: w.appearance!, pad: 50) { rect in
            let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = .black.withAlphaComponent(w.appearance?.name == .darkAqua ? 0.6 : 0.35)
            shadow.shadowBlurRadius = 30
            shadow.shadowOffset = NSSize(width: 0, height: -12)
            shadow.set()
            NSColor.windowBackgroundColor.setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            content.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            hairline(shape, dark: w.appearance?.name == .darkAqua)
        }
    }

    /// A popover's content on a rounded panel with the arrow pointing up at the menu bar icon.
    private static func popoverImage(_ w: NSWindow) -> NSBitmapImageRep? {
        guard let view = w.contentView, let content = image(w, view: view) else { return nil }
        let arrow: CGFloat = 12
        let body = view.bounds.size
        let size = NSSize(width: body.width, height: body.height + arrow)
        return composite(size: size, appearance: w.appearance!, pad: 40) { rect in
            let panel = NSRect(x: rect.minX, y: rect.minY, width: body.width, height: body.height)
            let shape = popoverShape(panel, arrow: arrow)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = .black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = 20
            shadow.shadowOffset = NSSize(width: 0, height: -6)
            shadow.set()
            (w.appearance?.name == .darkAqua ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()
            content.draw(in: panel, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            hairline(shape, dark: w.appearance?.name == .darkAqua)
        }
    }

    /// One outline for panel and arrow, so the hairline doesn't cross the arrow's base.
    private static func popoverShape(_ r: NSRect, arrow: CGFloat) -> NSBezierPath {
        let radius: CGFloat = 16, mid = r.midX, half = arrow * 1.6
        let p = NSBezierPath()
        p.move(to: NSPoint(x: r.minX + radius, y: r.minY))
        p.line(to: NSPoint(x: r.maxX - radius, y: r.minY))
        p.appendArc(withCenter: NSPoint(x: r.maxX - radius, y: r.minY + radius), radius: radius, startAngle: 270, endAngle: 0)
        p.line(to: NSPoint(x: r.maxX, y: r.maxY - radius))
        p.appendArc(withCenter: NSPoint(x: r.maxX - radius, y: r.maxY - radius), radius: radius, startAngle: 0, endAngle: 90)
        p.line(to: NSPoint(x: mid + half, y: r.maxY))
        p.curve(to: NSPoint(x: mid, y: r.maxY + arrow), controlPoint1: NSPoint(x: mid + half / 2, y: r.maxY),
                controlPoint2: NSPoint(x: mid + half / 4, y: r.maxY + arrow))
        p.curve(to: NSPoint(x: mid - half, y: r.maxY), controlPoint1: NSPoint(x: mid - half / 4, y: r.maxY + arrow),
                controlPoint2: NSPoint(x: mid - half / 2, y: r.maxY))
        p.line(to: NSPoint(x: r.minX + radius, y: r.maxY))
        p.appendArc(withCenter: NSPoint(x: r.minX + radius, y: r.maxY - radius), radius: radius, startAngle: 90, endAngle: 180)
        p.line(to: NSPoint(x: r.minX, y: r.minY + radius))
        p.appendArc(withCenter: NSPoint(x: r.minX + radius, y: r.minY + radius), radius: radius, startAngle: 180, endAngle: 270)
        p.close()
        return p
    }

    private static func hairline(_ shape: NSBezierPath, dark: Bool) {
        (dark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.12)).setStroke()
        shape.lineWidth = 1 / scale
        shape.stroke()
    }

    /// A transparent 2x canvas with room for the shadow, drawn in the given appearance.
    private static func composite(size: NSSize, appearance: NSAppearance, pad: CGFloat, _ body: (NSRect) -> Void) -> NSBitmapImageRep? {
        let canvas = NSSize(width: size.width + 2 * pad, height: size.height + 2 * pad)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = { rep.size = canvas; return NSGraphicsContext(bitmapImageRep: rep) }() else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        appearance.performAsCurrentDrawingAppearance {
            body(NSRect(x: pad, y: pad, width: size.width, height: size.height))
        }
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func save(_ rep: NSBitmapImageRep?, _ url: URL) {
        guard let data = rep?.representation(using: .png, properties: [:]) else { return print("failed: \(url.lastPathComponent)") }
        try? data.write(to: url)
        print("wrote \(url.lastPathComponent) \(rep!.pixelsWide)x\(rep!.pixelsHigh)")
    }

    // MARK: Sample data

    /// A shipping label from the repo's fixtures (found above the executable), else the test pattern.
    private static func sampleLabel() -> URL {
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        while dir.path != "/" {
            let fixture = dir.appendingPathComponent("Fixtures/letter-usps.pdf")
            if FileManager.default.fileExists(atPath: fixture.path) { return fixture }
            dir = dir.deletingLastPathComponent()
        }
        let size = LabelSize.fourBySix
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Peel Good Sample.pdf")
        try? TestLabel.pattern.writePDF(size: size, title: TestLabel.title(printer: nil, size: size), to: url)
        return url
    }

    /// Folders to show as watched. In the throwaway home they're created so they get folder icons.
    private static func sampleFolders() -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let folders = [home.appendingPathComponent("Downloads/Labels", isDirectory: true),
                       home.appendingPathComponent("Documents/Returns", isDirectory: true)]
        if isolated { for f in folders { try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true) } }
        return folders
    }

    /// A believable day of activity in the (isolated) log file.
    private static func seedLog() async {
        Log.clear()
        Log.notice(.app, "Peel Good Inc. 0.1 started, 2 printers, default Label_Printer_ITPP941AP")
        Log.info(.drop, "drop targets registered for 6 types")
        Log.info(.drop, "drag entered: public.file-url")
        Log.info(.drop, "drop gave 1 file(s): order-1234-label.pdf")
        Log.info(.rules, "order-1234-label.pdf: rule \"Royal Mail\" → Label_Printer_ITPP941AP, 4x6, print, 1 copy")
        Log.info(.job, "start: order-1234-label.pdf on Label_Printer_ITPP941AP at 4x6, countdown 1.5s")
        Log.info(.job, "composed 1 label(s) at 4x6, 2 code(s), 0 unreadable")
        Log.notice(.print, "sent 1 label(s) to Label_Printer_ITPP941AP (media w288h432): Label_Printer_ITPP941AP-42")
        Log.info(.files, "tagged order-1234-label.pdf \"Printed\"")
        Log.info(.intake, "asked to open return-label.png")
        Log.warning(.job, "Label is smaller than the roll; centred")
        Log.info(.rules, "return-label.png: rule \"Amazon returns\" → Label_Printer_ITPP941AP, 4x6, review, 1 copy")
        Log.info(.job, "cancelled")
        Log.error(.print, "print failed on Canon_TS9500_series: printer is offline")
        try? await Task.sleep(for: .seconds(0.3))
    }
}
