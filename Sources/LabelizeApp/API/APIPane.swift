import AppKit
import SwiftUI

/// Settings > API: the HTTP API and MCP switches, port, token, the endpoint reference
/// (from `OpenAPI`), and setup snippets for MCP clients.
struct APIPane: View {
    @ObservedObject var api: APIController
    @State private var portDraft: Int?
    @State private var showToken = false
    @State private var confirmRegenerate = false

    private var port: Int { api.activePort }
    private var base: String { OpenAPI.baseURL(port: port) }

    var body: some View {
        Form {
            serverSection
            Section {
                HStack {
                    Button("Open API Docs") { NSWorkspace.shared.open(URL(string: base + "/")!) }
                        .disabled(!(api.httpEnabled && api.isRunning))
                    CopyButton("Copy OpenAPI URL", text: base + "/openapi.json")
                    CopyButton("Copy OpenAPI JSON", text: OpenAPI.document(port: port).serialized())
                    Spacer()
                }
            } header: {
                Text("HTTP API")
            } footer: {
                Text("Prints only files sent with each request. Every request needs the token. Requests from web pages are refused.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(OpenAPI.tags, id: \.self) { tag in
                Section(tag) {
                    ForEach(OpenAPI.endpoints.filter { $0.tag == tag }) { EndpointRow(endpoint: $0, port: port) }
                }
            }
            mcpSection
        }
        .formStyle(.grouped)
        .frame(width: 680, height: 640)
        .alert("Regenerate token?", isPresented: $confirmRegenerate) {
            Button("Regenerate", role: .destructive) { api.regenerateToken() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Apps and MCP clients using the current token will need the new one.")
        }
    }

    // MARK: Server

    private var serverSection: some View {
        Section {
            Toggle("HTTP API", isOn: Binding(get: { api.httpEnabled }, set: { api.httpEnabled = $0 }))
            Toggle("MCP server", isOn: Binding(get: { api.mcpEnabled }, set: { api.mcpEnabled = $0 }))
            LabeledContent("Port") {
                HStack(spacing: 6) {
                    TextField("", value: Binding(get: { portDraft ?? api.port }, set: { portDraft = $0 }), format: .number.grouping(.never))
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                        .onSubmit(commitPort)
                    if let draft = portDraft, draft != api.port {
                        Button("Apply", action: commitPort).disabled(!APIController.validPorts.contains(draft))
                    }
                }
            }
            LabeledContent("Token") {
                HStack(spacing: 6) {
                    Text(showToken ? api.token : String(repeating: "•", count: 16))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(showToken ? "Hide" : "Show") { showToken.toggle() }
                    CopyButton("Copy", text: api.token)
                    Button("Regenerate…") { confirmRegenerate = true }
                }
            }
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(statusText).foregroundStyle(isFailed ? .red : .secondary)
                }
            }
        } footer: {
            Text("Only apps on this Mac can connect. The token is in ~/Library/Application Support/Labelize/token.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func commitPort() {
        guard let draft = portDraft else { return }
        if APIController.validPorts.contains(draft) { api.port = draft }
        portDraft = nil
    }

    private var isFailed: Bool { if case .failed = api.status { true } else { false } }

    private var statusText: String {
        switch api.status {
        case .off: "Off"
        case .starting: "Starting…"
        case .running(let p): "Running on 127.0.0.1:\(p)"
        case .failed(let message): message
        }
    }

    private var statusColor: Color {
        switch api.status {
        case .off: .secondary
        case .starting: .orange
        case .running: .green
        case .failed: .red
        }
    }

    // MARK: MCP

    private var mcpSection: some View {
        Section {
            LabeledContent("Endpoint") {
                HStack {
                    Text(base + "/mcp").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    CopyButton(nil, text: base + "/mcp")
                }
            }
            Toggle(isOn: Binding(get: { api.mcpCanUseLocalFiles }, set: { api.mcpCanUseLocalFiles = $0 })) {
                Text(MCPPermission.localFiles.settingTitle)
                Text("Files by path, the clipboard, and reprinting.")
            }
            Toggle(isOn: Binding(get: { api.mcpCanChangeSettings }, set: { api.mcpCanChangeSettings = $0 })) {
                Text(MCPPermission.settings.settingTitle)
                Text("Settings, printers, rules, watched folders, and the HTTP API. Never the MCP switch, these permissions or the token.")
            }
            SnippetView(title: "Claude Code", text: Snippets.claudeCodeHTTP(port: port))
            SnippetView(title: "Claude Code (stdio)", text: Snippets.claudeCodeStdio)
            SnippetView(title: "Claude Desktop: claude_desktop_config.json", text: Snippets.claudeDesktop)
        } header: {
            Text("MCP")
        } footer: {
            Text(api.mcpEnabled ? "MCP can always print files it sends and read settings. Tools that need a permission explain how to turn it on."
                                : "Turn on MCP server to use these.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

// MARK: Snippets

enum Snippets {
    /// The bundled stdio relay, next to the app's executable.
    static var shimPath: String {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" { return bundle.appendingPathComponent("Contents/MacOS/labelize-mcp").path }
        return (Bundle.main.executableURL ?? bundle).deletingLastPathComponent().appendingPathComponent("labelize-mcp").path
    }

    static func claudeCodeHTTP(port: Int) -> String {
        "claude mcp add --transport http peel-good \(OpenAPI.baseURL(port: port))/mcp --header \"Authorization: Bearer $(cat \(OpenAPI.tokenShellPath))\""
    }

    static var claudeCodeStdio: String {
        "claude mcp add peel-good -- \"\(shimPath)\""
    }

    static var claudeDesktop: String {
        JSONValue.object([("mcpServers", .object([("peel-good", .object([("command", .string(shimPath))]))]))]).serialized()
    }
}

// MARK: Endpoint row

struct EndpointRow: View {
    let endpoint: OpenAPI.Endpoint
    let port: Int
    @State private var expanded = false

    private var url: String { OpenAPI.baseURL(port: port) + endpoint.examplePath }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text(endpoint.detail + (endpoint.authenticated ? "" : " No token needed."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !endpoint.parameters.isEmpty {
                    Heading("Parameters")
                    ForEach(endpoint.parameters) { p in
                        FieldLine(name: p.name, type: p.schema.typeName, note: "\(p.location.rawValue)\(p.required ? ", required" : "")",
                                  detail: p.schema.summary)
                    }
                }
                if !endpoint.body.isEmpty {
                    Heading("Request body")
                    ForEach(endpoint.body) { c in SchemaBlock(mediaType: c.mediaType, schema: c.schema) }
                }
                Heading("Responses")
                ForEach(endpoint.responses) { r in
                    if r.status == 200 {
                        ForEach(r.content) { c in SchemaBlock(mediaType: "200 · \(c.mediaType)", schema: c.schema) }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(String(r.status)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            Text(r.description).font(.caption)
                        }
                    }
                }
                ForEach(OpenAPI.curl(endpoint, port: port), id: \.command) { example in
                    SnippetView(title: example.title.isEmpty ? "curl" : "curl: \(example.title)", text: example.command)
                }
                if let request = OpenAPI.requestExample(endpoint) {
                    SnippetView(title: "Request example", text: request)
                }
                if let response = OpenAPI.responseExample(endpoint) {
                    SnippetView(title: "Response example", text: response, maxHeight: 160)
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 8) {
                MethodBadge(verb: endpoint.verb)
                Text(endpoint.path).font(.system(.body, design: .monospaced)).lineLimit(1)
                Text(endpoint.summary).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Menu {
                    Button("Copy Path") { Clipboard.copy(endpoint.path) }
                    Button("Copy URL") { Clipboard.copy(url) }
                    ForEach(OpenAPI.curl(endpoint, port: port), id: \.command) { example in
                        Button(example.title.isEmpty ? "Copy curl" : "Copy curl (\(example.title))") { Clipboard.copy(example.command) }
                    }
                    if let json = OpenAPI.exampleJSON(endpoint) {
                        Button("Copy JSON Example") { Clipboard.copy(json) }
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Copy")
            }
        }
    }
}

struct MethodBadge: View {
    let verb: OpenAPI.Verb

    var body: some View {
        Text(verb.rawValue)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .frame(width: 40)
            .padding(.vertical, 2)
            .background(color, in: RoundedRectangle(cornerRadius: 4))
    }

    private var color: Color {
        switch verb {
        case .get: .green
        case .post: .blue
        }
    }
}

private struct Heading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2)
    }
}

private struct FieldLine: View {
    let name: String
    let type: String
    var note: String?
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).font(.system(.callout, design: .monospaced))
            Text(type).font(.caption).foregroundStyle(.blue)
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// A media type with its schema's fields, one level of references expanded on request.
private struct SchemaBlock: View {
    let mediaType: String
    let schema: OpenAPI.Schema

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(mediaType).font(.system(.caption, design: .monospaced))
                Text(schema.typeName).font(.caption).foregroundStyle(.blue)
            }
            if !schema.fields.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(schema.fields) { f in SchemaFieldRow(field: f, depth: 0) }
                }
                .padding(.leading, 10)
            }
        }
    }
}

private struct SchemaFieldRow: View {
    let field: OpenAPI.Field
    let depth: Int
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if !field.schema.fields.isEmpty && depth < 2 {
                    Button { open.toggle() } label: {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 10)
                    }
                    .buttonStyle(.borderless)
                } else {
                    Color.clear.frame(width: 10, height: 1)
                }
                Text(field.name).font(.system(.callout, design: .monospaced))
                Text(field.schema.typeName).font(.caption).foregroundStyle(.blue)
                if !field.required { Text("optional").font(.caption).foregroundStyle(.tertiary) }
                if let d = field.schema.summary {
                    Text(d).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if open {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(field.schema.fields) { SchemaFieldRow(field: $0, depth: depth + 1) }
                }
                .padding(.leading, 18)
            }
        }
    }
}

/// A titled monospaced block with a copy button.
struct SnippetView: View {
    let title: String
    let text: String
    var maxHeight: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                CopyButton(nil, text: text)
            }
            ScrollView(.vertical) {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
            }
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: maxHeight == nil)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }
}

/// Copies text and briefly shows a checkmark.
struct CopyButton: View {
    let title: String?
    let text: String
    @State private var copied = false

    init(_ title: String?, text: String) {
        self.title = title
        self.text = text
    }

    var body: some View {
        Button {
            Clipboard.copy(text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            if let title {
                Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc").labelStyle(.titleOnly)
            } else {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
        }
        .buttonStyle(title == nil ? AnyButtonStyle(.borderless) : AnyButtonStyle(.automatic))
        .help(title ?? "Copy")
    }
}

/// Lets one view pick a button style at run time.
struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: PrimitiveButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
