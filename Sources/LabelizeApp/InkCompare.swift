import AppKit
import LabelKit
import SwiftUI

/// The round ? button Mac apps use for help.
struct HelpButton: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.fire))
        button.bezelStyle = .helpButton
        return button
    }

    func updateNSView(_ view: NSButton, context: Context) { context.coordinator.action = action }
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}

/// A preview that shows an enlarge button on hover and opens a lightbox.
struct ZoomablePreview: View {
    let image: NSImage
    let title: String
    @State private var hovering = false
    @State private var zoomed = false

    var body: some View {
        Image(nsImage: image)
            .resizable().interpolation(.none).aspectRatio(contentMode: .fit)
            .background(.white)
            .border(.quaternary)
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button { zoomed = true } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.semibold))
                            .padding(5)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .transition(.opacity)
                    .help("Enlarge")
                }
            }
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
            .onTapGesture(count: 2) { zoomed = true }
            .sheet(isPresented: $zoomed) { Lightbox(image: image, title: title) }
    }
}

struct Lightbox: View {
    let image: NSImage
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: image)
                .resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                .background(.white)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                .frame(maxWidth: 720, maxHeight: 640)
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
        .onTapGesture { dismiss() }
    }
}

/// A sample with text, a barcode, a QR code and a gray ramp, so each ink mode shows its character.
enum InkSample {
    static func page(size: LabelSize, title: String) -> SourcePage {
        let s = size.points
        return SourcePage(size: s) { ctx in
            TestPattern.page(size: size, title: title).draw(in: ctx)
            let ramp = CGRect(x: s.width * 0.55, y: 14, width: s.width * 0.4, height: s.height * 0.3)
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                                  colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 1, alpha: 1)] as CFArray, locations: nil) {
                ctx.saveGState()
                ctx.clip(to: ramp)
                ctx.drawLinearGradient(g, start: CGPoint(x: ramp.minX, y: 0), end: CGPoint(x: ramp.maxX, y: 0), options: [])
                ctx.restoreGState()
            }
        }
    }
}

// MARK: Ink comparison window

@MainActor
enum InkCompareWindow {
    private static var window: NSWindow?

    static func show(store: Store, printer: PrinterInfo) {
        let view = InkCompareView(store: store, printer: printer)
        if let window {
            window.contentViewController = NSHostingController(rootView: view)
        } else {
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "Ink Modes"
            w.styleMask = [.titled, .closable, .resizable]
            w.isReleasedWhenClosed = false
            w.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { AppWindows.settingsClosed() }
            }
            window = w
        }
        AppWindows.bringToFront(window)
    }
}

/// Drop a file and see it next to its Auto, Crisp, Photo and Halftone versions.
struct InkCompareView: View {
    let store: Store
    let printer: PrinterInfo

    struct Result: Identifiable {
        let mode: InkMode
        let resolved: InkMode
        let image: NSImage
        var id: String { mode.rawValue }
    }

    @State private var name = "Sample"
    @State private var original: NSImage?
    @State private var results: [Result] = []
    @State private var working = false
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                column("Original", detail: name) {
                    if let original {
                        ZoomablePreview(image: original, title: name)
                    } else {
                        RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(targeted ? Color.accentColor : .clear, lineWidth: 3)
                        .padding(-6)
                }
                Image(systemName: "arrow.right").font(.title).foregroundStyle(.secondary)
                ForEach(results) { r in
                    column(r.mode.rawValue.capitalized, detail: detail(r)) {
                        ZoomablePreview(image: r.image, title: "\(name) · \(r.mode.rawValue.capitalized)")
                    }
                }
                if results.isEmpty {
                    ProgressView().frame(width: 4 * 150)
                }
            }
            .frame(height: 300)
            HStack {
                Text("Drop a file to compare.").foregroundStyle(.secondary)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Choose File…", action: choose)
            }
        }
        .padding(20)
        .onDrop(of: [.fileURL, .pdf, .svg, .image], isTargeted: $targeted) { providers in
            Task { @MainActor in
                if let url = await Intake.files(from: providers).first { load(url) }
            }
            return true
        }
        .onAppear { loadSample() }
    }

    private func detail(_ r: Result) -> String {
        switch r.mode {
        case .auto: "Picks \(r.resolved.rawValue.capitalized) for this file"
        case .crisp: "Black or white"
        case .photo: "Grays as fine dots"
        case .halftone: "Grays as a dot screen"
        }
    }

    private func column<C: View>(_ title: String, detail: String, @ViewBuilder content: () -> C) -> some View {
        VStack(spacing: 6) {
            content().frame(width: 150, height: 240)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(width: 150)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Intake.fileTypes
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    private func loadSample() {
        let size = store.size(for: printer)
        render(InkSample.page(size: size, title: printer.displayName), name: "Sample")
    }

    private func load(_ url: URL) {
        guard let page = try? DocumentLoader.load(url).first else { return }
        render(page, name: url.lastPathComponent)
    }

    private func render(_ page: SourcePage, name: String) {
        self.name = name
        working = true
        var base = store.options(for: printer)
        base.nudgeMM = .zero
        original = Self.colorImage(page)
        Task.detached {
            var out: [Result] = []
            for mode in [InkMode.auto, .crisp, .photo, .halftone] {
                var o = base
                o.ink = mode
                let label = LabelComposer.compose(page, o)
                if let cg = label.bitmap.cgImage() {
                    out.append(Result(mode: mode, resolved: label.ink, image: NSImage(cgImage: cg, size: o.size.points)))
                }
            }
            let done = out
            await MainActor.run {
                results = done
                working = false
            }
        }
    }

    /// The source page in color, about 600 px on the long side.
    static func colorImage(_ page: SourcePage) -> NSImage {
        let scale = 600 / max(page.size.width, page.size.height)
        let size = NSSize(width: page.size.width * scale, height: page.size.height * scale)
        return NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(.white)
            ctx.fill(rect)
            ctx.scaleBy(x: scale, y: scale)
            page.draw(in: ctx)
            return true
        }
    }
}
