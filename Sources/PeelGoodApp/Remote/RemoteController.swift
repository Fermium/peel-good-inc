import AppKit
import LabelKit
import Network
import PeelGoodCore
import PeelGoodRemote
import PeelGoodShared

/// Remote sources while the app runs: keeps their list, checks each on its interval and when the Mac
/// wakes or comes back online, and prints what they find through the rules. Every connection goes
/// out from this Mac; nothing here listens.
@MainActor
final class RemoteController: ObservableObject {
    static let shared = RemoteController(secrets: KeychainSecretStore())

    struct Live: Equatable {
        var status = RemoteInbox.Status()
        var entries: [Ledger.Entry] = []
    }

    @Published private(set) var sources: [RemoteSource] = []
    @Published private(set) var live: [UUID: Live] = [:]
    @Published private(set) var isOnline = true

    private let secrets: any SecretStore
    private var store: Store?
    private var inboxes: [UUID: RemoteInbox] = [:]
    private var runners: [UUID: Task<Void, Never>] = [:]
    private var followers: [UUID: Task<Void, Never>] = [:]
    /// Inboxes being opened. A source's poll and stream ask at once, and must share one: its ledger is
    /// the memory of what printed.
    private var opening: [UUID: Task<RemoteInbox?, Never>] = [:]
    private var failingSince: [UUID: Date] = [:]
    private var told: Set<UUID> = []
    private let path = NWPathMonitor()
    private var activity: NSObjectProtocol?
    var sender: PrintJob.Sender?
    /// Asks about a label: its name, the question, its source and its id. Replaced in tests, which have no app bundle.
    var ask: (String, String, String, String) -> Void = { Notifier.shared.askRemote(name: $0, detail: $1, source: $2, item: $3) }

    init(secrets: any SecretStore) { self.secrets = secrets }

    /// Sample sources for screenshots: nothing runs and nothing connects.
    static func preview() -> RemoteController {
        let remote = RemoteController(secrets: PreviewSecrets())
        let now = Date()
        let orders = RemoteSource(name: "Orders", s3: S3Source(endpoint: "https://s3.eu-west-1.amazonaws.com", region: "eu-west-1", bucket: "acme-shipping", prefix: "labels/", accessKey: "AKIAEXAMPLE"))
        let returns = RemoteSource(name: "Returns", s3: S3Source(endpoint: "https://example.r2.cloudflarestorage.com", region: "auto", bucket: "returns", accessKey: "EXAMPLE", pathStyle: true))
        var paused = RemoteSource(name: "Warehouse B", s3: S3Source(endpoint: "https://s3.us-east-1.amazonaws.com", region: "us-east-1", bucket: "wh-b", accessKey: "AKIAEXAMPLE"))
        paused.isPaused = true
        remote.sources = [orders, returns, paused]
        func entry(_ name: String, _ state: Ledger.State, _ minutes: Double, detail: String? = nil, labels: Int? = nil) -> Ledger.Entry {
            Ledger.Entry(id: name, key: "labels/\(name)", name: name, size: 42_000, modified: now, state: state, at: now.addingTimeInterval(-minutes * 60), detail: detail, labels: labels)
        }
        var status = RemoteInbox.Status()
        status.lastCheck = now.addingTimeInterval(-12)
        status.skippedOnFirstCheck = 1342
        remote.live[orders.id] = Live(status: status, entries: [
            entry("order 1458.pdf", .sent, 9, labels: 1),
            entry("order 1459.pdf", .sent, 4, labels: 2),
            entry("order 1460.pdf", .failed, 3, detail: "USB printer stopped after 2048 of 3470 bytes because it's out of labels. Check what printed before you print again"),
            entry("order 1461.pdf", .unclear, 2, detail: "Peel Good stopped while this was printing. It may have printed."),
            entry("packing list.pdf", .held, 1, detail: "This would pass 30 labels in 10 minutes."),
            entry("order 1462.pdf", .waiting, 0),
        ])
        var failing = RemoteInbox.Status()
        failing.lastError = "\(RemoteError.denied("SignatureDoesNotMatch"))"
        failing.needsAttention = true
        remote.live[returns.id] = Live(status: failing, entries: [])
        var stream = RemoteInbox.Status()
        stream.isStreaming = true
        stream.lastCheck = now
        let server = RemoteSource(name: "Shop labels", kind: .http(HTTPSource(jobsURL: "https://shop.example.com/labels/jobs", streamURL: "https://shop.example.com/labels/events", downloadHosts: ["files.example.net"], sendsAcknowledgements: true)))
        remote.sources.append(server)
        remote.live[server.id] = Live(status: stream, entries: [entry("order 88.pdf", .sent, 1, labels: 3)])
        return remote
    }

    private struct PreviewSecrets: SecretStore {
        func secret(for source: UUID) throws -> String? { nil }
        func setSecret(_ secret: String?, for source: UUID) throws {}
    }

    private var listFile: URL { AppPaths.remote.appendingPathComponent("sources.json") }
    private func directory(_ id: UUID) -> URL { AppPaths.remote.appendingPathComponent(id.uuidString, isDirectory: true) }

    /// Labels waiting for someone, across sources.
    var waitingCount: Int { live.values.reduce(0) { $0 + $1.entries.filter { [.waiting, .held, .unclear, .failed].contains($0.state) }.count } }

    func start(store: Store) {
        self.store = store
        sources = (try? Data(contentsOf: listFile)).flatMap { try? JSONDecoder().decode([RemoteSource].self, from: $0) } ?? []
        path.pathUpdateHandler = { [weak self] update in
            let online = update.status == .satisfied
            Task { @MainActor in self?.setOnline(online) }
        }
        path.start(queue: DispatchQueue(label: "PeelGood.RemotePath"))
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAll() }
        }
        restartAll()
    }

    // MARK: Changing sources

    /// `secret` is an S3 secret key, or the bearer token for a URL, if it needs one.
    func add(_ source: RemoteSource, secret: String?) async throws {
        // Refuse a source that could never start, while the person is here to fix it.
        if case .http(let http) = source.kind { _ = try HTTPFeed(source: http, token: nil) }
        let secrets = secrets, id = source.id
        try await Task.detached { try secrets.setSecret(secret?.isEmpty == true ? nil : secret, for: id) }.value
        sources.append(source)
        save()
        restart(source)
    }

    func remove(_ id: UUID) {
        runners.removeValue(forKey: id)?.cancel()
        followers.removeValue(forKey: id)?.cancel()
        opening[id] = nil
        inboxes[id] = nil
        live[id] = nil
        sources.removeAll { $0.id == id }
        save()
        try? FileManager.default.removeItem(at: directory(id))
        let secrets = secrets
        Task.detached { try? secrets.setSecret(nil, for: id) }
        updateActivity()
    }

    func setPaused(_ paused: Bool, _ id: UUID) {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[i].isPaused = paused
        save()
        restart(sources[i])
    }

    /// Pauses or resumes every source (the menu bar menu).
    func setAllPaused(_ paused: Bool) {
        for s in sources where s.isPaused != paused { setPaused(paused, s.id) }
    }

    func checkNow(_ id: UUID) {
        if let s = sources.first(where: { $0.id == id }) { restart(s) }
    }

    /// Tries the connection without printing, acknowledging or changing anything.
    func test(_ kind: RemoteSource.Kind, secret: String?) async -> String {
        do {
            switch kind {
            case .s3(let source):
                let client = try S3Client(source: source, secret: secret ?? "")
                return try await client.probe() ? "Peel Good can list and read this bucket." : "Peel Good can list this bucket. It found no file to test reading."
            case .http(let source):
                return try await HTTPFeed(source: source, token: secret, sendAcknowledgements: false).test()
            }
        } catch {
            return RemoteError.describe(error)
        }
    }

    func printAll(_ states: [Ledger.State], source id: UUID) {
        act(id) { await $0.printAll(states) }
    }

    func discardAll(_ states: [Ledger.State], source id: UUID) {
        act(id) { await $0.discardAll(states) }
    }

    /// Changes a source and keeps its history. A new address starts from now, like a new source.
    /// A blank `secret` keeps the saved one.
    func update(_ source: RemoteSource, secret: String?) async throws {
        if case .http(let http) = source.kind { _ = try HTTPFeed(source: http, token: nil) }
        let secrets = secrets, id = source.id
        if let secret, !secret.isEmpty { try await Task.detached { try secrets.setSecret(secret, for: id) }.value }
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        if sources[i].kind != source.kind { try? FileManager.default.removeItem(at: directory(id).appendingPathComponent("cursor.json")) }
        sources[i] = source
        save()
        inboxes[id] = nil
        restart(source)
    }

    func printNow(_ item: String, source id: UUID) {
        act(id) { await $0.printNow(item) }
    }

    func markPrinted(_ item: String, source id: UUID) {
        act(id) { await $0.markPrinted(item) }
    }

    func discard(_ item: String, source id: UUID) {
        act(id) { await $0.discard(item) }
    }

    private func act(_ id: UUID, _ action: @escaping @Sendable (RemoteInbox) async -> Void) {
        guard let inbox = inboxes[id] else { return }
        Task {
            await action(inbox)
            await refresh(id, inbox)
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: AppPaths.remote, withIntermediateDirectories: true)
        try? JSONEncoder().encode(sources).write(to: listFile, options: .atomic)
    }

    // MARK: Running

    private func setOnline(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        if online { restartAll() }
    }

    private func restartAll() { sources.forEach(restart) }

    /// A runner's sleep can't be interrupted politely, so waking one up means starting it again. The
    /// inbox stays, and a check in progress is cancelled at its next suspension.
    private func restart(_ source: RemoteSource) {
        runners.removeValue(forKey: source.id)?.cancel()
        followers.removeValue(forKey: source.id)?.cancel()
        updateActivity()
        guard !source.isPaused else { return }
        runners[source.id] = Task { [weak self] in await self?.run(source) }
        if source.streamURL != nil { followers[source.id] = Task { [weak self] in await self?.follow(source) } }
    }

    /// Stays connected to a source's stream, reconnecting with growing waits.
    private func follow(_ source: RemoteSource) async {
        var backoff = Backoff()
        while !Task.isCancelled {
            guard isOnline, let inbox = await inbox(for: source) else {
                try? await Task.sleep(for: .seconds(30))
                continue
            }
            let started = Date()
            var hint: TimeInterval?
            var attention = false
            do {
                hint = try await inbox.follow()
            } catch {
                attention = (error as? RemoteError)?.needsAttention ?? false
            }
            await refresh(source.id, inbox)
            let wait = backoff.next(connectedFor: Date().timeIntervalSince(started))
            // A refused token won't fix itself soon, and a stream asking for a wait gets it.
            try? await Task.sleep(for: .seconds(attention ? 900 : max(wait, hint ?? 0)))
        }
    }

    private func run(_ source: RemoteSource) async {
        var failures = 0
        while !Task.isCancelled {
            if isOnline, let inbox = await inbox(for: source) {
                await inbox.check()
                await refresh(source.id, inbox)
                let status = await inbox.status
                if status.shouldPause {
                    Log.warning(.remote, "\(source.name): paused, too many labels waiting")
                    Notifier.shared.tell(title: source.name, body: "\(RemoteLimits.heldBeforePausing) labels are waiting, so Peel Good paused this source. Print or discard them in Settings › Remote.")
                    setPaused(true, source.id)
                    return
                }
                failures = status.lastError == nil ? 0 : failures + 1
                report(source, status)
                let delay = status.retryAfter ?? (status.needsAttention ? 900 : failures > 0 ? min(pow(2, Double(failures)), 300) * .random(in: 0.8...1.2) : source.interval)
                try? await Task.sleep(for: .seconds(delay))
            } else {
                try? await Task.sleep(for: .seconds(failures > 0 ? 60 : source.interval))
            }
        }
    }

    /// The failure shows in Settings at once, and as one notification if it lasts 10 minutes.
    private func report(_ source: RemoteSource, _ status: RemoteInbox.Status) {
        guard let error = status.lastError else {
            failingSince[source.id] = nil
            told.remove(source.id)
            return
        }
        let since = failingSince[source.id] ?? Date()
        failingSince[source.id] = since
        Log.warning(.remote, "\(source.name): \(error)")
        if Date().timeIntervalSince(since) > 600, told.insert(source.id).inserted {
            Notifier.shared.tell(title: source.name, body: error)
        }
    }

    func inbox(for source: RemoteSource) async -> RemoteInbox? {
        if let inbox = inboxes[source.id] { return inbox }
        if let open = opening[source.id] { return await open.value }
        let open = Task { await openInbox(for: source) }
        opening[source.id] = open
        let inbox = await open.value
        opening[source.id] = nil
        return inbox
    }

    private func openInbox(for source: RemoteSource) async -> RemoteInbox? {
        do {
            let secrets = secrets, id = source.id
            // After an update, macOS may ask before handing over the key, and nothing runs until someone answers.
            let notice = Task { [weak self] in
                try await Task.sleep(for: .seconds(3))
                self?.live[id, default: Live()].status.lastError = "Allow Keychain access to start this source."
            }
            defer { notice.cancel() }
            let secret = try await Task.detached(operation: { try secrets.secret(for: id) }).value
            let origin = source.origin, name = source.name, sourceID = id.uuidString
            let feed: any RemoteFeed
            switch source.kind {
            case .s3(let s3):
                guard let secret else {
                    live[id, default: Live()].status.lastError = "Peel Good has no secret key for this source. Remove it and add it again."
                    live[id, default: Live()].status.needsAttention = true
                    return nil
                }
                feed = S3Feed(client: try S3Client(source: s3, secret: secret))
            case .http(let http):
                // A dry run prints nothing, so it reports nothing either.
                feed = try HTTPFeed(source: http, token: secret, sendAcknowledgements: !PrintJob.isDryRun)
            }
            let inbox = try RemoteInbox(feed: feed, directory: directory(id), changed: { [weak self] in
                Task { @MainActor in await self?.refresh(id) }
            }) { [weak self] delivery in
                await self?.deliver(delivery, origin: origin, source: name, sourceID: sourceID) ?? .notReady("Peel Good is quitting")
            }
            inboxes[id] = inbox
            return inbox
        } catch {
            live[source.id, default: Live()].status.lastError = RemoteError.describe(error)
            return nil
        }
    }

    private func refresh(_ id: UUID) async {
        if let inbox = inboxes[id] { await refresh(id, inbox) }
    }

    private func refresh(_ id: UUID, _ inbox: RemoteInbox) async {
        let next = Live(status: await inbox.status, entries: await inbox.entries.filter { $0.state != .skipped })
        if live[id] != next { live[id] = next }
    }

    /// Stops App Nap from stretching the checks while a source runs. The Mac can still sleep.
    private func updateActivity() {
        let needed = sources.contains { !$0.isPaused }
        if needed, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Checking remote sources")
        } else if !needed, let token = activity {
            ProcessInfo.processInfo.endActivity(token)
            activity = nil
        }
    }

    // MARK: Printing

    private func deliver(_ d: Delivery, origin: String, source: String, sourceID: String) async -> DeliveryResult {
        guard let store else { return .notReady("Peel Good is starting") }
        let result = await Self.deliver(d, origin: origin, store: store, engine: .shared, sender: sender)
        Log.info(.remote, "\(source): \(d.name): \(result)")
        if case .waiting = result {
            ask(d.name, "From \(source). Print it?", sourceID, d.id)
        }
        return result
    }

    /// One file through the rules. Nothing in a reply chooses the printer or size.
    static func deliver(_ d: Delivery, origin: String, store: Store, engine: RuleEngine, sender: PrintJob.Sender?) async -> DeliveryResult {
        tag(d.file, origin: origin)
        do {
            guard let plan = try await JobFlow.plan([d.file], trigger: .remote, store: store, engine: engine, copies: d.copies,
                                                    action: d.forced ? .print : nil) else {
                return .notReady("No label printer found")
            }
            // Asking also covers "always review": nothing's on screen to review with.
            guard d.forced || !plan.review else { return .waiting }
            guard d.fits(copies: plan.copies) else { return .overLimit }
            // Fresh, not the list from the last refresh: this decides whether the label waits.
            let settings = store.settings, name = plan.printer.name
            let now = await Task.detached { settings.printers(zebraStatus: settings.zebraStatus()) }.value.first { $0.name == name }
            if now?.state == .stopped { return .notReady(now?.problem ?? "The printer stopped") }
            let (outcome, labels) = await JobFlow.runQuietly(plan, store: store, sender: sender)
            switch outcome {
            case .printed: return .sent(labels: labels)
            case .cancelled: return .cancelled
            case .failed(let reason): return .failed(reason)
            }
        } catch {
            return .failed("\(error)")
        }
    }

    /// Says where a file came from the way browsers do, for the rules' Source website condition. The
    /// value comes from the source's settings, never from a reply.
    static func tag(_ file: URL, origin: String) {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: [origin], format: .binary, options: 0) else { return }
        _ = data.withUnsafeBytes { Darwin.setxattr(file.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, $0.count, 0, 0) }
    }
}
