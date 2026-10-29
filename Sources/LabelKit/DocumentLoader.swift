import AppKit
import CoreGraphics
import Foundation

/// One page of input, drawable into a context whose origin is the page's bottom-left corner.
public struct SourcePage {
    public let size: CGSize
    /// True for photos and screenshots, whose point size says nothing about physical size.
    public let isRaster: Bool
    private let render: (CGContext) -> Void

    public init(size: CGSize, isRaster: Bool = false, render: @escaping (CGContext) -> Void) {
        self.size = size
        self.isRaster = isRaster
        self.render = render
    }

    public var bounds: CGRect { CGRect(origin: .zero, size: size) }

    public func draw(in ctx: CGContext) {
        ctx.saveGState()
        render(ctx)
        ctx.restoreGState()
    }
}

public enum DocumentLoader {
    public enum LoadError: Error, CustomStringConvertible {
        case unreadable(URL)
        case empty(URL)

        public var description: String {
            switch self {
            case .unreadable(let url): "can't read \(url.lastPathComponent) as a PDF, SVG or image"
            case .empty(let url): "\(url.lastPathComponent) has no pages"
            }
        }
    }

    public static func load(_ url: URL) throws -> [SourcePage] {
        if url.pathExtension.lowercased() == "pdf" {
            return try loadPDF(url)
        }
        return [try loadImage(url)]
    }

    private static func loadPDF(_ url: URL) throws -> [SourcePage] {
        guard let doc = CGPDFDocument(url as CFURL) else { throw LoadError.unreadable(url) }
        guard doc.numberOfPages > 0 else { throw LoadError.empty(url) }
        return (1...doc.numberOfPages).compactMap { doc.page(at: $0) }.map { page in
            let box = page.getBoxRect(.cropBox)
            let quarterTurn = (page.rotationAngle / 90) % 2 != 0
            let size = quarterTurn ? CGSize(width: box.height, height: box.width) : box.size
            return SourcePage(size: size) { ctx in
                let target = CGRect(origin: .zero, size: size)
                ctx.concatenate(page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
                ctx.clip(to: box)
                ctx.drawPDFPage(page)
            }
        }
    }

    /// SVG and raster images go through NSImage, which keeps SVG as vectors.
    private static func loadImage(_ url: URL) throws -> SourcePage {
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
            throw LoadError.unreadable(url)
        }
        let size = image.size
        let isRaster = !image.representations.contains { String(describing: type(of: $0)).contains("SVG") }
        return SourcePage(size: size, isRaster: isRaster) { ctx in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            image.draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
