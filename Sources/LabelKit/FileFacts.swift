import CoreGraphics
import CoreServices
import Foundation
import ImageIO
import PDFKit
import Vision

/// What can be read about a file on disk without composing it: where it came from, whether it's a
/// screenshot, its first page, its text and codes. The rules (PeelGoodCore's `RuleContext`) are built on this.
public enum FileFacts {
    public struct Page: Sendable {
        public var count = 1
        /// First page, in points (pixels for raster images).
        public var size: CGSize?
    }

    /// PDF page count and first-page size (rotation applied), or an image's pixel size.
    public static func firstPage(_ url: URL) -> Page {
        var page = Page()
        if url.pathExtension.lowercased() == "pdf" {
            if let doc = CGPDFDocument(url as CFURL), let first = doc.page(at: 1) {
                page.count = doc.numberOfPages
                let box = first.getBoxRect(.cropBox)
                page.size = (first.rotationAngle / 90) % 2 != 0 ? CGSize(width: box.height, height: box.width) : box.size
            }
        } else if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int {
            page.size = CGSize(width: w, height: h)
        }
        return page
    }

    /// PDF text from the first three pages, or Vision text recognition for images.
    public static func text(in url: URL, raster: Bool) -> String {
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

    /// Codes on the first page, rendered at about 150 dpi (long side capped at 2400 px), as (symbology, payload).
    public static func codes(in url: URL) -> [(symbology: String, payload: String)] {
        guard let page = try? DocumentLoader.load(url).first else { return [] }
        let scale = min(150.0 / 72, 2400 / max(page.size.width, page.size.height, 1))
        let scaleUp = page.isRaster ? 1 : scale
        let w = Int((page.size.width * scaleUp).rounded()), h = Int((page.size.height * scaleUp).rounded())
        guard w > 0, h > 0, w * h < 40_000_000 else { return [] }
        let bitmap = GrayBitmap.render(width: w, height: h) { ctx in
            ctx.scaleBy(x: scaleUp, y: scaleUp)
            page.draw(in: ctx)
        }
        return BarcodeReader.read(bitmap).map { ($0.symbology, $0.payload) }
    }

    /// Download and referrer URLs, from the xattr browsers write on download, falling back to Spotlight.
    public static func whereFroms(_ url: URL) -> [URL] {
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

    public static func isScreenCapture(_ url: URL) -> Bool {
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
