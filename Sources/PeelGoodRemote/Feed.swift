import Foundation

public struct RemoteItem: Equatable, Sendable {
    /// Stable across checks, and different when the content changes.
    public var id: String
    public var key: String
    public var name: String
    public var size: Int
    public var modified: Date
    /// Copies the sender asked for, within `Limits.copies`; nil leaves it to the rules.
    public var copies: Int?

    public init(id: String, key: String, name: String, size: Int, modified: Date, copies: Int? = nil) {
        self.id = id
        self.key = key
        self.name = name
        self.size = size
        self.modified = modified
        self.copies = copies
    }
}

/// Where a feed had got to, saved between runs. Nil `watermark`: never checked.
public struct FeedCursor: Codable, Equatable, Sendable {
    public var watermark: Date?
    public init(watermark: Date? = nil) { self.watermark = watermark }
}

public struct FeedPage: Sendable {
    public var items: [RemoteItem]
    /// Recent items seen on the first check, to remember as already there.
    public var baseline: [RemoteItem]
    /// How many existing files the first check left alone.
    public var skippedCount: Int
    public var cursor: FeedCursor
}

public protocol RemoteFeed: Sendable {
    func reconcile(cursor: FeedCursor) async throws -> FeedPage
    func download(_ item: RemoteItem, to file: URL, limit: Int) async throws
}

/// An S3 prefix: lists it and picks out what's new since the last complete listing. Dates come from
/// the server, so the Mac's clock doesn't matter.
public struct S3Feed: RemoteFeed {
    /// Listings overlap by this much, for uploads whose date precedes their appearing. The ledger
    /// keeps the overlap from printing twice.
    static let overlap: TimeInterval = 900

    private let client: S3Client

    public init(client: S3Client) { self.client = client }

    public func reconcile(cursor: FeedCursor) async throws -> FeedPage {
        let (objects, serverDate) = try await client.listAll()
        let next = serverDate.addingTimeInterval(-Self.overlap)
        func item(_ o: S3Object) -> RemoteItem {
            RemoteItem(id: "\(o.key)#\(o.etag)", key: o.key, name: (o.key as NSString).lastPathComponent, size: o.size, modified: o.modified)
        }
        guard let watermark = cursor.watermark else {
            return FeedPage(items: [], baseline: objects.filter { $0.modified >= next }.map(item), skippedCount: objects.count,
                            cursor: FeedCursor(watermark: next))
        }
        return FeedPage(items: objects.filter { $0.modified >= watermark }.sorted { $0.modified < $1.modified }.map(item), baseline: [], skippedCount: 0,
                        cursor: FeedCursor(watermark: max(watermark, next)))
    }

    public func download(_ item: RemoteItem, to file: URL, limit: Int) async throws {
        try await client.download(key: item.key, to: file, limit: limit)
    }
}
