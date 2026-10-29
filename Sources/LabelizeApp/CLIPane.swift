import AppKit
import LabelizeCLI
import SwiftUI

/// Puts the bundled command (Contents/Helpers/peelgood) on PATH as `peelgood`, with
/// symlinks only: no copies, no sudo. The man page and completions are linked next to it when
/// the folders for them already exist.
@MainActor
final class CommandInstaller: ObservableObject {
    struct Link: Equatable {
        var path: String
        var destination: String
        /// Points at a Peel Good Inc. helper (this copy or another).
        var ours: Bool
    }

    @Published private(set) var links: [String: Link] = [:]
    @Published private(set) var homebrew = false
    @Published var message: String?
    @Published var failed = false

    let helper: URL?
    private let isPreview: Bool

    nonisolated static let systemDirs = ["/opt/homebrew/bin", "/usr/local/bin"]
    nonisolated static var userDir: String { NSHomeDirectory() + "/.local/bin" }
    nonisolated static var searchDirs: [String] { systemDirs + [userDir] }

    init(bundle: Bundle = .main) {
        let url = bundle.bundleURL.appendingPathComponent("Contents/Helpers/\(Manual.tool)")
        helper = FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        isPreview = false
        refresh()
    }

    /// Fixed state for screenshots: installed in /opt/homebrew/bin, nothing on disk is read or changed.
    private init(previewHelper: URL) {
        helper = previewHelper
        isPreview = true
        for name in Manual.names {
            links[name] = Link(path: "/opt/homebrew/bin/\(name)", destination: previewHelper.path, ours: true)
        }
    }

    static func preview() -> CommandInstaller {
        CommandInstaller(previewHelper: URL(fileURLWithPath: "/Applications/Peel Good Inc.app/Contents/Helpers/peelgood"))
    }

    var installed: Bool { links[Manual.tool] != nil }
    var installedDir: String? { links[Manual.tool].map { ($0.path as NSString).deletingLastPathComponent } }

    /// Where Install links to: the first writable system folder, else ~/.local/bin.
    var targetDir: String {
        Self.systemDirs.first { FileManager.default.isWritableFile(atPath: $0) } ?? Self.userDir
    }

    var needsAdmin: Bool { targetDir == Self.userDir }

    /// For when no system folder is writable: what to paste into Terminal.
    var adminCommand: String {
        let src = helper?.path ?? "/Applications/Peel Good Inc.app/Contents/Helpers/peelgood"
        return Manual.names.map { "sudo ln -sf '\(src)' /usr/local/bin/\($0)" }.joined(separator: "\n")
    }

    static let pathLine = #"echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zprofile"#

    func refresh() {
        guard !isPreview else { return }
        let fm = FileManager.default
        var found: [String: Link] = [:]
        for name in Manual.names {
            for dir in Self.searchDirs {
                let path = "\(dir)/\(name)"
                guard fm.fileExists(atPath: path) || (try? fm.destinationOfSymbolicLink(atPath: path)) != nil else { continue }
                let dest = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                found[name] = Link(path: path, destination: dest, ours: dest.hasSuffix(".app/Contents/Helpers/\(Manual.tool)"))
                break
            }
        }
        links = found
        homebrew = Self.systemDirs.contains { fm.fileExists(atPath: ($0 as NSString).deletingLastPathComponent + "/Caskroom/peel-good-inc") }
    }

    func install() {
        guard !isPreview else { return }
        guard let helper else { return }
        let fm = FileManager.default
        let dir = targetDir
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for name in Manual.names {
                try link(helper.path, at: "\(dir)/\(name)")
            }
            // Man page and completions, only into folders that are already there.
            let prefix = (dir as NSString).deletingLastPathComponent
            let resources = helper.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
            for (sub, file) in Self.extras {
                let src = resources.appendingPathComponent(file).path
                let folder = "\(prefix)/\(sub)"
                guard fm.fileExists(atPath: src), fm.isWritableFile(atPath: folder) else { continue }
                try? link(src, at: "\(folder)/\((file as NSString).lastPathComponent)")
            }
            failed = false
            message = dir == Self.userDir ? "Installed in ~/.local/bin." : "Installed in \(dir)."
        } catch {
            failed = true
            message = error.localizedDescription
        }
        refresh()
    }

    func uninstall() {
        guard !isPreview else { return }
        for dir in Self.searchDirs {
            for name in Manual.names { removeIfOurs("\(dir)/\(name)") }
            let prefix = (dir as NSString).deletingLastPathComponent
            for (sub, file) in Self.extras { removeIfOurs("\(prefix)/\(sub)/\((file as NSString).lastPathComponent)") }
        }
        failed = false
        message = "Uninstalled."
        refresh()
    }

    /// (folder under the prefix, file in Contents/Resources)
    nonisolated static let extras = [
        ("share/man/man1", "peelgood.1"),
        ("share/zsh/site-functions", "completions/_peelgood"),
        ("share/fish/vendor_completions.d", "completions/peelgood.fish"),
        ("etc/bash_completion.d", "completions/peelgood.bash"),
    ]

    private func link(_ source: String, at path: String) throws {
        let fm = FileManager.default
        if let existing = try? fm.destinationOfSymbolicLink(atPath: path) {
            guard existing.contains(".app/Contents/") else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "\(path) belongs to something else. Remove it first."])
            }
            try fm.removeItem(atPath: path)
        } else if fm.fileExists(atPath: path) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "\(path) belongs to something else. Remove it first."])
        }
        try fm.createSymbolicLink(atPath: path, withDestinationPath: source)
    }

    /// Only symlinks into a Peel Good Inc. bundle; anything else is left alone.
    private func removeIfOurs(_ path: String) {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: path),
              dest.contains("Peel Good") || dest.hasSuffix("Contents/Helpers/\(Manual.tool)") else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// Settings > CLI: install the command, then the manual with every command and its examples.
struct CLIPane: View {
    @StateObject private var installer: CommandInstaller
    @State private var confirmInstall = false
    @State private var expanded: Set<String>

    init(installer: CommandInstaller? = nil, expanded: Set<String> = []) {
        _installer = StateObject(wrappedValue: installer ?? CommandInstaller())
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        Form {
            commandSection
            manualSection
            completionSection
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 650)
        .onAppear { installer.refresh() }
        .alert("Install the command?", isPresented: $confirmInstall) {
            Button("Install") { installer.install() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(installer.needsAdmin
                 ? "Links peelgood in ~/.local/bin. To install for all users instead, use the Terminal command shown below."
                 : "Links peelgood in \(installer.targetDir).")
        }
    }

    // MARK: Command

    private var commandSection: some View {
        Section {
            ForEach(Manual.names, id: \.self) { name in
                LabeledContent {
                    HStack(spacing: 6) {
                        Circle().fill(installer.links[name] != nil ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                        Text(status(name)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                } label: {
                    Text(name).font(.system(.body, design: .monospaced))
                }
            }
            HStack {
                if let message = installer.message {
                    Text(message).font(.callout).foregroundStyle(installer.failed ? .red : .secondary)
                }
                Spacer()
                if installer.installed && !installer.homebrew {
                    Button("Uninstall") { installer.uninstall() }
                }
                Button(installer.installed ? "Reinstall Command…" : "Install Command…") { confirmInstall = true }
                    .disabled(installer.helper == nil || installer.homebrew)
            }
            if installer.installedDir == CommandInstaller.userDir {
                SnippetView(title: "Add ~/.local/bin to your PATH", text: CommandInstaller.pathLine)
            } else if installer.needsAdmin && !installer.installed && installer.helper != nil {
                SnippetView(title: "Or install for all users in Terminal", text: installer.adminCommand)
            }
        } header: {
            Text("Command")
        } footer: {
            Text(footer).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func status(_ name: String) -> String {
        guard let link = installer.links[name] else { return "Not installed" }
        let dir = (link.path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return link.ours ? "Installed in \(dir)" : "\(dir)/\(name) is another program"
    }

    private var footer: String {
        if installer.helper == nil { return "This build doesn't include the command. Build the app with scripts/make-app.sh." }
        if installer.homebrew { return "Installed with Homebrew, with the man page and completions. Updates with the cask." }
        return "Use peelgood in Terminal. It uses the printer and settings chosen here."
    }

    // MARK: Manual

    private var manualSection: some View {
        Section {
            ForEach(Manual.visibleCommands.filter { $0.name != "help" }, id: \.name) { command in
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(command.name) },
                                                    set: { if $0 { expanded.insert(command.name) } else { expanded.remove(command.name) } })) {
                    CommandManual(command: command)
                } label: {
                    HStack(spacing: 8) {
                        Text(command.name).font(.system(.body, design: .monospaced).weight(.medium))
                        Text(command.summary).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Manual")
        } footer: {
            Text("Run peelgood help, or man peelgood, for the same text in Terminal.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Completion

    private var completionSection: some View {
        Section {
            ForEach(Completions.Shell.allCases, id: \.self) { shell in
                SnippetView(title: shell == .fish ? "fish: run once" : "\(shell.rawValue): add to \(shell.startupFile)", text: shell.installLine)
            }
        } header: {
            Text("Shell Completion")
        } footer: {
            Text("Tab completes commands, options, printers and sizes.").font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// One command: usage, options and examples with copy buttons.
private struct CommandManual: View {
    let command: CLICommand

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(command.usage()).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                Spacer()
            }
            if !command.discussion.isEmpty {
                Text(command.discussion).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !command.visibleOptions.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(command.visibleOptions, id: \.name) { option in
                        GridRow {
                            Text(option.signature).font(.system(size: 11, design: .monospaced)).fixedSize()
                            Text(option.help).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if !command.examples.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(command.examples, id: \.command) { example in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(example.comment).font(.caption).foregroundStyle(.secondary)
                                Text(example.command).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            }
                            Spacer()
                            CopyButton(nil, text: example.command)
                        }
                    }
                }
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            }
        }
        .padding(.vertical, 4)
    }
}
