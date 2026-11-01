import Foundation

/// A Data Matrix (ECC 200) encoder for short ASCII messages: square symbols from 10×10 to 26×26
/// modules (one data region, one Reed–Solomon block), enough for test labels. Core Image draws QR,
/// Aztec, PDF417 and Code 128 but not Data Matrix. Follows ISO/IEC 16022: ASCII encodation (§5.2.3),
/// pad codewords (§5.2.3), Reed–Solomon over GF(256) with polynomial 301 (§5.7) and the module
/// placement of Annex F.
public enum DataMatrix {
    /// Symbol size, data codewords and error-correction codewords (ISO/IEC 16022 Table 7).
    static let sizes: [(size: Int, data: Int, ecc: Int)] = [
        (10, 3, 5), (12, 5, 7), (14, 8, 10), (16, 12, 12), (18, 18, 14),
        (20, 22, 18), (22, 30, 20), (24, 36, 24), (26, 44, 28),
    ]

    /// The symbol's modules, row 0 at the top, true = dark. Nil when the text isn't ASCII or doesn't fit.
    public static func encode(_ text: String) -> [[Bool]]? {
        guard let data = asciiCodewords(text), let spec = sizes.first(where: { $0.data >= data.count }) else { return nil }
        let codewords = padded(data, to: spec.data)
        let all = codewords + errorCorrection(codewords, count: spec.ecc)
        return symbol(placing: all, size: spec.size)
    }

    // MARK: Encodation

    /// Two digits make one codeword (130 + value), any other ASCII character is its code + 1.
    static func asciiCodewords(_ text: String) -> [Int]? {
        let bytes = Array(text.utf8)
        guard bytes.allSatisfy({ $0 < 128 }) else { return nil }
        var out: [Int] = []
        var i = 0
        while i < bytes.count {
            let isDigit = { (b: UInt8) in b >= 48 && b <= 57 }
            if i + 1 < bytes.count, isDigit(bytes[i]), isDigit(bytes[i + 1]) {
                out.append(130 + Int(bytes[i] - 48) * 10 + Int(bytes[i + 1] - 48))
                i += 2
            } else {
                out.append(Int(bytes[i]) + 1)
                i += 1
            }
        }
        return out
    }

    /// The first pad is 129; later ones are scrambled with the 253-state algorithm.
    static func padded(_ data: [Int], to count: Int) -> [Int] {
        var out = data
        if out.count < count { out.append(129) }
        while out.count < count {
            let position = out.count + 1
            var v = 129 + (149 * position) % 253 + 1
            if v > 254 { v -= 254 }
            out.append(v)
        }
        return out
    }

    // MARK: Reed–Solomon

    private static let (exp, log): ([Int], [Int]) = {
        var exp = [Int](repeating: 0, count: 512), log = [Int](repeating: 0, count: 256)
        var x = 1
        for i in 0..<255 {
            exp[i] = x
            log[x] = i
            x <<= 1
            if x & 0x100 != 0 { x ^= 0x12D }
        }
        for i in 255..<512 { exp[i] = exp[i - 255] }
        return (exp, log)
    }()

    private static func multiply(_ a: Int, _ b: Int) -> Int { a == 0 || b == 0 ? 0 : exp[log[a] + log[b]] }

    /// The remainder of data(x)·x^n divided by the generator with roots α^1…α^n.
    static func errorCorrection(_ data: [Int], count n: Int) -> [Int] {
        var generator = [1]
        for i in 1...n {
            var next = [Int](repeating: 0, count: generator.count + 1)
            for (j, g) in generator.enumerated() {
                next[j] ^= g
                next[j + 1] ^= multiply(g, exp[i])
            }
            generator = next
        }
        var remainder = [Int](repeating: 0, count: n)
        for d in data {
            let factor = d ^ remainder[0]
            remainder.removeFirst()
            remainder.append(0)
            for j in 0..<n { remainder[j] ^= multiply(generator[j + 1], factor) }
        }
        return remainder
    }

    // MARK: Placement (Annex F)

    static func symbol(placing codewords: [Int], size: Int) -> [[Bool]] {
        let n = size - 2
        var grid = [[Int]](repeating: [Int](repeating: -1, count: n), count: n)

        func module(_ r: Int, _ c: Int, _ chr: Int, _ bit: Int) {
            var r = r, c = c
            if r < 0 { r += n; c += 4 - ((n + 4) % 8) }
            if c < 0 { c += n; r += 4 - ((n + 4) % 8) }
            grid[r][c] = chr < codewords.count ? (codewords[chr] >> (8 - bit)) & 1 : 0
        }
        func utah(_ r: Int, _ c: Int, _ chr: Int) {
            module(r - 2, c - 2, chr, 1); module(r - 2, c - 1, chr, 2); module(r - 1, c - 2, chr, 3); module(r - 1, c - 1, chr, 4)
            module(r - 1, c, chr, 5); module(r, c - 2, chr, 6); module(r, c - 1, chr, 7); module(r, c, chr, 8)
        }
        func corner(_ chr: Int, _ cells: [(Int, Int)]) {
            for (i, cell) in cells.enumerated() { module(cell.0, cell.1, chr, i + 1) }
        }

        var chr = 0, r = 4, c = 0
        repeat {
            if r == n && c == 0 {
                corner(chr, [(n - 1, 0), (n - 1, 1), (n - 1, 2), (0, n - 2), (0, n - 1), (1, n - 1), (2, n - 1), (3, n - 1)]); chr += 1
            }
            if r == n - 2 && c == 0 && n % 4 != 0 {
                corner(chr, [(n - 3, 0), (n - 2, 0), (n - 1, 0), (0, n - 4), (0, n - 3), (0, n - 2), (0, n - 1), (1, n - 1)]); chr += 1
            }
            if r == n - 2 && c == 0 && n % 8 == 4 {
                corner(chr, [(n - 3, 0), (n - 2, 0), (n - 1, 0), (0, n - 2), (0, n - 1), (1, n - 1), (2, n - 1), (3, n - 1)]); chr += 1
            }
            if r == n + 4 && c == 2 && n % 8 == 0 {
                corner(chr, [(n - 1, 0), (n - 1, n - 1), (0, n - 3), (0, n - 2), (0, n - 1), (1, n - 3), (1, n - 2), (1, n - 1)]); chr += 1
            }
            repeat {
                if r < n && c >= 0 && grid[r][c] < 0 { utah(r, c, chr); chr += 1 }
                r -= 2; c += 2
            } while r >= 0 && c < n
            r += 1; c += 3
            repeat {
                if r >= 0 && c < n && grid[r][c] < 0 { utah(r, c, chr); chr += 1 }
                r += 2; c -= 2
            } while r < n && c >= 0
            r += 3; c += 1
        } while r < n || c < n
        // Sizes that leave the corner unfilled get a fixed pattern there.
        if grid[n - 1][n - 1] < 0 {
            grid[n - 1][n - 1] = 1; grid[n - 2][n - 2] = 1
            grid[n - 1][n - 2] = 0; grid[n - 2][n - 1] = 0
        }

        // The finder: solid left and bottom edges, alternating top and right edges.
        var out = [[Bool]](repeating: [Bool](repeating: false, count: size), count: size)
        for i in 0..<size {
            out[i][0] = true
            out[size - 1][i] = true
            out[0][i] = i % 2 == 0
            out[i][size - 1] = i % 2 == 1
        }
        for row in 0..<n {
            for col in 0..<n where grid[row][col] == 1 { out[row + 1][col + 1] = true }
        }
        return out
    }
}
