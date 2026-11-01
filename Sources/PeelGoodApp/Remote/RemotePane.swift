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
                Text(remote.sources.isEmpty ? "Add an S3 bucket to get the labels that land in it." : "No source selected")
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
        if live?.status.lastError != nil { return "Can't connect" }
        let waiting = live?.entries.filter { [.waiting, .held, .unclear].contains($0.state) }.count ?? 0
        if waiting > 0 { return "\(waiting) need\(waiting == 1 ? "s" : "") you" }
        return live?.status.lastCheck == nil ? "Starting" : "Watching"
    }

    private func removeSelected() {
        guard let id = selection, let source = remote.sources.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(source.name)?"
        alert.informativeText = "Peel Good stops watching it and forgets its secret key. Files in the bucket stay as they are."
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

    private var live: RemoteController.Live { remote.live[source.id] ?? RemoteController.Live() }

    var body: some View {
        Form {
            Section(source.name) {
                LabeledContent("Bucket", value: source.s3.bucket)
                if !source.s3.prefix.isEmpty { LabeledContent("Prefix", value: source.s3.prefix) }
                LabeledContent("Endpoint", value: source.s3.endpoint)
                LabeledContent("Status", value: statusText)
                if live.status.skippedOnFirstCheck > 0 {
                    Text("Peel Good started from now, and left the \(live.status.skippedOnFirstCheck) files already there.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let error = live.status.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                Toggle("Pause", isOn: Binding(get: { source.isPaused }, set: { remote.setPaused($0, source.id) }))
                Text("Your rules choose the printer, size and copies. Add one with “From a remote source” to print without asking.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Check Now") { remote.checkNow(source.id) }.disabled(source.isPaused)
                }
            }
            list("Waiting for you", [.waiting]) { e in
                Button("Print") { remote.printNow(e.id, source: source.id) }
                Button("Discard") { remote.discard(e.id, source: source.id) }
            }
            list("Held", [.held]) { e in
                Button("Print") { remote.printNow(e.id, source: source.id) }
                Button("Discard") { remote.discard(e.id, source: source.id) }
            }
            list("Needs a check", [.unclear]) { e in
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
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private var statusText: String {
        if source.isPaused { return "Paused" }
        if !remote.isOnline { return "Offline" }
        if live.status.lastError != nil { return "Can't connect" }
        guard let last = live.status.lastCheck else { return "Starting" }
        return "Checked \(Self.time.string(from: last)), every \(Int(source.interval)) s"
    }

    @ViewBuilder
    private func list<Actions: View>(_ title: String, _ states: [Ledger.State], @ViewBuilder actions: @escaping (Ledger.Entry) -> Actions) -> some View {
        let items = Array(live.entries.filter { states.contains($0.state) }.suffix(20).reversed())
        if !items.isEmpty {
            Section(title) {
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
    @ObservedObject var remote: RemoteController
    let done: (UUID?) -> Void
    @State private var provider = RemoteProvider.aws
    @State private var name = ""
    @State private var region = "us-east-1"
    @State private var account = ""
    @State private var bucket = ""
    @State private var prefix = ""
    @State private var accessKey = ""
    @State private var secret = ""
    @State private var message: String?
    @State private var busy = false

    private var source: S3Source {
        let r = provider == .r2 ? "auto" : region
        return S3Source(endpoint: provider.endpoint(region: r, account: account.trimmingCharacters(in: .whitespaces)), region: r,
                        bucket: bucket.trimmingCharacters(in: .whitespaces), prefix: prefix.trimmingCharacters(in: .whitespaces),
                        accessKey: accessKey.trimmingCharacters(in: .whitespaces), pathStyle: provider != .aws)
    }

    private var isComplete: Bool {
        !bucket.isEmpty && !accessKey.isEmpty && !secret.isEmpty && (provider == .aws || provider == .b2 ? !region.isEmpty : !account.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add S3 Bucket").font(.headline)
            Text("Peel Good checks the bucket every 30 seconds for new labels. It needs permission to list and read only. It connects out from this Mac, and nothing connects in.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                Picker("Service", selection: $provider) { ForEach(RemoteProvider.allCases) { Text($0.rawValue).tag($0) } }
                TextField("Name", text: $name, prompt: Text("Orders"))
                if provider == .r2 { TextField("Account ID", text: $account) }
                if provider == .other { TextField("Endpoint", text: $account, prompt: Text("https://s3.example.com")) }
                if provider == .aws || provider == .b2 || provider == .other { TextField("Region", text: $region) }
                TextField("Bucket", text: $bucket)
                TextField("Prefix", text: $prefix, prompt: Text("Optional, such as labels/"))
                TextField("Access key", text: $accessKey)
                SecureField("Secret key", text: $secret)
            }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Button("Test Connection") { test() }.disabled(!isComplete || busy)
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Add") { add() }.keyboardShortcut(.defaultAction).disabled(!isComplete || busy)
            }
        }
        .padding(20)
        .frame(width: 460)
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
        let new = RemoteSource(name: name.isEmpty ? bucket : name, s3: source)
        Task {
            do {
                try await remote.add(new, secret: secret)
                done(new.id)
            } catch {
                message = "\(error)"
            }
            busy = false
        }
    }
}
