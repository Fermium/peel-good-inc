import CoreGraphics
import Foundation

/// An 8-bit grayscale bitmap. Row 0 is the top of the image; 0 is black, 255 is white.
public struct GrayBitmap {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// Renders onto a white background. The context uses PDF coordinates (origin bottom-left).
    /// Drawing happens in RGB (some sources, like SVG, draw incompletely into gray contexts),
    /// then converts to luminance.
    public static func render(width: Int, height: Int, _ draw: (CGContext) -> Void) -> GrayBitmap {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        rgba.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return }
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            draw(ctx)
        }
        var pixels = [UInt8](repeating: 255, count: width * height)
        for i in pixels.indices {
            let r = UInt32(rgba[i * 4]), g = UInt32(rgba[i * 4 + 1]), b = UInt32(rgba[i * 4 + 2])
            pixels[i] = UInt8((r * 299 + g * 587 + b * 114) / 1000)
        }
        return GrayBitmap(width: width, height: height, pixels: pixels)
    }

    /// An 8-bit image, for previews.
    public func cgImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// Rows of 1-bit dots, 1 = black (pixels below 128), leftmost dot in the high bit, each row padded
    /// to whole bytes with white: what printers take (ZPL ^GF) and what `oneBitImage` draws.
    public func packedBlack() -> (rowBytes: Int, bytes: [UInt8]) {
        let rowBytes = (width + 7) / 8
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where pixels[row + x] < 128 {
                bytes[y * rowBytes + x / 8] |= 0x80 >> UInt8(x % 8)
            }
        }
        return (rowBytes, bytes)
    }

    /// A packed 1-bit image, for printing.
    public func oneBitImage() -> CGImage? {
        let packed = packedBlack()
        guard let provider = CGDataProvider(data: Data(packed.bytes) as CFData) else { return nil }
        // Set bits are black: decode inverts DeviceGray's 0 = black.
        return CGImage(
            width: width, height: height, bitsPerComponent: 1, bitsPerPixel: 1, bytesPerRow: packed.rowBytes,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider,
            decode: [1, 0], shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
