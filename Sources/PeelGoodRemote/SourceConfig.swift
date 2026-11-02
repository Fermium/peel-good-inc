import Foundation

public enum RemoteError: Error, CustomStringConvertible, Equatable, Sendable {
    /// Plain HTTP anywhere but this Mac, or a URL that names a user and password.
    case insecureURL(String)
    case denied(String)
    case server(Int, String)
    case unreadableReply(String)
    case tooLarge(limit: Int)
    /// A message named an address this source isn't allowed to fetch from.
    case refusedAddress(String)
    case checksumMismatch
    /// The data is no longer available, and won't come back.
    case gone
    case tryLater(TimeInterval)

    public var description: String {
        switch self {
        case .insecureURL(let url): "\(url) isn't a secure address. Use https."
        case .denied("SignatureDoesNotMatch"): "The secret key doesn't match this access key."
        case .denied("InvalidAccessKeyId"): "The server doesn't know this access key."
        case .denied(let reason): "The server refused the credentials: \(reason)"
        case .server(let code, let reason): "The server answered \(code)\(reason.isEmpty ? "" : ": \(reason)")"
        case .unreadableReply(let what): "The server sent something unreadable (\(what))"
        case .tooLarge(let limit): "The file is larger than \(limit / 1_000_000) MB"
        case .refusedAddress(let host): "The server named \(host), which this source isn't allowed to download from"
        case .checksumMismatch: "The file doesn't match its checksum"
        case .gone: "The server no longer has this file"
        case .tryLater(let seconds): "The server asked Peel Good to wait \(Int(seconds)) s"
        }
    }

    /// What to show for any error. URL errors can carry the whole address, and a signed link's query
    /// is a credential, so they're reduced to their message.
    public static func describe(_ error: Error) -> String {
        (error as? RemoteError)?.description ?? (error as NSError).localizedDescription
    }

    /// It won't get better by downloading again.
    var isPermanentForFile: Bool {
        switch self {
        case .tooLarge, .refusedAddress, .checksumMismatch, .gone, .insecureURL: true
        case .server(let code, _): code == 404 || code == 410
        default: false
        }
    }

    /// Worth showing as Needs attention and retrying slowly, not a passing network problem.
    public var needsAttention: Bool {
        switch self {
        case .insecureURL, .denied: true
        case .server(let code, _): code == 404
        default: false
        }
    }
}

/// An S3 bucket and prefix to watch. The secret key lives in the Keychain (`SecretStore`).
public struct S3Source: Codable, Equatable, Sendable {
    /// "https://s3.eu-west-1.amazonaws.com", or a store's own endpoint.
    public var endpoint: String
    public var region: String
    public var bucket: String
    public var prefix: String
    public var accessKey: String
    /// bucket in the path rather than the host name: MinIO and many other stores.
    public var pathStyle: Bool

    public init(endpoint: String, region: String, bucket: String, prefix: String = "", accessKey: String, pathStyle: Bool = false) {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.prefix = prefix
        self.accessKey = accessKey
        self.pathStyle = pathStyle
    }

    /// Where a file from this source says it came from, for the rules' Source website condition.
    /// Always this, never anything a server sent.
    public var origin: String {
        var parts = URLComponents(string: endpoint) ?? URLComponents()
        parts.path = "/\(bucket)/\(prefix)".replacingOccurrences(of: "//", with: "/")
        return parts.string ?? endpoint
    }
}

/// Your own server: a jobs URL to poll, a Server-Sent Events stream to follow, or both. The contract
/// is in docs/REMOTE-SOURCES.md. A bearer token, if any, lives in the Keychain.
public struct HTTPSource: Codable, Equatable, Sendable {
    public var jobsURL: String?
    public var streamURL: String?
    /// Other hosts files can come from, such as a storage service for signed links.
    public var downloadHosts: [String]
    /// POST what became of each job back to the jobs URL.
    public var sendsAcknowledgements: Bool

    public init(jobsURL: String? = nil, streamURL: String? = nil, downloadHosts: [String] = [], sendsAcknowledgements: Bool = false) {
        self.jobsURL = jobsURL
        self.streamURL = streamURL
        self.downloadHosts = downloadHosts
        self.sendsAcknowledgements = sendsAcknowledgements
    }

    /// The configured address everything is judged against: its host gets the token.
    public var primaryURL: String { jobsURL ?? streamURL ?? "" }

    public var origin: String {
        guard var parts = URLComponents(string: primaryURL) else { return primaryURL }
        parts.query = nil
        parts.fragment = nil
        return parts.string ?? primaryURL
    }
}

public struct RemoteSource: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        case s3(S3Source)
        case http(HTTPSource)
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var isPaused = false
    /// Seconds between checks.
    public var interval: TimeInterval = 30

    public init(id: UUID = UUID(), name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public init(id: UUID = UUID(), name: String, s3: S3Source) { self.init(id: id, name: name, kind: .s3(s3)) }

    public var origin: String {
        switch kind {
        case .s3(let s): s.origin
        case .http(let h): h.origin
        }
    }

    /// Whether it follows a stream, on top of or instead of checking on an interval.
    public var streamURL: String? {
        if case .http(let h) = kind { h.streamURL } else { nil }
    }
}

public enum RemoteLimits {
    public static let fileBytes = 25_000_000
    public static let replyBytes = 5_000_000
    public static let eventBytes = 2_000_000
    public static let inlineBytes = 1_000_000
    /// What a sender can ask for per job, like everywhere else in the app.
    public static let copies = 1...100
    public static let pagesPerDocument = 20
    public static let labelsPerWindow = 30
    public static let window: TimeInterval = 600
    /// A source this far behind pauses itself.
    public static let heldBeforePausing = 500
}

/// The Keychain in the app, a dictionary in tests.
public protocol SecretStore: Sendable {
    func secret(for source: UUID) throws -> String?
    func setSecret(_ secret: String?, for source: UUID) throws
}

enum SecureURL {
    /// https anywhere; http only to this Mac; never credentials in the URL.
    static func check(_ text: String) throws -> URLComponents {
        guard let url = URLComponents(string: text), let host = url.host, url.user == nil, url.password == nil else {
            throw RemoteError.insecureURL(text)
        }
        let local = host == "127.0.0.1" || host == "localhost"
        guard url.scheme == "https" || (url.scheme == "http" && local) else { throw RemoteError.insecureURL(text) }
        return url
    }
}
