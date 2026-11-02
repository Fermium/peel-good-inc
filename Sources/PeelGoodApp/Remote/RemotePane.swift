import AppKit
import Foundation
import PeelGoodRemote
import SwiftUI

/// Settings › Remote: S3 buckets to watch for labels, what each is doing, and what waits for you.
struct RemotePane: View {
    @ObservedObject var remote: RemoteController
    /// Selected at first (for screenshots).
    var initialSelection: UUID?
    @State private var selection: UUID?
    @State private var adding = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(remote.sources, selection: $selection) { source in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(source.name).lineLimit(1)
                        Text(summary(source)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(source.id)
                }
                Divider()
                HStack(spacing: 0) {
                    Button { adding = true } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                        .help("Add a source")
                    Button { removeSelected() } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                        .disabled(selection == nil)
                        .help("Remove source")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(width: 210)
            Divider()
            if let source = remote.sources.first(where: { $0.id == selection }) {
                RemoteDetail(remote: remote, source: source).id(source.id)
            } else {
                Text(remote.sources.isEmpty ? "Add an S3 bucket, a URL or an event stream to get labels from it." : "No source selected")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 680, height: 500)
        .onAppear { selection = selection ?? initialSelection ?? remote.sources.first?.id }
        .sheet(isPresented: $adding) {
            AddRemoteSheet(remote: remote) { added in
                adding = false
                if let added { selection = added }
            }
        }
    }

    private func summary(_ source: RemoteSource) -> String {
        if source.isPaused { return "Paused" }
        if !remote.isOnline { return "Offline" }
        let live = remote.live[source.id]
        if live?.status.lastError != nil || live?.status.streamError != nil { return "Error" }
        if live?.status.printerProblem != nil { return "Waiting for the printer" }
        let waiting = live?.entries.filter { [.waiting, .held, .unclear, .failed].contains($0.state) }.count ?? 0
        if waiting > 0 { return "\(waiting) label\(waiting == 1 ? " needs" : "s need") you" }
        return live?.status.lastCheck == nil ? "Starting" : "Watching"
    }

    private func removeSelected() {
        guard let id = selection, let source = remote.sources.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(source.name)?"
        alert.informativeText = "Peel Good stops checking it, and deletes its key, its history and any labels still waiting. Your files on the source stay where they are."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        remote.remove(id)
        selection = remote.sources.first?.id
    }
}

private struct RemoteDetail: View {
    @ObservedObject var remote: RemoteController
    let source: RemoteSource

    @State private var editing = false

    private var live: RemoteController.Live { remote.live[source.id] ?? RemoteController.Live() }

    var body: some View {
        Form {
            Section(source.name) {
                switch source.kind {
                case .s3(let s3):
                    LabeledContent("Bucket", value: s3.bucket)
                    if !s3.prefix.isEmpty { LabeledContent("Prefix", value: s3.prefix) }
                    LabeledContent("Endpoint", value: s3.endpoint)
                case .http(let http):
                    if let jobs = http.jobsURL { LabeledContent("URL", value: jobs) }
                    if let stream = http.streamURL { LabeledContent("Event stream", value: stream) }
                    if !http.downloadHosts.isEmpty { LabeledContent("Download hosts", value: http.downloadHosts.joined(separator: ", ")) }
                }
                if let encryption = source.encryption {
                    LabeledContent("This Mac's key") { MacKey(key: encryption.macKey) }
                    Text("Peel Good only accepts labels encrypted by the paired sender.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                LabeledContent("Status", value: statusText)
                if live.status.skippedOnFirstCheck > 0 {
                    Text("Peel Good skipped the \(live.status.skippedOnFirstCheck) \(sendsJobs ? "jobs" : "files") already there.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let error = live.status.lastError ?? live.status.streamError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                if live.status.rejectedJobs > 0 {
                    Text("Peel Good skipped \(live.status.rejectedJobs) job\(live.status.rejectedJobs == 1 ? "" : "s"). Each job needs an ID of 1 to 256 letters, digits, -, _ or ., a url or content_base64, and copies from 1 to 100.")
                        .font(.callout).foregroundStyle(.red)
                }
                if case .http(let http) = source.kind, http.jobsURL == nil {
                    Text("With only a stream, Peel Good can miss labels sent while this Mac is off, unless the stream replays them.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Toggle("Pause", isOn: Binding(get: { source.isPaused }, set: { remote.setPaused($0, source.id) }))
                Text("Your rules choose the printer, size\(sendsCopies ? " and copies, unless a job sets its own" : " and copies"). To print without asking, add a rule: set How it arrives to “From a remote source” and When a file matches to Print.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Edit…") { editing = true }
                    Button("Check Now") { remote.checkNow(source.id) }.disabled(source.isPaused)
                }
            }
            list("Waiting for you", [.waiting], all: true) { e in
                Button("Print") { remote.printNow(e.id, source: source.id) }
                Button("Discard") { remote.discard(e.id, source: source.id) }
            }
            list("Held", [.held], all: true) { e in
                Button("Print") { remote.printNow(e.id, source: source.id) }
                Button("Discard") { remote.discard(e.id, source: source.id) }
            }
            list("May have printed", [.unclear]) { e in
                Button("Print Again") { remote.printNow(e.id, source: source.id) }
                Button("Mark as Printed") { remote.markPrinted(e.id, source: source.id) }
            }
            list("Failed", [.failed]) { e in
                Button("Print Again") { remote.printNow(e.id, source: source.id) }
                Button("Discard") { remote.discard(e.id, source: source.id) }
            }
            list("Printed", [.sent]) { _ in EmptyView() }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $editing) {
            AddRemoteSheet(remote: remote, editing: source) { _ in editing = false }
        }
    }

    private var sendsJobs: Bool { if case .http = source.kind { true } else { false } }
    private var sendsCopies: Bool { sendsJobs || source.encryption != nil }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private var statusText: String {
        if source.isPaused { return "Paused" }
        if !remote.isOnline { return "Offline" }
        if live.status.lastError != nil || live.status.streamError != nil { return "Error" }
        if let problem = live.status.printerProblem { return "Waiting for the printer: \(problem)" }
        if live.status.isStreaming { return "Connected to the stream" }
        guard let last = live.status.lastCheck else { return "Starting" }
        return "Checked \(Self.time.string(from: last)), every \(Int(source.interval)) s"
    }

    @ViewBuilder
    private func list<Actions: View>(_ title: String, _ states: [Ledger.State], all: Bool = false, @ViewBuilder actions: @escaping (Ledger.Entry) -> Actions) -> some View {
        let every = live.entries.filter { states.contains($0.state) }
        let items = Array(every.suffix(20).reversed())
        if !items.isEmpty {
            Section {
                ForEach(items) { e in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.name).lineLimit(1).truncationMode(.middle)
                            if let detail = e.detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                        Spacer()
                        actions(e)
                    }
                }
            } header: {
                HStack {
                    Text(every.count > items.count ? "\(title): newest \(items.count) of \(every.count)" : title)
                    Spacer()
                    if all, every.count > 1 {
                        Button("Print All") { remote.printAll(states, source: source.id) }
                        Button("Discard All") { remote.discardAll(states, source: source.id) }
                    }
                }
            }
        }
    }
}

/// A public key to hand to the sender.
private struct MacKey: View {
    let key: String

    var body: some View {
        HStack {
            Text(key).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(key, forType: .string)
            }
        }
    }
}

/// S3 and the stores that speak its API. Each fills in what it can.
private enum RemoteProvider: String, CaseIterable, Identifiable {
    case aws = "Amazon S3", r2 = "Cloudflare R2", b2 = "Backblaze B2", other = "Other"
    var id: String { rawValue }

    func endpoint(region: String, account: String) -> String {
        switch self {
        case .aws: "https://s3.\(region).amazonaws.com"
        case .r2: "https://\(account).r2.cloudflarestorage.com"
        case .b2: "https://s3.\(region).backblazeb2.com"
        case .other: account
        }
    }
}

struct AddRemoteSheet: View {
    enum Kind: String, CaseIterable, Identifiable {
        case bucket = "S3 Bucket", url = "URL", stream = "Event Stream"
        var id: String { rawValue }
    }

    @ObservedObject var remote: RemoteController
    var initialKind = Kind.bucket
    /// The source to change, instead of adding one.
    var editing: RemoteSource?
    let done: (UUID?) -> Void
    @State private var kind: Kind?
    @State private var provider = RemoteProvider.aws
    @State private var name = ""
    @State private var region = "us-east-1"
    @State private var account = ""
    @State private var bucket = ""
    @State private var prefix = ""
    @State private var accessKey = ""
    @State private var secret = ""
    @State private var jobsURL = ""
    @State private var streamURL = ""
    @State private var downloadHosts = ""
    @State private var acknowledges = false
    @State private var encrypted = false
    @State private var macKey = ""
    @State private var senderKey = ""
    /// Made when encryption first goes on, and saved along with the source.
    @State private var newPrivateKey: String?
    @State private var message: String?
    @State private var busy = false

    private var current: Kind { kind ?? initialKind }

    private var source: RemoteSource.Kind {
        switch current {
        case .bucket:
            let r = provider == .r2 ? "auto" : region
            return .s3(S3Source(endpoint: provider.endpoint(region: r, account: account.trimmingCharacters(in: .whitespaces)), region: r,
                                bucket: bucket.trimmingCharacters(in: .whitespaces), prefix: prefix.trimmingCharacters(in: .whitespaces),
                                accessKey: accessKey.trimmingCharacters(in: .whitespaces), pathStyle: provider != .aws))
        case .url, .stream:
            func clean(_ s: String) -> String? { let t = s.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t }
            return .http(HTTPSource(jobsURL: current == .url ? clean(jobsURL) : nil, streamURL: clean(streamURL),
                                    downloadHosts: downloadHosts.split(separator: ",").map(String.init), sendsAcknowledgements: current == .url && acknowledges))
        }
    }

    private var explanation: String {
        let direction = "It connects out from this Mac, and nothing connects in."
        return switch current {
        case .bucket: "Peel Good checks the bucket every 30 seconds, and treats each new file under the prefix as a label. It needs permission to list and read only. \(direction)"
        case .url: "Peel Good fetches this URL every 30 seconds. The URL can serve a list of jobs or a label file. \(direction)"
        case .stream: "Peel Good stays connected to this Server-Sent Events URL and picks up each label event. \(direction)"
        }
    }

    private var isComplete: Bool {
        if encrypted, !SealedLabel.isValidKey(senderKey) { return false }
        return switch current {
        case .bucket: !bucket.isEmpty && !accessKey.isEmpty && (editing != nil || !secret.isEmpty) && (provider == .aws || provider == .b2 ? !region.isEmpty : !account.isEmpty)
        case .url: !jobsURL.isEmpty
        case .stream: !streamURL.isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editing == nil ? "Add Remote Source" : "Edit \(editing?.name ?? "Source")").font(.headline)
            Picker("", selection: Binding(get: { current }, set: { kind = $0; message = nil })) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(explanation)
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $name, prompt: Text("Orders"))
                if current == .bucket {
                    Picker("Service", selection: $provider) { ForEach(RemoteProvider.allCases) { Text($0.rawValue).tag($0) } }
                    if provider == .r2 { TextField("Account ID", text: $account) }
                    if provider == .other { TextField("Endpoint", text: $account, prompt: Text("https://s3.example.com")) }
                    if provider != .r2 { TextField("Region", text: $region) }
                    TextField("Bucket", text: $bucket)
                    TextField("Prefix", text: $prefix, prompt: Text("Optional, such as labels/"))
                    TextField("Access key", text: $accessKey)
                    SecureField("Secret key", text: $secret, prompt: editing == nil ? nil : Text("Unchanged"))
                } else {
                    if current == .url {
                        TextField("URL", text: $jobsURL, prompt: Text("https://example.com/labels/jobs"))
                        TextField("Event stream", text: $streamURL, prompt: Text("Optional, on the same host, for faster delivery"))
                    } else {
                        TextField("Stream URL", text: $streamURL, prompt: Text("https://example.com/labels/events"))
                    }
                    SecureField("Token", text: $secret, prompt: Text(editing == nil ? "Optional bearer token" : "Unchanged"))
                    TextField("Download hosts", text: $downloadHosts, prompt: Text("Optional, such as files.example.com"))
                    if current == .url { Toggle("Report each job's result to this URL", isOn: $acknowledges) }
                }
                Toggle("Only accept encrypted labels", isOn: $encrypted)
                    .onChange(of: encrypted) { _, on in
                        guard on, macKey.isEmpty else { return }
                        let keys = SealedLabel.newKeys()
                        newPrivateKey = keys.privateKey
                        macKey = keys.publicKey
                    }
                if encrypted {
                    LabeledContent("This Mac's key") { MacKey(key: macKey) }
                    TextField("Sender's key", text: $senderKey, prompt: Text("The sender's public key"))
                    Text("Give the sender this Mac's key. Peel Good then refuses anything this sender didn't encrypt.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if current == .stream {
                Text("With only a stream, Peel Good can miss labels sent while this Mac is off, unless the stream replays them.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Button("Test Connection") { test() }.disabled(!isComplete || busy)
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Add" : "Save") { add() }.keyboardShortcut(.defaultAction).disabled(!isComplete || busy)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear(perform: load)
    }

    /// Fills the form from the source being edited.
    private func load() {
        guard let editing else { return }
        name = editing.name
        if let encryption = editing.encryption {
            encrypted = true
            macKey = encryption.macKey
            senderKey = encryption.senderKey
        }
        switch editing.kind {
        case .s3(let s3):
            kind = .bucket
            bucket = s3.bucket
            prefix = s3.prefix
            accessKey = s3.accessKey
            region = s3.region
            if s3.endpoint.hasSuffix(".amazonaws.com") {
                provider = .aws
            } else if s3.endpoint.hasSuffix(".r2.cloudflarestorage.com") {
                provider = .r2
                account = URLComponents(string: s3.endpoint)?.host?.components(separatedBy: ".").first ?? ""
            } else if s3.endpoint.hasSuffix(".backblazeb2.com") {
                provider = .b2
            } else {
                provider = .other
                account = s3.endpoint
            }
        case .http(let http):
            kind = http.jobsURL == nil ? .stream : .url
            jobsURL = http.jobsURL ?? ""
            streamURL = http.streamURL ?? ""
            downloadHosts = http.downloadHosts.joined(separator: ", ")
            acknowledges = http.sendsAcknowledgements
        }
    }

    private func test() {
        busy = true
        Task {
            message = await remote.test(source, secret: secret)
            busy = false
        }
    }

    private func add() {
        busy = true
        let fallback = current == .bucket ? bucket : URLComponents(string: jobsURL.isEmpty ? streamURL : jobsURL)?.host ?? "URL"
        var new = RemoteSource(name: name.isEmpty ? fallback : name, kind: source)
        if let editing {
            new.id = editing.id
            new.isPaused = editing.isPaused
            new.interval = editing.interval
        }
        new.encryption = encrypted ? SourceEncryption(macKey: macKey, senderKey: senderKey.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
        let privateKey = encrypted ? newPrivateKey : nil
        Task {
            do {
                if editing == nil { try await remote.add(new, secret: secret, privateKey: privateKey) } else { try await remote.update(new, secret: secret, privateKey: privateKey) }
                done(new.id)
            } catch {
                message = RemoteError.describe(error)
            }
            busy = false
        }
    }
}
