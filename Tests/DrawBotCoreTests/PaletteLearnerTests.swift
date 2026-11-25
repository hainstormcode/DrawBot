import CoreGraphics
import XCTest
@testable import DrawBotCore

/// A synthetic toolbar like PaintZ's: a "current color" ring that shows the selected color,
/// twelve swatch circles (the selected one gets a white outline), and a hex label whose glyphs
/// change with every selection.
final class PaletteLearnerTests: XCTestCase {
    let w = 360, h = 90
    let background = RGB(r: 48, g: 48, b: 48)
    let swatchColors: [RGB] = [
        RGB(r: 0, g: 0, b: 0), RGB(r: 121, g: 85, b: 72), RGB(r: 244, g: 67, b: 54), RGB(r: 255, g: 152, b: 0),
        RGB(r: 255, g: 235, b: 59), RGB(r: 118, g: 255, b: 3), RGB(r: 255, g: 255, b: 255), RGB(r: 158, g: 158, b: 158),
        RGB(r: 76, g: 175, b: 80), RGB(r: 128, g: 216, b: 255), RGB(r: 41, g: 98, b: 255), RGB(r: 156, g: 39, b: 176),
    ]

    func swatchCenter(_ i: Int) -> CGPoint { CGPoint(x: 110 + (i % 6) * 38, y: 25 + (i / 6) * 38) }

    func blank() -> [UInt8] {
        var d = [UInt8](repeating: 255, count: w * h * 4)
        for p in 0..<(w * h) { d[p * 4] = background.r; d[p * 4 + 1] = background.g; d[p * 4 + 2] = background.b }
        return d
    }

    func put(_ d: inout [UInt8], _ x: Int, _ y: Int, _ c: RGB, alpha: Double = 1) {
        guard x >= 0, y >= 0, x < w, y < h else { return }
        let i = (y * w + x) * 4
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(a) * (1 - alpha) + Double(b) * alpha).rounded()) }
        d[i] = mix(d[i], c.r); d[i + 1] = mix(d[i + 1], c.g); d[i + 2] = mix(d[i + 2], c.b)
    }

    func ring(_ d: inout [UInt8], center: CGPoint, inner: Double, outer: Double, _ c: RGB) {
        for y in 0..<h {
            for x in 0..<w {
                let r = hypot(Double(x) - Double(center.x), Double(y) - Double(center.y))
                if r >= inner && r <= outer { put(&d, x, y, c) }
                else if r > outer && r < outer + 1 || r < inner && r > inner - 1 { put(&d, x, y, c, alpha: 0.5) }   // anti-aliasing
            }
        }
    }

    /// The toolbar with `selected` (or nothing) selected.
    func frame(selected: Int?, indicator: Bool = true) -> RGBAImage {
        var d = blank()
        let current = selected.map { swatchColors[$0] } ?? RGB(r: 0, g: 0, b: 0)
        if indicator {
            ring(&d, center: CGPoint(x: 45, y: 45), inner: 0, outer: 15, RGB(r: 255, g: 255, b: 255))
            ring(&d, center: CGPoint(x: 45, y: 45), inner: 15, outer: 21, current)
            // Hex label: glyph-like pixels that depend on the selected color.
            for k in 0..<60 {
                let bit = (Int(current.r) * 7 + Int(current.g) * 13 + Int(current.b) * 3 + k * 31) % 3 == 0
                put(&d, 20 + (k % 30), 75 + (k / 30) * 2, bit ? RGB(r: 255, g: 255, b: 255) : background)
            }
        }
        for i in swatchColors.indices {
            ring(&d, center: swatchCenter(i), inner: 0, outer: 13, swatchColors[i])
            if i == selected { ring(&d, center: swatchCenter(i), inner: 14, outer: 16, RGB(r: 255, g: 255, b: 255)) }
        }
        return RGBAImage(width: w, height: h, data: d)
    }

    func testFindsColorsFromTheCurrentColorIndicator() throws {
        let order = Array(swatchColors.indices)
        let analysis = try XCTUnwrap(PaletteLearner.analyze(baseline: frame(selected: nil),
                                                            frames: order.map { frame(selected: $0) },
                                                            clicks: order.map(swatchCenter)))
        XCTAssertTrue(analysis.fromIndicator)
        XCTAssertEqual(analysis.colors, order.map { swatchColors[$0] })
        // The indicator is the ring around (45,45), not the hex label or a swatch.
        let xs = analysis.indicator.map { $0 % w }, ys = analysis.indicator.map { $0 / w }
        XCTAssertLessThan(xs.max()!, 70)
        XCTAssertLessThan(ys.max()!, 70)
        // It can read a later selection.
        XCTAssertEqual(PaletteLearner.indicatorColor(in: frame(selected: 4), indicator: analysis.indicator), swatchColors[4])
    }

    func testFallsBackToTheSwatchesThemselvesWithoutAnIndicator() throws {
        let order = [3, 8, 0, 10, 6]
        let analysis = try XCTUnwrap(PaletteLearner.analyze(baseline: frame(selected: nil, indicator: false),
                                                            frames: order.map { frame(selected: $0, indicator: false) },
                                                            clicks: order.map(swatchCenter)))
        XCTAssertFalse(analysis.fromIndicator)
        XCTAssertEqual(analysis.colors, order.map { swatchColors[$0] })
    }

    func testSwatchesDeduplicateRepeatedClicks() {
        let s = PaletteLearner.swatches(clicks: [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 10), CGPoint(x: 12, y: 11)],
                                        colors: [RGB(r: 1, g: 1, b: 1), RGB(r: 2, g: 2, b: 2), RGB(r: 3, g: 3, b: 3)])
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0].color, RGB(r: 3, g: 3, b: 3))
    }

    func testSnapMovesColorsToTheirNearestSwatchAndMerges() {
        let q = QuantizedImage(width: 4, height: 1, labels: [0, 1, 2, -1],
                               palette: [RGB(r: 250, g: 60, b: 50), RGB(r: 235, g: 75, b: 60), RGB(r: 20, g: 20, b: 30)],
                               counts: [1, 1, 1])
        let s = Quantizer.snap(q, to: swatchColors)
        XCTAssertEqual(s.palette, [RGB(r: 244, g: 67, b: 54), RGB(r: 0, g: 0, b: 0)])
        XCTAssertEqual(s.labels, [0, 0, 1, -1])
        XCTAssertEqual(s.counts, [2, 1])
    }

    func testPaletteProfileClicksTheNearestSwatch() {
        let swatches = swatchColors.indices.map { PaletteSwatch(point: swatchCenter($0), color: swatchColors[$0]) }
        let p = ColorPickerProfile(appKey: "k", appName: "K", steps: [], keyMap: [:], space: nil, summary: "", learnedAt: Date(),
                                   hypothesisKey: "palette", pointerBounds: nil, isExact: true, swatches: swatches)
        XCTAssertEqual(p.actions(for: RGB(r: 240, g: 70, b: 60), previous: nil).first,
                       .click(at: swatchCenter(2), button: .left, count: 1, modifiers: []))
    }
}
