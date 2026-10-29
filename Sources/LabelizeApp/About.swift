import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum AboutWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: AboutView()))
            w.title = "About Peel Good Inc."
            w.styleMask = [.titled, .closable]
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

struct AboutView: View {
    @Environment(\.colorScheme) private var scheme
    @State private var showLicense = false
    @State private var showComponents = false

    static let companyURL = URL(string: "https://find-and-update.company-information.service.gov.uk/company/12425065/filing-history")!
    static let issuesURL = URL(string: "https://github.com/Fermium/peel-good-inc/issues/new")!

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String
        return build.map { "Version \(short) (\($0))" } ?? "Version \(short)"
    }

    private var logo: NSImage? {
        Bundle.main.url(forResource: scheme == .dark ? "logo-dark" : "logo-light", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }

    var body: some View {
        VStack(spacing: 14) {
            if let logo {
                Image(nsImage: logo).resizable().aspectRatio(contentMode: .fit).frame(width: 240)
                    .accessibilityLabel("Peel Good Inc.")
            } else {
                Text("Peel Good Inc.").font(.largeTitle.weight(.semibold))
            }
            Text(version).foregroundStyle(.secondary).textSelection(.enabled)

            VStack(spacing: 3) {
                Text("© 2026 FERMIUM LTD")
                Link("Company number 12425065", destination: Self.companyURL).font(.callout)
            }

            HStack(spacing: 10) {
                Button("MIT License") { showLicense = true }
                Button("Open Source Components") { showComponents = true }
            }

            Divider().padding(.horizontal, 30)

            VStack(spacing: 8) {
                Text("Questions or problems?").font(.headline)
                Button {
                    NSWorkspace.shared.open(Self.issuesURL)
                } label: {
                    Label("Open an Issue on GitHub", systemImage: "exclamationmark.bubble")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 36).padding(.vertical, 26)
        .frame(width: 420)
        .sheet(isPresented: $showLicense) { LicenseSheet() }
        .sheet(isPresented: $showComponents) { ComponentsSheet() }
    }
}

private struct LicenseSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let text = Bundle.main.url(forResource: "LICENSE", withExtension: nil)
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "MIT License\n\nCopyright (c) 2026 Fermium Ltd"

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            ScrollView {
                Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(width: 560, height: 420)
    }
}

/// The bundled CycloneDX SBOM as a list, with Save for the full file.
private struct ComponentsSheet: View {
    @Environment(\.dismiss) private var dismiss

    struct Component: Identifiable {
        let name, version, license, url: String
        var id: String { name }
    }

    private static let sbomURL = Bundle.main.url(forResource: "sbom.cdx", withExtension: "json")

    private let components: [Component] = {
        guard let url = sbomURL, let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["components"] as? [[String: Any]] else { return [] }
        return list.map { c in
            let licenses = (c["licenses"] as? [[String: Any]] ?? []).compactMap { entry in
                (entry["license"] as? [String: Any])?["id"] as? String ?? entry["expression"] as? String
            }
            let url = ((c["externalReferences"] as? [[String: Any]])?.first?["url"] as? String) ?? ""
            return Component(name: c["name"] as? String ?? "?", version: c["version"] as? String ?? "",
                             license: licenses.joined(separator: ", "), url: url)
        }
    }()

    var body: some View {
        VStack(spacing: 12) {
            Text("Peel Good Inc. is built with these open source packages.").foregroundStyle(.secondary)
            Table(components) {
                TableColumn("Package") { c in
                    if let url = URL(string: c.url), !c.url.isEmpty { Link(c.name, destination: url) } else { Text(c.name) }
                }
                TableColumn("Version", value: \.version).width(80)
                TableColumn("License", value: \.license).width(100)
            }
            HStack {
                Text("\(components.count) packages · CycloneDX 1.5").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save SBOM…", action: save).disabled(Self.sbomURL == nil)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 460)
    }

    private func save() {
        guard let source = Self.sbomURL else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "peel-good-inc.cdx.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: source, to: dest)
    }
}
