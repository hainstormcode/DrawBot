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

/// Learns what color each preset color button holds, from the spot the user clicked on it.
///
/// Input: a screenshot taken when the lesson starts, before any click (no hover or "selected"
/// highlight yet), and one taken shortly after each click (same rectangle, 1 pixel per point).
/// Each button's color is read around the exact point the user clicked, in the first
/// screenshot; only if that spot isn't one clear color there (it was covered, or showed an
/// icon) is the last screenshot before that click used instead.
///
/// The spot is a small square around the clicked pixel. Its pixels are grouped by color, so a
/// check mark, a selection ring or the button's edge doesn't pull the color off: the group the
/// clicked pixel belongs to wins when it fills a fair part of the square, otherwise the
/// largest group.
public enum PaletteLearner {
    public struct Analysis: Equatable, Sendable {
        /// The color each click selected.
        public var colors: [RGB]
    }

    /// Half the side of the square read around a click (7 × 7 points).
    static let radius = 3
    /// Pixels closer than this (summed RGB difference) count as the same color.
    static let sameColor = 30

    /// `frames[i]` was captured after clicking `clicks[i]` (in image pixel coordinates).
    public static func analyze(baseline: RGBAImage, frames: [RGBAImage], clicks: [CGPoint]) -> Analysis? {
        guard !clicks.isEmpty else { return nil }
        let colors = clicks.enumerated().map { i, p -> RGB in
            if let c = clickedColor(in: baseline, at: p, strict: true) { return c }
            let before = i > 0 && i - 1 < frames.count ? frames[i - 1] : baseline
            return clickedColor(in: before, at: p, strict: false) ?? clickedColor(in: baseline, at: p, strict: false)
                ?? RGB(r: 0, g: 0, b: 0)
        }
        return Analysis(colors: colors)
    }

    /// The color around `p` in `image`. `strict`: nil unless one color clearly dominates the
    /// spot (at least 40% of it).
    public static func clickedColor(in image: RGBAImage, at p: CGPoint, strict: Bool) -> RGB? {
        let cx = Int(p.x.rounded(.down)), cy = Int(p.y.rounded(.down))
        let w = image.width, h = image.height
        guard cx >= 0, cy >= 0, cx < w, cy < h else { return nil }
        var pixels: [Int] = []
        for dy in -radius...radius {
            for dx in -radius...radius {
                let x = cx + dx, y = cy + dy
                if x >= 0 && y >= 0 && x < w && y < h { pixels.append(y * w + x) }
            }
        }
        let d = image.data
        func near(_ a: Int, _ b: Int) -> Bool { diff(d, d, a, b) <= sameColor }
        func group(around q: Int) -> [Int] { pixels.filter { near($0, q) } }
        let center = cy * w + cx
        var best = group(around: center)
        if Double(best.count) < 0.4 * Double(pixels.count) {
            for q in pixels {
                let g = group(around: q)
                if g.count > best.count { best = g }
            }
        }
        if strict && Double(best.count) < 0.4 * Double(pixels.count) { return nil }
        return median(image, best)
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

    @inline(__always) static func diff(_ a: [UInt8], _ b: [UInt8], _ p: Int, _ q: Int) -> Int {
        let i = p * 4, j = q * 4
        return abs(Int(a[i]) - Int(b[j])) + abs(Int(a[i + 1]) - Int(b[j + 1])) + abs(Int(a[i + 2]) - Int(b[j + 2]))
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
