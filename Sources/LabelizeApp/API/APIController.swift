import AppKit
import Combine

/// Owns the local server: the HTTP API and MCP switches (both off by default), the port and
/// the token. One listener on 127.0.0.1 serves both; it runs while either is on.
///
/// Launch arguments for development: `-apiMock` serves `MockLabelService`; `-apiDryRun` keeps
/// the real service but never calls `lp`. Defaults can be overridden for one run, for example
/// `-apiHTTPEnabled YES -apiMCPEnabled YES -apiPort 47399`.
@MainActor
final class APIController: ObservableObject {
    static let shared = APIController()

    enum Status: Equatable {
        case off, starting
        case running(port: Int)
        case failed(String)
    }

    private enum Key {
        static let http = "apiHTTPEnabled", mcp = "apiMCPEnabled", port = "apiPort"
        static let mcpLocalFiles = "apiMCPLocalFiles", mcpSettingsGrant = "apiMCPSettingsGrant", mcpSettingsUntil = "apiMCPSettingsUntil"
        static let legacySettings = "apiMCPSettings", legacyAutoOff = "apiMCPSettingsAutoOff"
    }

    /// How long "Let MCP change settings" stays on when set to For 45 Minutes.
    static let settingsGrant: TimeInterval = 45 * 60

    @Published private(set) var status: Status = .off
    @Published private(set) var token: String
    @Published private(set) var mcpSessions = 0
    private(set) var service: LabelService?

    private let defaults = UserDefaults.standard
    private let state = APIServerState()
    private var server: APIServer?
    private var applying: Task<Void, Never>?

    var httpEnabled: Bool {
        get { defaults.bool(forKey: Key.http) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.http); Log.notice(.api, "HTTP API \(newValue ? "on" : "off")"); apply() }
    }

    var mcpEnabled: Bool {
        get { defaults.bool(forKey: Key.mcp) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.mcp); Log.notice(.api, "MCP server \(newValue ? "on" : "off")"); apply() }
    }

    /// MCP may print paths on this Mac, the clipboard, and reprint. Off by default; only Settings can change it.
    var mcpCanUseLocalFiles: Bool {
        get { defaults.bool(forKey: Key.mcpLocalFiles) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.mcpLocalFiles); Log.notice(.api, "MCP local files \(newValue ? "allowed" : "not allowed")") }
    }

    /// "Let MCP change settings": Off, For 45 Minutes, or Always.
    enum SettingsGrant: String, CaseIterable {
        case off, timed, always

        var title: String {
            switch self {
            case .off: "Off"
            case .timed: "For 45 Minutes"
            case .always: "Always"
            }
        }
    }

    /// MCP may change settings, rules and watched folders. Off by default; only Settings can change it.
    /// For 45 Minutes turns itself off when the time is up, including after a relaunch.
    var mcpSettingsGrant: SettingsGrant {
        get {
            let grant = SettingsGrant(rawValue: defaults.string(forKey: Key.mcpSettingsGrant) ?? "") ?? .off
            if grant == .timed, let until = mcpSettingsUntil, until <= Date() { return .off }
            return grant
        }
        set {
            objectWillChange.send()
            defaults.set(newValue.rawValue, forKey: Key.mcpSettingsGrant)
            mcpSettingsUntil = newValue == .timed ? Date().addingTimeInterval(Self.settingsGrant) : nil
            Log.notice(.api, "MCP settings changes: \(newValue.title.lowercased())" + (mcpSettingsUntil.map { ", until \($0.formatted(date: .omitted, time: .shortened))" } ?? ""))
            scheduleSettingsExpiry()
        }
    }

    /// True while `mcpSettingsGrant` isn't Off. Turning it on from Off grants 45 minutes.
    var mcpCanChangeSettings: Bool {
        get { mcpSettingsGrant != .off }
        set {
            if !newValue { mcpSettingsGrant = .off } else if mcpSettingsGrant == .off { mcpSettingsGrant = .timed }
        }
    }

    /// When the settings permission turns itself off; nil when it's off or Always.
    private(set) var mcpSettingsUntil: Date? {
        get { defaults.object(forKey: Key.mcpSettingsUntil) as? Date }
        set { defaults.set(newValue, forKey: Key.mcpSettingsUntil) }
    }

    private var settingsExpiry: Task<Void, Never>?

    /// Turns the timed settings permission off when its time is up, including after a relaunch.
    private func scheduleSettingsExpiry() {
        settingsExpiry?.cancel()
        guard defaults.string(forKey: Key.mcpSettingsGrant) == SettingsGrant.timed.rawValue else { return }
        guard let until = mcpSettingsUntil else {
            // No end time saved: give it a fresh 45 minutes.
            mcpSettingsUntil = Date().addingTimeInterval(Self.settingsGrant)
            return scheduleSettingsExpiry()
        }
        settingsExpiry = Task { [weak self] in
            let wait = until.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, let self else { return }
            self.objectWillChange.send()
            self.defaults.set(SettingsGrant.off.rawValue, forKey: Key.mcpSettingsGrant)
            self.mcpSettingsUntil = nil
            Log.notice(.api, "MCP settings changes turned off after 45 minutes")
        }
    }

    /// Before the pop-up, a switch (`apiMCPSettings`) and "Turn off after 45 minutes" (`apiMCPSettingsAutoOff`, on by default).
    /// Runs once: on with auto-off becomes For 45 Minutes (keeping its end time), on without it Always.
    func migrateSettingsGrant() {
        guard defaults.object(forKey: Key.mcpSettingsGrant) == nil,
              defaults.object(forKey: Key.legacySettings) != nil || defaults.object(forKey: Key.legacyAutoOff) != nil else { return }
        let on = defaults.bool(forKey: Key.legacySettings)
        let autoOff = defaults.object(forKey: Key.legacyAutoOff) as? Bool ?? true
        let grant: SettingsGrant = !on ? .off : autoOff ? .timed : .always
        defaults.set(grant.rawValue, forKey: Key.mcpSettingsGrant)
        if grant != .timed { mcpSettingsUntil = nil }
        defaults.removeObject(forKey: Key.legacySettings)
        defaults.removeObject(forKey: Key.legacyAutoOff)
        Log.notice(.api, "MCP settings permission moved to the pop-up: \(grant.title)")
    }

    /// What MCP's configuration tools edit. Set by `attach`.
    private(set) var configurator: AppConfigurator?

    var port: Int {
        get {
            let saved = defaults.integer(forKey: Key.port)   // also reads "-apiPort 47399" launch arguments
            return Self.validPorts.contains(saved) ? saved : APISettings.defaultPort
        }
        set {
            guard Self.validPorts.contains(newValue), newValue != port else { return }
            objectWillChange.send()
            defaults.set(newValue, forKey: Key.port)
            Log.notice(.api, "port set to \(newValue)")
            apply()
        }
    }

    static let validPorts = 1024...65535

    /// The port clients should use: the bound one while running, else the setting.
    var activePort: Int {
        if case .running(let p) = status { return p }
        return port
    }

    var isRunning: Bool { if case .running = status { true } else { false } }

    private init() {
        token = APISettings.loadOrCreateToken()
        defer { migrateSettingsGrant(); scheduleSettingsExpiry() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            APISettings.removeServerInfo()
        }
    }

    /// Call once at launch with the app's service. Starts the server if a switch is on.
    /// `configurator` defaults to the live settings, rules and watched folders (in memory for `-apiMock` and `-apiDryRun`).
    func attach(_ service: LabelService, configurator custom: AppConfigurator? = nil) {
        let args = ProcessInfo.processInfo.arguments
        let dev = args.contains("-apiMock") || args.contains("-apiDryRun")
        if args.contains("-apiMock") {
            Log.notice(.api, "using the mock label service (-apiMock)")
            self.service = MockLabelService()
        } else {
            if args.contains("-apiDryRun"), let app = service as? AppLabelService {
                Log.notice(.api, "dry run: jobs won't reach a printer (-apiDryRun)")
                app.sender = AppLabelService.dryRunSender
            }
            self.service = service
        }
        // Development runs edit rules and watched folders in memory, never the real rules.json.
        let store = (service as? AppLabelService)?.store ?? Store()
        configurator = custom ?? (dev ? AppConfigurator(store: store, rules: RuleEngine(fileURL: nil), folders: .inMemory())
                           : AppConfigurator(store: store, rules: .shared, folders: .live))
        // Prints follow the same rules the configuration tools edit.
        (self.service as? AppLabelService)?.rules = configurator!.rules
        apply()
    }

    func regenerateToken() {
        token = APISettings.regenerateToken()
        state.update { [token] in $0.token = token }
    }

    /// Brings the listener in line with the switches. Calls run one after another.
    func apply() {
        let previous = applying
        applying = Task {
            await previous?.value
            await reconcile()
        }
    }

    private func reconcile() async {
        let http = httpEnabled, mcp = mcpEnabled, token = token
        let wanted = service != nil && (http || mcp)
        state.update { $0.http = http; $0.mcp = mcp; $0.token = token }

        if let running = server, !wanted || running.port != port {
            server = nil
            await running.stop()
            Log.notice(.api, "server stopped")
            APISettings.removeServerInfo()
            status = .off
        }
        if wanted && server == nil {
            await start()
        } else if wanted, case .running(let p) = status {
            APISettings.writeServerInfo(port: p, http: http, mcp: mcp)
        }
        if !wanted { status = .off }
    }

    private func start() async {
        let port = port
        status = .starting
        state.update { $0.port = port }
        let started: Int? = await withCheckedContinuation { (done: CheckedContinuation<Int?, Never>) in
            let once = OnceFlag()
            let server = APIServer(port: port, state: state, onRunning: { bound in
                if once.claim() { done.resume(returning: bound) }
            }, onExit: { error in
                if once.claim() { done.resume(returning: nil) }
                Task { @MainActor in APIController.shared.serverExited(port: port, error: error) }
            })
            self.server = server
        }
        guard let bound = started else { return }   // serverExited reports the error
        state.update { $0.port = bound }
        status = .running(port: bound)
        APISettings.writeServerInfo(port: bound, http: httpEnabled, mcp: mcpEnabled)
        Log.notice(.api, "server running on 127.0.0.1:\(bound) (HTTP API \(httpEnabled ? "on" : "off"), MCP \(mcpEnabled ? "on" : "off"))")
    }

    private func serverExited(port: Int, error: Error?) {
        guard server?.port == port else { return }   // a stop we asked for
        server = nil
        APISettings.removeServerInfo()
        let message = error.map(Self.describe) ?? "Server stopped."
        Log.error(.api, "server on port \(port) stopped: \(message)")
        status = .failed(message)
    }

    private static func describe(_ error: Error) -> String {
        let text = "\(error)"
        if text.contains("Address already in use") || text.contains("errno: 48") { return "Port is already in use." }
        return text
    }
}

/// Lets exactly one of several callbacks resume a continuation.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
