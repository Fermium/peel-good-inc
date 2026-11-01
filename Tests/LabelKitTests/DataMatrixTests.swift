import CoreGraphics
import Testing
@testable import LabelKit

/// Draws a module grid with a quiet zone, the way a printer would, for Vision to read back.
private func image(_ grid: [[Bool]], module: Int = 8, quiet: Int = 4) -> CGImage? {
    let n = grid.count, side = (n + 2 * quiet) * module
    var b = GrayBitmap(width: side, height: side, pixels: [UInt8](repeating: 255, count: side * side))
    for (r, row) in grid.enumerated() {
        for (c, dark) in row.enumerated() where dark {
            for y in 0..<module { for x in 0..<module { b[(c + quiet) * module + x, (r + quiet) * module + y] = 0 } }
        }
    }
    return b.cgImage()
}

@Test(arguments: ["A", "PEELGOOD", "PEELGOOD 4x6", "https://peelgood.example/1234", "Order 1234567890 shipped 2026-10-31"])
func dataMatrixReadsBack(_ text: String) throws {
    let grid = try #require(DataMatrix.encode(text))
    #expect(grid.count == grid[0].count && grid.count % 2 == 0)
    let found = BarcodeReader.read(try #require(image(grid)))
    #expect(found.contains { $0.payload == text && $0.symbology.lowercased().contains("datamatrix") }, "Vision reads \(text) (\(grid.count)×\(grid.count))")
}

@Test func dataMatrixEncodation() {
    // Digit pairs pack into one codeword; letters are their code + 1.
    #expect(DataMatrix.asciiCodewords("123") == [142, 52])
    #expect(DataMatrix.asciiCodewords("A") == [66])
    #expect(DataMatrix.asciiCodewords("é") == nil)
    // ISO/IEC 16022 example: "123456" fits a 10×10 with codewords 142 164 186 and ECC 114 25 5 88 102.
    let data = DataMatrix.padded(DataMatrix.asciiCodewords("123456")!, to: 3)
    #expect(data == [142, 164, 186])
    #expect(DataMatrix.errorCorrection(data, count: 5) == [114, 25, 5, 88, 102])
    #expect(DataMatrix.encode(String(repeating: "x", count: 45)) == nil, "larger than 26×26 isn't supported")
}
