import CoreGraphics
import Foundation

/// A fixed swatch in an app's color palette: where to click, and the color it selects.
public struct PaletteSwatch: Codable, Equatable, Sendable {
    public var point: CGPoint
    public var color: RGB
    public var clickCount: Int

    public init(point: CGPoint, color: RGB, clickCount: Int = 1) {
        self.point = point
        self.color = color
        self.clickCount = clickCount
    }
}

/// Learns what color each swatch of a fixed palette holds by watching the screen while the user
/// clicks through them.
///
/// Input: a screenshot taken before the first click, and one taken shortly after each click
/// (same rectangle, 1 pixel per point). Most apps show the selected color somewhere (a "current
/// color" circle, primary/secondary squares, a preview). That spot changes color on almost every
/// click, while everything else changes rarely (a selection ring moves, a hover fades). So:
///
/// 1. Count, per pixel, on how many clicks it changed.
/// 2. Keep pixels that changed on most clicks, group them into connected regions, and pick the
///    largest region that is a flat color within each screenshot (that rules out text such as a
///    changing hex label).
/// 3. That region's median color after click i is the color swatch i selects.
///
/// If no such region exists, each swatch's own pixels (in the screenshot taken before it was
/// clicked) are used instead.
public enum PaletteLearner {
    public struct Analysis: Equatable, Sendable {
        /// The color each click selected.
        public var colors: [RGB]
        /// True when the colors were read from a "current color" indicator; false when they were
        /// sampled from the swatches themselves.
        public var fromIndicator: Bool
        /// The indicator's pixels (indices into the image), for checking later selections.
        public var indicator: [Int]
    }

    /// Pixels whose summed RGB difference exceeds this count as "changed".
    static let changeThreshold = 36

    /// `frames[i]` was captured after clicking `clicks[i]` (in image pixel coordinates).
    public static func analyze(baseline: RGBAImage, frames: [RGBAImage], clicks: [CGPoint]) -> Analysis? {
        let n = frames.count
        guard n >= 1, frames.allSatisfy({ $0.width == baseline.width && $0.height == baseline.height }) else { return nil }
        let w = baseline.width, h = baseline.height, count = w * h
        let sequence = [baseline] + frames

        // 1. Change counts.
        var changes = [UInt8](repeating: 0, count: count)
        for i in 1...n {
            let a = sequence[i - 1].data, b = sequence[i].data
            for p in 0..<count where diff(a, b, p) > changeThreshold {
                changes[p] = changes[p] &+ 1
            }
        }

        // 2. Candidate regions.
        let needed = UInt8(max(1, Int((Double(n) * 0.6).rounded(.up))))
        var visited = [Bool](repeating: false, count: count)
        var best: (pixels: [Int], score: Double)?
        for start in 0..<count where !visited[start] && changes[start] >= needed {
            var region: [Int] = []
            var stack = [start]
            visited[start] = true
            while let p = stack.popLast() {
                region.append(p)
                let x = p % w, y = p / w
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h {
                    let q = ny * w + nx
                    if !visited[q] && changes[q] >= needed {
                        visited[q] = true
                        stack.append(q)
                    }
                }
            }
            guard region.count >= 12 else { continue }
            // Flatness: how far pixels sit from the region's median color, averaged over frames.
            var spread = 0.0
            for f in frames {
                let m = median(f, region)
                spread += region.reduce(0.0) { $0 + Double(distance(f.data, $1, m)) } / Double(region.count)
            }
            spread /= Double(n)
            let score = Double(region.count) / (1 + spread / 12)
            if best == nil || score > best!.score { best = (region, score) }
        }

        if let region = best?.pixels {
            // Read only the core of the region (pixels close to the median), ignoring
            // anti-aliased edges.
            let colors = frames.map { f -> RGB in
                let m = median(f, region)
                let core = region.filter { distance(f.data, $0, m) <= 30 }
                return median(f, core.isEmpty ? region : core)
            }
            // A real indicator shows different colors for (most) different swatches.
            if Set(colors).count >= min(n, max(2, n / 2)) {
                return Analysis(colors: colors, fromIndicator: true, indicator: region)
            }
        }

        // 3. Fallback: the swatches' own pixels, from the frame before each click.
        let colors = clicks.enumerated().map { i, p -> RGB in
            let f = sequence[min(i, sequence.count - 1)]
            let cx = Int(p.x.rounded()), cy = Int(p.y.rounded())
            var pixels: [Int] = []
            for dy in -2...2 {
                for dx in -2...2 {
                    let x = cx + dx, y = cy + dy
                    if x >= 0 && y >= 0 && x < w && y < h { pixels.append(y * w + x) }
                }
            }
            return pixels.isEmpty ? RGB(r: 0, g: 0, b: 0) : median(f, pixels)
        }
        return Analysis(colors: colors, fromIndicator: false, indicator: [])
    }

    /// The indicator's color in a new screenshot (to check a selection), or nil.
    public static func indicatorColor(in frame: RGBAImage, indicator: [Int]) -> RGB? {
        guard !indicator.isEmpty, indicator.allSatisfy({ $0 < frame.width * frame.height }) else { return nil }
        let m = median(frame, indicator)
        let core = indicator.filter { distance(frame.data, $0, m) <= 30 }
        return median(frame, core.isEmpty ? indicator : core)
    }

    /// One swatch per spot (a later click on the same swatch wins).
    public static func swatches(clicks: [CGPoint], colors: [RGB], clickCounts: [Int]? = nil) -> [PaletteSwatch] {
        var out: [PaletteSwatch] = []
        for (i, p) in clicks.enumerated() where i < colors.count {
            let s = PaletteSwatch(point: p, color: colors[i], clickCount: clickCounts?[i] ?? 1)
            if let j = out.firstIndex(where: { hypot($0.point.x - p.x, $0.point.y - p.y) <= 6 }) {
                out[j] = s
            } else {
                out.append(s)
            }
        }
        return out
    }

    // MARK: Pixel helpers

    @inline(__always) static func diff(_ a: [UInt8], _ b: [UInt8], _ p: Int) -> Int {
        let i = p * 4
        return abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2]))
    }

    @inline(__always) static func distance(_ d: [UInt8], _ p: Int, _ c: RGB) -> Int {
        let i = p * 4
        return abs(Int(d[i]) - Int(c.r)) + abs(Int(d[i + 1]) - Int(c.g)) + abs(Int(d[i + 2]) - Int(c.b))
    }

    static func median(_ f: RGBAImage, _ pixels: [Int]) -> RGB {
        guard !pixels.isEmpty else { return RGB(r: 0, g: 0, b: 0) }
        func channel(_ o: Int) -> UInt8 {
            let v = pixels.map { f.data[$0 * 4 + o] }.sorted()
            return v[v.count / 2]
        }
        return RGB(r: channel(0), g: channel(1), b: channel(2))
    }
}

extension Quantizer {
    /// Moves every color of `q` to its closest color in `palette` (by CIE ΔE), merging colors that
    /// land on the same one. Used for apps that only offer fixed swatches.
    public static func snap(_ q: QuantizedImage, to palette: [RGB]) -> QuantizedImage {
        guard !palette.isEmpty, !q.palette.isEmpty else { return q }
        let labs = palette.map(ColorMath.lab)
        var newIndexForSwatch: [Int: Int] = [:]
        var newPalette: [RGB] = []
        var map = [Int32](repeating: -1, count: q.palette.count)
        for i in q.palette.indices {
            let l = ColorMath.lab(q.palette[i])
            var bestJ = 0
            var bestD = Double.infinity
            for (j, s) in labs.enumerated() {
                let d = ColorMath.deltaE(l, s)
                if d < bestD { bestD = d; bestJ = j }
            }
            if newIndexForSwatch[bestJ] == nil {
                newIndexForSwatch[bestJ] = newPalette.count
                newPalette.append(palette[bestJ])
            }
            map[i] = Int32(newIndexForSwatch[bestJ]!)
        }
        let labels = q.labels.map { $0 < 0 ? -1 : map[Int($0)] }
        var counts = [Int](repeating: 0, count: newPalette.count)
        for (i, c) in q.counts.enumerated() where map[i] >= 0 { counts[Int(map[i])] += c }
        return QuantizedImage(width: q.width, height: q.height, labels: labels, palette: newPalette, counts: counts)
    }
}
