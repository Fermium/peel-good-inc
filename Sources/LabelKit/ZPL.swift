import Foundation
import zlib

/// ZPL II for Zebra printers: each label is one 1-bit graphic, exactly the composed dots, so nothing
/// on the way (no CUPS driver) rescales or re-dithers it.
///
/// Encoding follows the ZPL II Programming Guide (^GF, "Alternative Data Compression Scheme",
/// Z64); test vectors come from BinaryKits.Zpl (MIT).
public enum ZPL {
    public enum Compression: String, Sendable, CaseIterable {
        /// zlib, then Base64, with a CRC: the smallest. Firmware from the mid-2000s on.
        case z64
        /// Zebra's run-length hex ("ACS"): works on every ZPL II printer.
        case acs
        /// Plain hex, twice the bytes. For debugging.
        case hex
    }

    public enum Orientation: String, Sendable {
        /// Row 0 of the bitmap prints first, at the leading edge.
        case normal
        /// Turned 180° (^POI), as the CUPS driver sends it.
        case inverted
    }

    public struct Options: Sendable {
        public var compression: Compression = .z64
        public var orientation: Orientation = .normal
        /// Copies of the whole set of labels.
        public var copies = 1
        /// Uncompressed bytes per ^GF band. The guide caps ^GF counts at 99999; smaller bands keep
        /// each field well inside printer memory.
        public var bandBytes = 24_000
        /// Send ^LL. Only continuous media needs it: on gap or mark media the printer measures each
        /// label, and a longer ^LL than it measured feeds blank labels (LPrint issues #95, #196).
        public var labelLength = true

        public init(compression: Compression = .z64, orientation: Orientation = .normal, copies: Int = 1) {
            self.compression = compression
            self.orientation = orientation
            self.copies = copies
        }
    }

    /// One ^XA…^XZ format per label. A single label prints its copies with ^PQ; a set repeats in order.
    public static func job(_ labels: [GrayBitmap], options: Options = Options()) -> Data {
        let copies = max(1, options.copies)
        var out = ""
        if labels.count == 1 {
            out = format(labels[0], options: options, quantity: copies)
        } else {
            let formats = labels.map { format($0, options: options, quantity: 1) }
            for _ in 0..<copies { out += formats.joined() }
        }
        return Data(out.utf8)
    }

    /// One label, laid out as Zebra's own driver does (^PW the label's width, the image at 0,0), so the
    /// printer's calibration (LEFT POSITION ^LS, LABEL TOP ^LT) places it as it does for every other app.
    /// Where the roll sits on the head differs by model and by how it's loaded; that's calibrated, never
    /// assumed. ^PO, ^LH and ^PW are stated because they persist from whatever printed before; darkness,
    /// speed, media and print mode stay as the printer is set up.
    public static func format(_ bitmap: GrayBitmap, options: Options = Options(), quantity: Int = 1) -> String {
        let rows = bitmap.packedBlack()
        var s = "^XA\n^PO\(options.orientation == .inverted ? "I" : "N")\n^LH0,0\n^PW\(bitmap.width)\n"
        if options.labelLength { s += "^LL\(bitmap.height)\n" }
        let perBand = max(1, options.bandBytes / max(1, rows.rowBytes))
        var y = 0
        while y < bitmap.height {
            let count = min(perBand, bitmap.height - y)
            let band = Array(rows.bytes[(y * rows.rowBytes)..<((y + count) * rows.rowBytes)])
            let total = band.count
            s += "^FO0,\(y)^GFA,\(total),\(total),\(rows.rowBytes),\(graphicData(band, rowBytes: rows.rowBytes, compression: options.compression))^FS\n"
            y += count
        }
        if quantity > 1 { s += "^PQ\(quantity)\n" }
        return s + "^XZ\n"
    }

    // MARK: Graphic data

    public static func graphicData(_ bytes: [UInt8], rowBytes: Int, compression: Compression) -> String {
        switch compression {
        case .z64: z64(bytes)
        case .acs: acs(bytes, rowBytes: rowBytes)
        case .hex: hex(bytes[...])
        }
    }

    /// `:Z64:` Base64 of the zlib stream, then `:` and the CRC-16 of the Base64 text.
    public static func z64(_ bytes: [UInt8]) -> String {
        var size = compressBound(uLong(bytes.count))
        var out = [UInt8](repeating: 0, count: Int(size))
        let status = compress2(&out, &size, bytes, uLong(bytes.count), Z_BEST_COMPRESSION)
        precondition(status == Z_OK, "zlib compress2 failed: \(status)")
        let text = Data(out[0..<Int(size)]).base64EncodedString()
        return ":Z64:\(text):\(String(format: "%04X", crc16(Array(text.utf8))))"
    }

    /// CRC-16/XMODEM (polynomial 0x1021, initial 0, no reflection), as Z64 and B64 use.
    public static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }

    static func hex(_ bytes: ArraySlice<UInt8>) -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Zebra's compressed hex, row by row: `:` repeats the row above, `,` fills the rest of the row
    /// with white, and a run of a hex digit is a count (G–Y = 1–19, g–z = 20–400, summed) before it.
    /// Never `!` (fill with black): renderers disagree on it, and black runs encode almost as short.
    public static func acs(_ bytes: [UInt8], rowBytes: Int) -> String {
        var out = ""
        var previous: ArraySlice<UInt8>?
        var start = 0
        while start < bytes.count {
            let row = bytes[start..<min(start + rowBytes, bytes.count)]
            defer { previous = row; start += rowBytes }
            if let previous, previous.elementsEqual(row) {
                out += ":"
                continue
            }
            var digits = Array(hex(row).utf8)
            var filled = false
            if let last = digits.lastIndex(where: { $0 != UInt8(ascii: "0") }) {
                // Keep an even number of digits before the comma, as the guide asks. A row that is
                // full again must not get one: a comma at a row boundary is a whole blank row.
                let kept = (last + 1) % 2 == 1 ? last + 2 : last + 1
                if kept < digits.count {
                    digits = Array(digits[..<kept])
                    filled = true
                }
            } else {
                digits = []
                filled = true
            }
            out += runLength(digits)
            if filled { out += "," }
        }
        return out
    }

    private static func runLength(_ digits: [UInt8]) -> String {
        var out = ""
        var i = 0
        while i < digits.count {
            var j = i
            while j < digits.count && digits[j] == digits[i] { j += 1 }
            var n = j - i
            let digit = Character(UnicodeScalar(digits[i]))
            while n > 0 {
                let chunk = min(n, 419)
                if chunk < 3 {
                    out += String(repeating: digit, count: chunk)
                } else {
                    out += count(chunk) + String(digit)
                }
                n -= chunk
            }
            i = j
        }
        return out
    }

    /// 1–419 as repeat letters: g–z for the twenties (20–400), then G–Y for 1–19.
    static func count(_ n: Int) -> String {
        var s = ""
        if n >= 20 { s += String(UnicodeScalar(UInt8(ascii: "f") + UInt8(n / 20))) }
        if n % 20 > 0 { s += String(UnicodeScalar(UInt8(ascii: "F") + UInt8(n % 20))) }
        return s
    }
}
