import CoreGraphics
import Foundation

/// Gray to 1-bit conversion for thermal heads.
///
/// Thermal dots print bigger than their cell (dot gain), so a requested coverage `c` prints about
/// `c^γ` dark. Tone work happens in linear light on coverage (1 is black): the source gray becomes
/// the darkness it should print, then `darkness^(1/γ)` is the coverage to ask for.
public enum Dither {
    /// Default dot-gain exponent until a printer is measured with the step wedge.
    public static let defaultGamma = 0.65

    /// Pixels kept off the dither, with their final value.
    public struct Mask {
        public static let free: UInt8 = 0, black: UInt8 = 1, white: UInt8 = 2
        public let width: Int, height: Int
        /// `free`, `black` or `white` per pixel.
        public var state: [UInt8]

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
            state = Array(repeating: Self.free, count: width * height)
        }

        public mutating func fix(_ i: Int, to v: UInt8) { state[i] = v < 128 ? Self.black : Self.white }
        public var count: Int { state.reduce(0) { $0 + ($1 == Self.free ? 0 : 1) } }
    }

    /// sRGB code value to linear light, 0...1.
    static let linear: [Double] = (0...255).map { i in
        let v = Double(i) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// Coverage to request (0 white, 1 black) for each 8-bit gray.
    /// `cutoff` biases the midpoint: above 0.5 prints darker, below lighter, 0.5 leaves tone alone.
    public static func toneLUT(gamma: Double, cutoff: Double = 0.5) -> [Float] {
        let g = min(3, max(0.2, gamma))
        let c = min(0.95, max(0.05, cutoff))
        let bias = log(0.5) / log(1 - c)
        return (0...255).map { i in
            let dark = 1 - linear[i]
            return Float(min(1, max(0, pow(pow(dark, bias), 1 / g))))
        }
    }

    // MARK: Masks

    /// Codes (with their quiet zones) and solid text on gray: thresholded like crisp, never dithered.
    /// Text gets a one-dot white halo so it stays readable on a gray background.
    static func mask(_ b: GrayBitmap, level: UInt8, codes: [CGRect], text: Bool) -> Mask {
        var m = Mask(width: b.width, height: b.height)
        let w = b.width, h = b.height
        let px = b.pixels
        if text {
            let region = textRegion(b)
            px.withUnsafeBufferPointer { p in
                region.withUnsafeBufferPointer { r in
                    m.state.withUnsafeMutableBufferPointer { st in
                        for i in 0..<(w * h) where r[i] { st[i] = p[i] < level ? Mask.black : Mask.white }
                        // Halo: free pixels touching printed text go white.
                        for i in 0..<(w * h) where r[i] && p[i] < level {
                            let x = i % w, y = i / w
                            let x0 = x > 0 ? -1 : 0, x1 = x < w - 1 ? 1 : 0
                            let y0 = y > 0 ? -1 : 0, y1 = y < h - 1 ? 1 : 0
                            var dy = y0
                            while dy <= y1 {
                                var dx = x0
                                while dx <= x1 {
                                    let j = i + dy * w + dx
                                    if !r[j] { st[j] = Mask.white }
                                    dx += 1
                                }
                                dy += 1
                            }
                        }
                    }
                }
            }
        }
        // Codes last: their pixels are exactly the crisp threshold, halo or not.
        for r in codes {
            let x0 = max(0, Int(r.minX.rounded(.down))), x1 = min(w, Int(r.maxX.rounded(.up)))
            let y0 = max(0, Int(r.minY.rounded(.down))), y1 = min(h, Int(r.maxY.rounded(.up)))
            guard x0 < x1, y0 < y1 else { continue }
            for y in y0..<y1 {
                for x in x0..<x1 { m.fix(y * w + x, to: px[y * w + x] < level ? 0 : 255) }
            }
        }
        return m
    }

    /// Glyph-sized near-black ink with a hard edge to something much lighter (text, thin rules),
    /// grown through its dark interior and one dot of antialiasing. Big dark shapes, like shadows
    /// in a photo, stay with the dither so they don't get outlined.
    static func textRegion(_ b: GrayBitmap) -> [Bool] {
        let w = b.width, h = b.height
        let dark: UInt8 = 72, jump = 110
        let maxGlyph = 48, maxStroke = 6 // dots
        var seed = [Bool](repeating: false, count: w * h)
        var seen = [Bool](repeating: false, count: w * h)
        var stack: [Int] = [], part: [Int] = []
        b.pixels.withUnsafeBufferPointer { p in
            seed.withUnsafeMutableBufferPointer { sd in
                seen.withUnsafeMutableBufferPointer { sn in
                    /// A much lighter pixel one or two dots away.
                    func sharp(_ x: Int, _ y: Int) -> Bool {
                        let v = Int(p[y * w + x]) + jump
                        if x >= 1 && Int(p[y * w + x - 1]) >= v { return true }
                        if x >= 2 && Int(p[y * w + x - 2]) >= v { return true }
                        if x + 1 < w && Int(p[y * w + x + 1]) >= v { return true }
                        if x + 2 < w && Int(p[y * w + x + 2]) >= v { return true }
                        if y >= 1 && Int(p[(y - 1) * w + x]) >= v { return true }
                        if y >= 2 && Int(p[(y - 2) * w + x]) >= v { return true }
                        if y + 1 < h && Int(p[(y + 1) * w + x]) >= v { return true }
                        if y + 2 < h && Int(p[(y + 2) * w + x]) >= v { return true }
                        return false
                    }
                    for start in 0..<(w * h) where !sn[start] && p[start] < dark && sharp(start % w, start / w) {
                        // Flood the dark shape this edge belongs to.
                        part.removeAll(keepingCapacity: true)
                        stack.append(start)
                        sn[start] = true
                        var x0 = w, y0 = h, x1 = 0, y1 = 0
                        while let i = stack.popLast() {
                            part.append(i)
                            let x = i % w, y = i / w
                            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                            if x > 0 && !sn[i - 1] && p[i - 1] < dark { sn[i - 1] = true; stack.append(i - 1) }
                            if x + 1 < w && !sn[i + 1] && p[i + 1] < dark { sn[i + 1] = true; stack.append(i + 1) }
                            if y > 0 && !sn[i - w] && p[i - w] < dark { sn[i - w] = true; stack.append(i - w) }
                            if y + 1 < h && !sn[i + w] && p[i + w] < dark { sn[i + w] = true; stack.append(i + w) }
                        }
                        let bw = x1 - x0 + 1, bh = y1 - y0 + 1
                        if max(bw, bh) <= maxGlyph || min(bw, bh) <= maxStroke { for i in part { sd[i] = true } }
                    }
                }
            }
        }
        // Plus one dot of antialiased fringe, so the edge thresholds cleanly.
        var region = seed
        b.pixels.withUnsafeBufferPointer { p in
            seed.withUnsafeBufferPointer { sd in
                region.withUnsafeMutableBufferPointer { r in
                    for y in 0..<h {
                        for x in 0..<w {
                            let i = y * w + x
                            guard !sd[i] && p[i] < 230 else { continue }
                            if (x > 0 && sd[i - 1]) || (x < w - 1 && sd[i + 1]) || (y > 0 && sd[i - w]) || (y < h - 1 && sd[i + w]) {
                                r[i] = true
                            }
                        }
                    }
                }
            }
        }
        return region
    }

    // MARK: Photo

    /// Serpentine Floyd–Steinberg on tone-mapped coverage, with the pair rule: a dot that would print
    /// alone (every causal neighbour white) pulls the next one black, and a lone hole pulls the next
    /// one white. Single dots print faint and unpredictably on thermal heads; pairs print solid.
    /// Fixed pixels take their mask value; error never flows into or out of them.
    static func floydSteinberg(_ b: inout GrayBitmap, lut: [Float], mask: Mask?) {
        let w = b.width, h = b.height
        var buf = b.pixels.map { lut[Int($0)] }
        var out = [UInt8](repeating: 0, count: w * h) // 1 = black
        let state = mask?.state ?? [UInt8](repeating: Mask.free, count: w * h)
        for i in state.indices where state[i] == Mask.black { out[i] = 1 }
        state.withUnsafeBufferPointer { st in
            buf.withUnsafeMutableBufferPointer { buf in
                out.withUnsafeMutableBufferPointer { out in
                    for y in 0..<h {
                        let s = y & 1 == 1 ? -1 : 1
                        let last = y == h - 1
                        var force: UInt8 = 2 // 2 = none
                        for k in 0..<w {
                            let x = s == 1 ? k : w - 1 - k
                            let i = y * w + x
                            if st[i] != Mask.free { force = 2; continue }
                            let xp = x - s, xn = x + s
                            let hasPrev = xp >= 0 && xp < w, hasNext = xn >= 0 && xn < w
                            var nb = 0, nn = 0
                            if hasPrev { nb += Int(out[i - s]); nn += 1 }
                            if y > 0 {
                                nb += Int(out[i - w]); nn += 1
                                if hasPrev { nb += Int(out[i - w - s]); nn += 1 }
                                if hasNext { nb += Int(out[i - w + s]); nn += 1 }
                            }
                            let v = buf[i]
                            var o: UInt8
                            if force != 2 {
                                o = force
                                force = 2
                            } else {
                                o = v > 0.5 ? 1 : 0
                                let nextFree = hasNext && st[i + s] == Mask.free
                                if o == 1 && nb == 0 {
                                    // Alone so far: pair it with the next dot, or drop it if there is none to take.
                                    if nextFree { force = 1 } else if !(hasNext && out[i + s] == 1) { o = 0 }
                                } else if o == 0 && nn > 0 && nb == nn {
                                    if nextFree { force = 0 } else if !(hasNext && out[i + s] == 0) { o = 1 }
                                }
                            }
                            out[i] = o
                            let err = v - Float(o)
                            if err == 0 { continue }
                            // Floyd–Steinberg along the scan. Error meant for fixed pixels or past the edge is dropped.
                            let fwd = hasNext && st[i + s] == Mask.free
                            let back = !last && hasPrev && st[i + w - s] == Mask.free
                            let down = !last && st[i + w] == Mask.free
                            let diag = !last && hasNext && st[i + w + s] == Mask.free
                            let e = err / 16
                            if fwd { buf[i + s] += 7 * e }
                            if back { buf[i + w - s] += 3 * e }
                            if down { buf[i + w] += 5 * e }
                            if diag { buf[i + w + s] += e }
                        }
                    }
                }
            }
        }
        b.pixels = out.map { $0 == 1 ? 0 : 255 }
    }

    // MARK: Halftone

    /// 45° round-dot clustered screen: a 2a×2a tile holding two dots, pitch a√2 dots
    /// (a = 3 at 200 dpi is about 47 lines per inch). Values are thresholds in 0...1.
    public static func screen(_ a: Int = 3) -> (size: Int, thresholds: [Float]) {
        let t = 2 * a
        var spot: [(Double, Int)] = []
        for y in 0..<t {
            for x in 0..<t {
                let xx = Double(x) + 0.5, yy = Double(y) + 0.5
                let u = (xx + yy) / Double(t), v = (xx - yy) / Double(t)
                spot.append((cos(2 * .pi * u) + cos(2 * .pi * v), y * t + x))
            }
        }
        // Highest spot value grows first; ties keep raster order.
        let order = spot.enumerated().sorted { $0.element.0 != $1.element.0 ? $0.element.0 > $1.element.0 : $0.offset < $1.offset }
        var th = [Float](repeating: 0, count: t * t)
        for (rank, e) in order.enumerated() { th[e.element.1] = (Float(rank) + 0.5) / Float(t * t) }
        return (t, th)
    }

    static func halftone(_ b: inout GrayBitmap, lut: [Float], mask: Mask?) {
        let (t, th) = screen()
        let w = b.width
        for i in b.pixels.indices {
            if let m = mask, m.state[i] != Mask.free { b.pixels[i] = m.state[i] == Mask.black ? 0 : 255; continue }
            let x = i % w, y = i / w
            b.pixels[i] = lut[Int(b.pixels[i])] > th[(y % t) * t + x % t] ? 0 : 255
        }
    }

    /// Black dots with all eight neighbours white.
    public static func isolatedDots(_ b: GrayBitmap) -> Int {
        var n = 0
        for y in 0..<b.height {
            for x in 0..<b.width where b[x, y] == 0 {
                var alone = true
                for dy in -1...1 where alone {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        if nx >= 0, ny >= 0, nx < b.width, ny < b.height, b[nx, ny] == 0 { alone = false; break }
                    }
                }
                if alone { n += 1 }
            }
        }
        return n
    }
}
