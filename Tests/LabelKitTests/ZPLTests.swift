import Foundation
import Testing
import zlib
@testable import LabelKit

// Vectors from BinaryKits.Zpl (MIT): ZebraZ64CompressionHelperTest, ZebraB64CompressionHelperTest.
private let binaryKitsHex = "FFFFFFFFFFFFFFFFFFFF8000FFFF0000FFFF00018000FFFF0000FFFF00018000FFFF0000FFFF0001FFFF0000FFFF0000FFFFFFFF0000FFFF0000FFFFFFFF0000FFFF0000FFFFFFFFFFFFFFFFFFFFFFFF"

private func bytes(hex: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = hex.startIndex
    while i < hex.endIndex {
        let j = hex.index(i, offsetBy: 2)
        out.append(UInt8(hex[i..<j], radix: 16)!)
        i = j
    }
    return out
}

// MARK: A decoder for what we emit, so the tests check dots rather than strings.

private func decodeACS(_ text: String, rowBytes: Int, rows: Int) -> [UInt8] {
    var out: [UInt8] = []
    var row = ""
    var previous = ""
    var count = 0
    func finishRow() {
        let padded = row.padding(toLength: rowBytes * 2, withPad: "0", startingAt: 0)
        out += bytes(hex: padded)
        previous = padded
        row = ""
    }
    for ch in text {
        switch ch {
        case "G"..."Y": count += Int(ch.asciiValue! - Character("F").asciiValue!)
        case "g"..."z": count += 20 * Int(ch.asciiValue! - Character("f").asciiValue!)
        case ",": finishRow()
        case ":":
            row = previous
            finishRow()
        default:
            row += String(repeating: ch, count: max(1, count))
            count = 0
            if row.count == rowBytes * 2 { finishRow() }
        }
    }
    #expect(row.isEmpty)
    return out
}

private func decodeZ64(_ text: String) -> [UInt8]? {
    let parts = text.split(separator: ":")
    guard parts.count == 3, parts[0] == "Z64", let data = Data(base64Encoded: String(parts[1])) else { return nil }
    #expect(String(format: "%04X", ZPL.crc16(Array(parts[1].utf8))) == parts[2])
    var size = uLong(1 << 22)
    var out = [UInt8](repeating: 0, count: Int(size))
    let input = [UInt8](data)
    guard uncompress(&out, &size, input, uLong(input.count)) == Z_OK else { return nil }
    return Array(out[0..<Int(size)])
}

/// Every ^GF band of a format, decoded back into packed rows.
private func decodeFormat(_ zpl: String) -> (width: Int, height: Int, bytes: [UInt8]) {
    func number(after tag: String) -> Int { Int(zpl.components(separatedBy: tag)[1].prefix { $0.isNumber })! }
    let width = number(after: "^PW"), height = number(after: "^LL")
    var all: [UInt8] = []
    for field in zpl.components(separatedBy: "^GFA,").dropFirst() {
        let body = field.components(separatedBy: "^FS")[0]
        let parts = body.split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        let total = Int(parts[1])!, rowBytes = Int(parts[2])!
        let data = parts[3]
        let band: [UInt8] = data.hasPrefix(":Z64:") ? decodeZ64(data)! : decodeACS(data, rowBytes: rowBytes, rows: total / rowBytes)
        #expect(band.count == total)
        all += band
    }
    return (width, height, all)
}

/// Gray dots with the cases the run-length code cares about: blank, repeated and solid rows,
/// runs longer than 419 digits, and rows ending in an odd number of white digits.
private func sampleBitmap(width: Int = 1700, height: Int = 40) -> GrayBitmap {
    var b = GrayBitmap(width: width, height: height, pixels: [UInt8](repeating: 255, count: width * height))
    for y in 0..<height {
        for x in 0..<width {
            let black: Bool = switch y {
            case 0, 1: false
            case 2...4: x < 7 || (x > 30 && x < 1650)
            case 5: true
            case 6..<20: (x / (y - 3) + y) % 3 == 0 && x < width - 13
            default: (x * 7 + y * 13) % 11 < 4
            }
            if black { b[x, y] = 0 }
        }
    }
    return b
}

@Test func crcIsXmodem() {
    #expect(ZPL.crc16(Array("123456789".utf8)) == 0x31C3)
    #expect(ZPL.crc16(Array("eNr7/x8GGhj+/2cAYUZsLCjNAFKJjQUDAOLDM1I=".utf8)) == 0x8F39)
    let b64 = Data(bytes(hex: binaryKitsHex)).base64EncodedString()
    #expect(ZPL.crc16(Array(b64.utf8)) == 0xE4B3)
}

@Test func z64RoundTrips() {
    let raw = bytes(hex: binaryKitsHex)
    let z = ZPL.z64(raw)
    #expect(z.hasPrefix(":Z64:eN"))
    #expect(decodeZ64(z) == raw)
}

@Test func repeatCounts() {
    #expect(ZPL.count(1) == "G")
    #expect(ZPL.count(19) == "Y")
    #expect(ZPL.count(20) == "g")
    #expect(ZPL.count(327) == "vM")
    #expect(ZPL.count(400) == "z")
    #expect(ZPL.count(419) == "zY")
}

@Test func acsUsesCommasColonsAndCounts() {
    // Rows of 4 bytes: solid, the same again, white, half white, ending in one odd zero digit.
    let rows = bytes(hex: "FFFFFFFF" + "FFFFFFFF" + "00000000" + "FF000000" + "F0F0F0F0")
    #expect(ZPL.acs(rows, rowBytes: 4) == "NF:,FF,F0F0F0F0")
    #expect(!ZPL.acs(rows, rowBytes: 4).contains("!"))
    #expect(decodeACS(ZPL.acs(rows, rowBytes: 4), rowBytes: 4, rows: 5) == rows)
    // An odd count of digits before the white fill keeps one zero: "F0F" → "F0F0,".
    #expect(ZPL.acs(bytes(hex: "F0F000"), rowBytes: 3) == "F0F0,")
    // One trailing zero digit: the row stays whole, with no comma (which would add a blank row).
    #expect(ZPL.acs(bytes(hex: "FFF0" + "FFFF"), rowBytes: 2) == "IF0JF")
}

@Test(arguments: ZPL.Compression.allCases)
func formatsRoundTripEveryDot(_ compression: ZPL.Compression) {
    let b = sampleBitmap()
    var options = ZPL.Options(compression: compression)
    options.bandBytes = 2000
    let zpl = ZPL.format(b, options: options)
    #expect(zpl.hasPrefix("^XA\n^PON\n^LH0,0\n^PW1700\n^LL40\n"))
    // 2000 bytes hold 9 rows of 213 bytes: 40 rows make 5 bands.
    #expect(zpl.components(separatedBy: "^GFA,").count - 1 == 5)
    if compression == .hex {
        #expect(zpl.contains(ZPL.hex(b.packedBlack().bytes[0..<213])))
        return
    }
    let decoded = decodeFormat(zpl)
    #expect(decoded.width == b.width && decoded.height == b.height)
    #expect(decoded.bytes == b.packedBlack().bytes)
}

@Test func placesLikeZebrasDriver() {
    // ^PW is the label, the image sits at 0,0 and ^LS/^LT are never sent: the printer's calibration applies.
    let zpl = ZPL.format(GrayBitmap(width: 813, height: 4, pixels: [UInt8](repeating: 0, count: 813 * 4)))
    #expect(zpl.contains("^PW813\n") && zpl.contains("^FO0,0^GFA,"))
    #expect(!zpl.contains("^LS") && !zpl.contains("^LT"))
}

@Test func jobCopies() {
    let one = GrayBitmap(width: 16, height: 2, pixels: [UInt8](repeating: 0, count: 32))
    let single = String(decoding: ZPL.job([one], options: ZPL.Options(copies: 3)), as: UTF8.self)
    #expect(single.contains("^PQ3\n") && single.components(separatedBy: "^XA").count == 2)
    let set = String(decoding: ZPL.job([one, one], options: ZPL.Options(copies: 3)), as: UTF8.self)
    #expect(!set.contains("^PQ") && set.components(separatedBy: "^XA").count == 7)
}

@Test func labelPDFComesBackDotForDot() throws {
    var o = LabelOptions()
    o.dpi = 8 * 25.4
    for size in [LabelSize.fourBySix, LabelSize(width: 2.25, height: 1.25)] {
        o.size = size
        let label = LabelComposer.compose(letterPage(), o)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zpl-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try LabelWriter.writePDF([label], size: o.size, to: url)
        let back = try LabelRaster.bitmaps(pdf: url, dpi: o.dpi)
        #expect(back.count == 1)
        #expect(back[0].width == label.bitmap.width && back[0].height == label.bitmap.height)
        #expect(back[0].packedBlack().bytes == label.bitmap.packedBlack().bytes)
    }
}

// MARK: Replies from a GX420t (firmware V56.17.17Z)

@Test func readsIdentity() throws {
    let id = try #require(Zebra.Identity(reply: "\u{02}GX420t-200dpi,V56.17.17Z,8,2104KB\u{03}\r\n"))
    #expect(id.model == "GX420t-200dpi" && id.product == "GX420t" && id.firmware == "V56.17.17Z")
    #expect(id.dotsPerMM == 8 && id.memoryKB == 2104 && abs(id.dpi - 203.2) < 1e-9)
    #expect(Zebra.Identity(reply: "hello") == nil)
}

@Test func readsStatus() throws {
    let idle = "\u{02}030,0,0,1214,000,0,0,0,000,0,0,0\u{03}\r\n\u{02}001,0,0,0,1,2,6,0,00000000,1,000\u{03}\r\n\u{02}1234,0\u{03}\r\n"
    let s = try #require(Zebra.Status(reply: idle))
    #expect(s.problems.isEmpty && s.isIdle)
    let busy = "\u{02}030,1,1,1214,002,0,0,0,000,0,0,0\u{03}\r\n\u{02}001,0,1,0,1,2,6,0,00000005,1,000\u{03}\r\n\u{02}1234,0\u{03}\r\n"
    let b = try #require(Zebra.Status(reply: busy))
    #expect(b.paperOut && b.paused && b.headOpen && !b.ribbonOut)
    #expect(b.formatsInBuffer == 2 && b.labelsRemaining == 5 && !b.isIdle)
    #expect(b.problems == ["the print head is open", "it's out of labels", "it's paused"])
}

@Test func readsSetup() {
    let text = """
      10.0                DARKNESS
      TEAR OFF            PRINT MODE
      GAP/NOTCH           MEDIA TYPE
      THERMAL-TRANS.      PRINT METHOD
      813                 PRINT WIDTH
      1214                LABEL LENGTH
      39.0IN   989MM      MAXIMUM LENGTH
      832 8/MM FULL       RESOLUTION
    """
    let s = Zebra.Setup(reply: text)
    #expect(s.printWidth == 813 && s.labelLength == 1214 && s.headWidth == 832 && s.maximumLength == 39)
    #expect(s.printMode == "TEAR OFF" && s.mediaType == "GAP/NOTCH" && s.darkness == "10.0")
}

@Test func readsDiscoveryReply() throws {
    var reply = [UInt8](repeating: 0, count: 375)
    reply[0...3] = [0x3A, 0x2C, 0x2E, 0x03]
    func put(_ s: String, _ at: Int) { for (i, b) in s.utf8.enumerated() { reply[at + i] = b } }
    put("ZebraNet Wired PS", 12)
    put("V56.17.17ZZBR", 39)
    put("123456", 62)
    put("ZBR11123456", 84)
    let f = try #require(Zebra.Found(reply: reply, from: "192.168.1.216"))
    #expect(f.server == "ZebraNet Wired PS" && f.serial == "123456" && f.systemName == "ZBR11123456")
    #expect(Zebra.Found(reply: [0, 1, 2], from: "x") == nil)
}

@Test func zebraNames() {
    #expect(Printers.zebraHost("zebra://192.168.1.216") == "192.168.1.216")
    #expect(Printers.zebraHost("ZEBRA://printer.local/") == "printer.local")
    #expect(Printers.zebraHost("zebra://") == nil)
    #expect(Printers.zebraHost("Label_Printer") == nil)
    let profile = Zebra.Profile(serial: "99J000000001", host: "h", product: "GX420t", dotsPerMM: 8, headDots: 832, maximumLength: 39)
    let z = profile.printer()
    #expect(z.name == "Zebra_99J000000001" && z.displayName == "Zebra GX420t")
    #expect(z.isLabelPrinter && z.zebraHost == "h" && z.dpi == 203.2 && z.state == .unknown)
    #expect(abs(z.customMax!.width - 832 / 203.2) < 1e-9 && z.resolve(LabelSize(width: 2.25, height: 1.25)) != nil)
    #expect(!PrinterInfo(name: "zebra://wide", presets: [], customMin: LabelSize(width: 1, height: 1),
                         customMax: LabelSize(width: 2, height: 3), zebraHost: "wide").isLabelPrinter)
}

// MARK: Printer settings (a GX420t's ^HH wording)

@Test func readsPrinterSettings() {
    let text = """
      10.0                DARKNESS
      6 IPS               PRINT SPEED
      +000                TEAR OFF
      TEAR OFF            PRINT MODE
      GAP/NOTCH           MEDIA TYPE
      THERMAL-TRANS.      PRINT METHOD
    """
    let c = Zebra.Config(Zebra.Setup(reply: text))
    #expect(c == Zebra.Config(darkness: 10, speed: 6, method: .thermalTransfer, tracking: .gap, mode: .tearOff, tearOff: 0))
    let withSpeeds = Zebra.Config(Zebra.Setup(reply: text), diagnostic: ["Slew Speed": "6", "Backfeed Speed": "2"])
    #expect(withSpeeds.slew == 6 && withSpeeds.backfeed == 2)
    let other = Zebra.Config(Zebra.Setup(reply: "  -012   TEAR OFF\n  PEEL OFF   PRINT MODE\n  MARK   MEDIA TYPE\n  DIRECT-THERMAL   PRINT METHOD\n"))
    #expect(other.tearOff == -12 && other.mode == .peelOff && other.tracking == .mark && other.method == .directThermal)
    let nonContinuous = Zebra.Setup(reply: "  NON-CONTINUOUS   MEDIA TYPE\n")
    #expect(Zebra.Config(nonContinuous).tracking == .gap && !nonContinuous.isContinuous)
    #expect(Zebra.Setup(reply: "  CONTINUOUS   MEDIA TYPE\n").isContinuous)
}

@Test func printerSettingCommands() {
    var now = Zebra.Config(darkness: 10, speed: 6, method: .thermalTransfer, tracking: .gap, mode: .tearOff, tearOff: 0)
    #expect(now.commands(from: now, save: false).isEmpty, "nothing changed, nothing sent")
    var faster = now
    faster.speed = 3
    #expect(faster.commands(from: now, save: false) == "^XA^PR3^XZ", "slew and backfeed unknown: print speed only")
    now.slew = 6
    now.backfeed = 2
    #expect(faster.commands(from: now, save: false) == "^XA^PR3,6,2^XZ", "slew and backfeed kept, not reset to ^PR's defaults")
    var want = now
    want.darkness = 5
    want.tearOff = -10
    want.speed = 4
    want.tracking = .gap
    #expect(want.commands(from: now, save: false) == "~SD05~TA-010^XA^PR4,6,2^XZ")
    #expect(want.commands(from: now, save: true) == "~SD05~TA-010^XA^PR4,6,2^JUS^XZ")
    #expect(want.changes(from: now) == ["Darkness: 10 → 5", "Print speed: 6 in/s → 4 in/s", "Tear-off position: +0 dots → -10 dots"])

    var media = now
    media.tracking = .continuous
    media.method = .directThermal
    media.mode = .cutter
    #expect(media.commands(from: now, save: false) == "^XA^MTD^MNN^MMC^XZ")
    media.tracking = .gap
    #expect(media.commands(from: Zebra.Config(), save: false).contains("^MNY"), "gaps are ^MNY, never ^MNM")

    var wild = now
    wild.darkness = 99
    wild.tearOff = 500
    #expect(wild.commands(from: now, save: false) == "~SD30~TA120", "clamped to what ZPL accepts")
}
