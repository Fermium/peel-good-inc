import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Descriptors are immutable once Vision hands them over, so sharing them across threads is safe.
public struct Barcode: @unchecked Sendable {
    public var payload: String
    public var symbology: String
    /// Location in the coordinates of the image it was found in (origin bottom-left, in pixels).
    public var rect: CGRect
    /// The symbol's raw codewords and version (2D codes only), enough to regenerate it exactly.
    public var descriptor: CIBarcodeDescriptor?

    public init(payload: String, symbology: String, rect: CGRect, descriptor: CIBarcodeDescriptor? = nil) {
        self.payload = payload
        self.symbology = symbology
        self.rect = rect
        self.descriptor = descriptor
    }

    static let linear: Set<String> = ["Code128", "Code39", "Code39Checksum", "Code39FullASCII", "Code39FullASCIIChecksum",
                                      "Code93", "Code93i", "EAN13", "EAN8", "UPCE", "ITF14", "I2of5", "I2of5Checksum",
                                      "Codabar", "GS1DataBar", "GS1DataBarExpanded", "GS1DataBarLimited", "MSIPlessey"]
    /// Symbologies whose bars and spaces are all whole modules (unlike Code39 or ITF, with 2–3× wide bars).
    static let wholeModules: Set<String> = ["Code128", "Code93", "Code93i", "EAN13", "EAN8", "UPCE",
                                            "GS1DataBar", "GS1DataBarExpanded", "GS1DataBarLimited"]

    /// Bars rather than a 2D grid of modules.
    public var isLinear: Bool { Self.linear.contains(symbology) }
}

public enum BarcodeReader {
    /// Finds QR codes and barcodes. Payloads are de-duplicated (Vision can report a code twice).
    public static func read(_ image: CGImage) -> [Barcode] {
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let results = request.results else { return [] }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        var seen = Set<String>()
        return results.compactMap { o in
            guard let payload = o.payloadStringValue, seen.insert(payload).inserted else { return nil }
            let b = o.boundingBox
            return Barcode(payload: payload, symbology: o.symbology.rawValue.replacingOccurrences(of: "VNBarcodeSymbology", with: ""),
                           rect: CGRect(x: b.minX * w, y: b.minY * h, width: b.width * w, height: b.height * h),
                           descriptor: o.barcodeDescriptor)
        }
    }

    public static func read(_ bitmap: GrayBitmap) -> [Barcode] {
        bitmap.cgImage().map(read) ?? []
    }
}
