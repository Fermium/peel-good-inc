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
            entry("packing list.pdf", .held, 1, detail: "It has 24 pages"),
            entry("order 1462.pdf", .waiting, 0),
        ])
        var failing = RemoteInbox.Status()
        failing.lastError = "\(RemoteError.denied("SignatureDoesNotMatch"))"
        failing.needsAttention = true
        remote.live[returns.id] = Live(status: failing, entries: [])
        return remote
    }

    private struct PreviewSecrets: SecretStore {
        func secret(for source: UUID) throws -> String? { nil }
        func setSecret(_ secret: String?, for source: UUID) throws {}
    }

    private var listFile: URL { AppPaths.remote.appendingPathComponent("sources.json") }
    private func directory(_ id: UUID) -> URL { AppPaths.remote.appendingPathComponent(id.uuidString, isDirectory: true) }

    /// Labels waiting for someone, across sources.
    var waitingCount: Int { live.values.reduce(0) { $0 + $1.entries.filter { [.waiting, .held, .unclear].contains($0.state) }.count } }

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

    func add(_ source: RemoteSource, secret: String) async throws {
        let secrets = secrets, id = source.id
        try await Task.detached { try secrets.setSecret(secret, for: id) }.value
        sources.append(source)
        save()
        restart(source)
    }

    func remove(_ id: UUID) {
        runners.removeValue(forKey: id)?.cancel()
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

    /// Lists one key and reads one object, without printing or changing anything.
    func test(_ source: S3Source, secret: String) async -> String {
        do {
            let client = try S3Client(source: source, secret: secret)
            return try await client.probe() ? "Peel Good can list and read this bucket." : "Peel Good can list this bucket. It has no files under this prefix yet."
        } catch {
            return "\(error)"
        }
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
        updateActivity()
        guard !source.isPaused else { return }
        runners[source.id] = Task { [weak self] in await self?.run(source) }
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
                    Notifier.shared.tell(title: source.name, body: "\(source.name) sent more labels than Peel Good can hold. Peel Good paused it.")
                    setPaused(true, source.id)
                    return
                }
                failures = status.lastError == nil ? 0 : failures + 1
                report(source, status)
                let delay = status.needsAttention ? 900 : failures > 0 ? min(pow(2, Double(failures)), 300) * .random(in: 0.8...1.2) : source.interval
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

    private func inbox(for source: RemoteSource) async -> RemoteInbox? {
        if let inbox = inboxes[source.id] { return inbox }
        do {
            let secrets = secrets, id = source.id
            guard let secret = try await Task.detached(operation: { try secrets.secret(for: id) }).value else {
                live[id, default: Live()].status.lastError = "Peel Good has no secret key for this source. Remove it and add it again."
                live[id, default: Live()].status.needsAttention = true
                return nil
            }
            let origin = source.s3.origin, name = source.name, sourceID = id.uuidString
            let feed = S3Feed(client: try S3Client(source: source.s3, secret: secret))
            let inbox = try RemoteInbox(feed: feed, directory: directory(id)) { [weak self] delivery in
                await self?.deliver(delivery, origin: origin, source: name, sourceID: sourceID) ?? .notReady("Peel Good is quitting")
            }
            inboxes[id] = inbox
            return inbox
        } catch {
            live[source.id, default: Live()].status.lastError = "\(error)"
            return nil
        }
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

    /// One file through the rules. Nothing a server sent chooses the printer or size.
    static func deliver(_ d: Delivery, origin: String, store: Store, engine: RuleEngine, sender: PrintJob.Sender?) async -> DeliveryResult {
        tag(d.file, origin: origin)
        do {
            guard let plan = try await JobFlow.plan([d.file], trigger: .remote, store: store, engine: engine, copies: d.copies,
                                                    action: d.forced ? .print : nil) else {
                return .notReady("No label printer found")
            }
            // Asking also covers "always review": nothing's on screen to review with.
            guard d.forced || !plan.review else { return .waiting }
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
    /// value comes from the source's settings, never from a server.
    static func tag(_ file: URL, origin: String) {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: [origin], format: .binary, options: 0) else { return }
        _ = data.withUnsafeBytes { Darwin.setxattr(file.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, $0.count, 0, 0) }
    }
}
