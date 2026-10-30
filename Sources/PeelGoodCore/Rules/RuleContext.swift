import CoreGraphics
import Foundation
import LabelKit

/// What rules can know about one incoming file.
public struct RuleContext: Sendable {
    public struct Code: Sendable, Hashable {
        public var symbology: String
        public var payload: String
        public init(symbology: String, payload: String) {
            self.symbology = symbology
            self.payload = payload
        }
    }

    public var trigger: RuleTrigger
    public var fileName: String
    public var kind: FileKind?
    /// Download and referrer URLs from Spotlight (`kMDItemWhereFroms`), empty when unknown.
    public var sources: [URL] = []
    public var folder: URL?
    public var pageCount = 1
    /// First page, in points (pixels for raster images).
    public var firstPageSize: CGSize?
    public var isScreenshot = false
    public var isRaster = false
    /// nil when detection wasn't run (no enabled rule looks at codes).
    public var codes: [Code]?
    /// Text of the first pages (PDF text, or recognised text in images); nil when not read.
    public var pageText: String?

    public init(trigger: RuleTrigger, fileName: String, kind: FileKind? = nil, sources: [URL] = [], folder: URL? = nil,
                pageCount: Int = 1, firstPageSize: CGSize? = nil, isScreenshot: Bool = false, isRaster: Bool = false,
                codes: [Code]? = nil, pageText: String? = nil) {
        self.trigger = trigger
        self.fileName = fileName
        self.kind = kind
        self.sources = sources
        self.folder = folder
        self.pageCount = pageCount
        self.firstPageSize = firstPageSize
        self.isScreenshot = isScreenshot
        self.isRaster = isRaster
        self.codes = codes
        self.pageText = pageText
    }

    /// Source hosts without "www.", for display and matching.
    public var sourceHosts: [String] {
        var seen = Set<String>()
        return sources.compactMap { $0.host.map(RuleContext.normalizedDomain) }.filter { seen.insert($0).inserted }
    }

    /// "https://www.Amazon.co.uk/returns" → "amazon.co.uk".
    public static func normalizedDomain(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = t.range(of: "://") { t = String(t[r.upperBound...]) }
        if let slash = t.firstIndex(where: { "/?#:".contains($0) }) { t = String(t[..<slash]) }
        if t.hasPrefix("www.") { t.removeFirst(4) }
        return t
    }
}

extension RuleContext {
    /// Reads the cheap facts from disk: name, type, source, folder, page count and size, screenshot flag.
    /// Pass `detectCodes` (see `RuleBook.needsCodes`) to also look for QR codes and barcodes on the first page.
    public static func inspect(_ url: URL, trigger: RuleTrigger, detectCodes: Bool = false, readText: Bool = false) -> RuleContext {
        var ctx = RuleContext(trigger: trigger, fileName: url.lastPathComponent, folder: url.deletingLastPathComponent())
        ctx.sources = FileFacts.whereFroms(url)
        ctx.isScreenshot = FileFacts.isScreenCapture(url)
        switch url.pathExtension.lowercased() {
        case "pdf": ctx.kind = .pdf
        case "svg": ctx.kind = .svg
        default:
            ctx.kind = ctx.isScreenshot ? .screenshot : .image
            ctx.isRaster = true
        }
        if ctx.kind != .svg {
            let page = FileFacts.firstPage(url)
            ctx.pageCount = page.count
            ctx.firstPageSize = page.size
        }
        if detectCodes { ctx.codes = FileFacts.codes(in: url).map { Code(symbology: $0.symbology, payload: $0.payload) } }
        if readText { ctx.pageText = FileFacts.text(in: url, raster: ctx.isRaster) }
        return ctx
    }
}
