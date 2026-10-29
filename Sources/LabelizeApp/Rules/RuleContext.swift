import Vision
import PDFKit
import CoreGraphics
import CoreServices
import Foundation
import ImageIO
import LabelKit

/// What rules can know about one incoming file.
struct RuleContext: Sendable {
    struct Code: Sendable, Hashable {
        var symbology: String
        var payload: String
    }

    var trigger: RuleTrigger
    var fileName: String
    var kind: FileKind?
    /// Download and referrer URLs from Spotlight (`kMDItemWhereFroms`), empty when unknown.
    var sources: [URL] = []
    var folder: URL?
    var pageCount = 1
    /// First page, in points (pixels for raster images).
    var firstPageSize: CGSize?
    var isScreenshot = false
    var isRaster = false
    /// nil when detection wasn't run (no enabled rule looks at codes).
    var codes: [Code]?
    /// Text of the first pages (PDF text, or recognised text in images); nil when not read.
    var pageText: String?

    /// Source hosts without "www.", for display and matching.
    var sourceHosts: [String] {
        var seen = Set<String>()
        return sources.compactMap { $0.host.map(RuleContext.normalizedDomain) }.filter { seen.insert($0).inserted }
    }

    /// "https://www.Amazon.co.uk/returns" → "amazon.co.uk".
    static func normalizedDomain(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = t.range(of: "://") { t = String(t[r.upperBound...]) }
        if let slash = t.firstIndex(where: { "/?#:".contains($0) }) { t = String(t[..<slash]) }
        if t.hasPrefix("www.") { t.removeFirst(4) }
        return t
    }
}

extension RuleContext {
    /// Reads the cheap facts from disk: name, type, source, folder, page count and size, screenshot flag.
    /// Pass `detectCodes` (see `RuleEngine.needsCodes`) to also look for QR codes and barcodes on the first page.
    static func inspect(_ url: URL, trigger: RuleTrigger, detectCodes: Bool = false, readText: Bool = false) -> RuleContext {
        let ext = url.pathExtension.lowercased()
        var ctx = RuleContext(trigger: trigger, fileName: url.lastPathComponent, folder: url.deletingLastPathComponent())
        ctx.sources = whereFroms(url)
        ctx.isScreenshot = isScreenCapture(url)

        switch ext {
        case "pdf":
            ctx.kind = .pdf
            if let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: 1) {
                ctx.pageCount = doc.numberOfPages
                let box = page.getBoxRect(.cropBox)
                ctx.firstPageSize = (page.rotationAngle / 90) % 2 != 0 ? CGSize(width: box.height, height: box.width) : box.size
            }
        case "svg":
            ctx.kind = .svg
        default:
            ctx.kind = ctx.isScreenshot ? .screenshot : .image
            ctx.isRaster = true
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int {
                ctx.firstPageSize = CGSize(width: w, height: h)
            }
        }
        if detectCodes { ctx.codes = Self.codes(in: url) }
        if readText { ctx.pageText = Self.text(in: url, raster: ctx.isRaster) }
        return ctx
    }

    /// Codes on the first page, rendered at about 150 dpi (long side capped at 2400 px).
    /// PDF text from the first three pages, or Vision text recognition for images.
    static func text(in url: URL, raster: Bool) -> String {
        if url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFDocument(url: url) else { return "" }
            return (0..<min(3, doc.pageCount)).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
        }
        guard raster, let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func codes(in url: URL) -> [Code] {
        guard let page = try? DocumentLoader.load(url).first else { return [] }
        let scale = min(150.0 / 72, 2400 / max(page.size.width, page.size.height, 1))
        let scaleUp = page.isRaster ? 1 : scale
        let w = Int((page.size.width * scaleUp).rounded()), h = Int((page.size.height * scaleUp).rounded())
        guard w > 0, h > 0, w * h < 40_000_000 else { return [] }
        let bitmap = GrayBitmap.render(width: w, height: h) { ctx in
            ctx.scaleBy(x: scaleUp, y: scaleUp)
            page.draw(in: ctx)
        }
        return BarcodeReader.read(bitmap).map { Code(symbology: $0.symbology, payload: $0.payload) }
    }

    /// From the xattr browsers write on download, falling back to Spotlight.
    private static func whereFroms(_ url: URL) -> [URL] {
        var strings: [String] = []
        if let data = xattr(url, "com.apple.metadata:kMDItemWhereFroms"),
           let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] {
            strings = list
        } else if let item = MDItemCreateWithURL(nil, url as CFURL),
                  let list = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String] {
            strings = list
        }
        return strings.compactMap(URL.init(string:)).filter { $0.host != nil }
    }

    private static func isScreenCapture(_ url: URL) -> Bool {
        if let data = xattr(url, "com.apple.metadata:kMDItemIsScreenCapture"),
           let flag = try? PropertyListSerialization.propertyList(from: data, format: nil) as? Bool {
            return flag
        }
        if let item = MDItemCreateWithURL(nil, url as CFURL),
           let flag = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? Bool {
            return flag
        }
        let name = url.lastPathComponent
        return ["png", "jpg", "jpeg", "heic"].contains(url.pathExtension.lowercased())
            && (name.hasPrefix("Screenshot") || name.hasPrefix("Screen Shot"))
    }

    private static func xattr(_ url: URL, _ name: String) -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, 0) }
        return read == size ? data : nil
    }
}
