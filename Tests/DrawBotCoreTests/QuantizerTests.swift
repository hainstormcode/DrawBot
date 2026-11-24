import XCTest
@testable import DrawBotCore

final class QuantizerTests: XCTestCase {
    func assertWellFormed(_ q: QuantizedImage, _ img: RGBAImage, threshold: UInt8 = 128,
                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(q.width, img.width, file: file, line: line)
        XCTAssertEqual(q.height, img.height, file: file, line: line)
        XCTAssertEqual(q.labels.count, img.width * img.height, file: file, line: line)
        XCTAssertEqual(q.palette.count, q.counts.count, file: file, line: line)
        var counts = [Int](repeating: 0, count: q.palette.count)
        var opaque = 0
        for i in 0..<q.labels.count {
            let l = Int(q.labels[i])
            let isOpaque = img.data[i * 4 + 3] >= threshold
            if isOpaque { opaque += 1 }
            if isOpaque {
                XCTAssertTrue(l >= 0 && l < q.palette.count, "label \(l) out of range", file: file, line: line)
                if l >= 0 && l < counts.count { counts[l] += 1 }
            } else {
                XCTAssertEqual(l, -1, file: file, line: line)
            }
        }
        XCTAssertEqual(counts, q.counts, file: file, line: line)
        XCTAssertEqual(q.counts.reduce(0, +), opaque, file: file, line: line)
        XCTAssertTrue(q.counts.allSatisfy { $0 > 0 }, file: file, line: line)
    }

    func testEmptyAndFullyTransparent() {
        let empty = RGBAImage(width: 0, height: 0, data: [])
        let qe = Quantizer.quantize(empty, options: QuantizeOptions())
        XCTAssertEqual(qe.palette, [])
        XCTAssertEqual(qe.labels, [])
        let clear = TestImages.rgba(width: 7, height: 5) { _, _ in (255, 0, 0, 10) }
        let q = Quantizer.quantize(clear, options: QuantizeOptions())
        XCTAssertEqual(q.palette, [])
        XCTAssertEqual(q.counts, [])
        XCTAssertEqual(q.labels, [Int32](repeating: -1, count: 35))
    }

    func testExactColoursPath() {
        let colours: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (0, 128, 0), (10, 20, 200), (250, 250, 250), (255, 1, 0)]
        let img = TestImages.rgba(width: 20, height: 10) { x, y in
            if y == 0 && x < 3 { return (0, 0, 0, 0) }  // transparent pixels
            let c = colours[(x / 4 + y) % colours.count]
            return (c.0, c.1, c.2, 255)
        }
        // mergeDistance 0: exact colours preserved, even the near-duplicate (255,1,0).
        let q = Quantizer.quantize(img, options: QuantizeOptions(maxColors: 8, mergeDistance: 0))
        assertWellFormed(q, img)
        XCTAssertEqual(Set(q.palette), Set(colours.map { RGB(r: $0.0, g: $0.1, b: $0.2) }))
        XCTAssertEqual(q.palette.count, 5)
        for y in 0..<10 {
            for x in 0..<20 {
                let l = q.labels[y * 20 + x]
                guard l >= 0 else { continue }
                let p = TestImages.pixel(img, x, y)
                XCTAssertEqual(q.palette[Int(l)], RGB(r: p.r, g: p.g, b: p.b))
            }
        }
        XCTAssertEqual(q.labels[0], -1)
        // With default merging, the two near-identical reds merge; the others stay exact.
        let qm = Quantizer.quantize(img, options: QuantizeOptions(maxColors: 8))
        assertWellFormed(qm, img)
        XCTAssertEqual(qm.palette.count, 4)
        XCTAssertTrue(qm.palette.contains(RGB(r: 0, g: 128, b: 0)))
        XCTAssertTrue(qm.palette.contains(RGB(r: 10, g: 20, b: 200)))
        XCTAssertTrue(qm.palette.contains(RGB(r: 250, g: 250, b: 250)))
    }

    func testPixelArtExactWhenColoursEqualMax() {
        // Exactly maxColors distinct colours → exact path.
        var rng = SplitMix64(seed: 5)
        let pal: [RGB] = (0..<6).map { _ in RGB(r: UInt8(rng.next() & 255), g: UInt8(rng.next() & 255), b: UInt8(rng.next() & 255)) }
        let img = TestImages.rgba(width: 16, height: 16) { x, y in
            let c = pal[(x * 7 + y * 3) % 6]
            return (c.r, c.g, c.b, 255)
        }
        let q = Quantizer.quantize(img, options: QuantizeOptions(maxColors: 6, mergeDistance: 0))
        assertWellFormed(q, img)
        XCTAssertEqual(Set(q.palette), Set(pal))
    }

    func testKMeansOnGradient() {
        let img = TestImages.rgba(width: 256, height: 8) { x, _ in (UInt8(x), UInt8(x), UInt8(x), 255) }
        let q = Quantizer.quantize(img, options: QuantizeOptions(maxColors: 4, mergeDistance: 0))
        assertWellFormed(q, img)
        XCTAssertEqual(q.palette.count, 4)
        // Palette entries are distinct greys spanning the range; labels are monotone along x.
        let greys = q.palette.map { Int($0.r) }.sorted()
        XCTAssertLessThan(greys.first!, 80)
        XCTAssertGreaterThan(greys.last!, 170)
        var lastGrey = -1
        for x in 0..<256 {
            let g = Int(q.palette[Int(q.labels[x])].r)
            XCTAssertGreaterThanOrEqual(g, lastGrey)
            lastGrey = g
        }
        // Each pixel is assigned to its closest palette colour (in Lab), approximately.
        for x in stride(from: 0, to: 256, by: 5) {
            let c = RGB(r: UInt8(x), g: UInt8(x), b: UInt8(x))
            let assigned = ColorMath.deltaE(c, q.palette[Int(q.labels[x])])
            let best = q.palette.map { ColorMath.deltaE(c, $0) }.min()!
            XCTAssertLessThanOrEqual(assigned, best + 1.0)
        }
        // Palette is the mean of members.
        for (i, p) in q.palette.enumerated() {
            let members = (0..<256).filter { q.labels[$0] == Int32(i) }
            let mean = Double(members.reduce(0, +)) / Double(members.count)
            XCTAssertEqual(Double(p.r), mean, accuracy: 0.51)
        }
    }

    func testMaxColoursRespectedAndClamped() {
        let img = TestImages.photoLike(width: 120, height: 80)
        for k in [1, 2, 5, 16, 64, 200] {
            let q = Quantizer.quantize(img, options: QuantizeOptions(maxColors: k, mergeDistance: 0))
            assertWellFormed(q, img)
            XCTAssertLessThanOrEqual(q.palette.count, min(64, k))
            XCTAssertGreaterThanOrEqual(q.palette.count, 1)
        }
        let q0 = Quantizer.quantize(img, options: QuantizeOptions(maxColors: 0))
        XCTAssertEqual(q0.palette.count, 1)
    }

    func testDeterminism() {
        let img = TestImages.photoLike(width: 300, height: 250)  // 75k px > sample size
        let opts = QuantizeOptions(maxColors: 12, mergeDistance: 4, seed: 1234)
        let a = Quantizer.quantize(img, options: opts)
        let b = Quantizer.quantize(img, options: opts)
        XCTAssertEqual(a, b)
        assertWellFormed(a, img)
        // A different seed is still well-formed (and usually different).
        var o2 = opts; o2.seed = 99
        assertWellFormed(Quantizer.quantize(img, options: o2), img)
    }

    func testMergeBehaviour() {
        // Two clearly different colours plus near-duplicates of each.
        let img = TestImages.rgba(width: 40, height: 10) { x, _ in
            switch x % 4 {
            case 0: return (200, 30, 30, 255)
            case 1: return (203, 32, 28, 255)   // ΔE ~ 2 from case 0
            case 2: return (30, 30, 200, 255)
            default: return (32, 28, 204, 255)
            }
        }
        let unmerged = Quantizer.quantize(img, options: QuantizeOptions(maxColors: 8, mergeDistance: 0))
        XCTAssertEqual(unmerged.palette.count, 4)
        let merged = Quantizer.quantize(img, options: QuantizeOptions(maxColors: 8, mergeDistance: 6))
        assertWellFormed(merged, img)
        XCTAssertEqual(merged.palette.count, 2)
        XCTAssertEqual(merged.counts, [200, 200])
        // Merged palette entry is the count-weighted mean.
        let red = merged.palette.first { $0.r > 100 }!
        XCTAssertEqual(red, RGB(r: 202, g: 31, b: 29))  // (200+203)/2 = 201.5 → 202 etc.
        // Huge merge distance collapses everything into one colour.
        let one = Quantizer.quantize(img, options: QuantizeOptions(maxColors: 8, mergeDistance: 500))
        assertWellFormed(one, img)
        XCTAssertEqual(one.palette.count, 1)
        // Weighted merge: 3:1 ratio pulls the mean toward the majority.
        let w = TestImages.rgba(width: 4, height: 1) { x, _ in x < 3 ? (100, 100, 100, 255) : (104, 104, 104, 255) }
        let qw = Quantizer.quantize(w, options: QuantizeOptions(maxColors: 4, mergeDistance: 5))
        XCTAssertEqual(qw.palette, [RGB(r: 101, g: 101, b: 101)])
        XCTAssertEqual(qw.counts, [4])
    }

    func testTransparencyThreshold() {
        let img = TestImages.rgba(width: 10, height: 10) { x, y in
            (UInt8(x * 25), UInt8(y * 25), 100, UInt8(x * 28))  // alpha 0…252 across x
        }
        let q = Quantizer.quantize(img, options: QuantizeOptions(maxColors: 5))
        assertWellFormed(q, img)
        for y in 0..<10 {
            for x in 0..<10 {
                XCTAssertEqual(q.labels[y * 10 + x] == -1, x * 28 < 128)
            }
        }
        let q2 = Quantizer.quantize(img, options: QuantizeOptions(maxColors: 5, alphaThreshold: 0))
        XCTAssertFalse(q2.labels.contains(-1))
        assertWellFormed(q2, img, threshold: 0)
    }

    func testRemovingAndPreview() {
        let img = TestImages.rgba(width: 6, height: 2) { x, y in
            if x == 5 && y == 1 { return (0, 0, 0, 0) }
            return x < 2 ? (255, 0, 0, 255) : x < 4 ? (0, 255, 0, 255) : (0, 0, 255, 255)
        }
        let q = Quantizer.quantize(img, options: QuantizeOptions(maxColors: 8))
        XCTAssertEqual(q.palette, [RGB(r: 255, g: 0, b: 0), RGB(r: 0, g: 255, b: 0), RGB(r: 0, g: 0, b: 255)])
        XCTAssertEqual(q.counts, [4, 4, 3])

        let preview = Quantizer.previewImage(q)
        XCTAssertEqual(preview.width, 6); XCTAssertEqual(preview.height, 2)
        XCTAssertEqual(preview, img)

        let r = Quantizer.removing([1, 99, -3], from: q)
        XCTAssertEqual(r.palette, q.palette)
        XCTAssertEqual(r.counts, [4, 0, 3])
        XCTAssertEqual(Array(r.labels[0..<6]), [0, 0, -1, -1, 2, 2])
        XCTAssertEqual(ColorMath.order(r, by: .lightToDark), [0, 2].sorted {
            ColorMath.lab(q.palette[$0]).L > ColorMath.lab(q.palette[$1]).L })
        XCTAssertEqual(StrokePlanner.runs(for: 1, in: r), [])
        let rp = Quantizer.previewImage(r)
        XCTAssertEqual(TestImages.pixel(rp, 2, 0).a, 0)
        XCTAssertEqual(TestImages.pixel(rp, 0, 0).a, 255)
        XCTAssertEqual(Quantizer.removing([], from: q), q)
    }

    /// Performance check: 1000×700 photo-like image, 16 colours. The hard bound is loose so it
    /// also passes in debug builds; the printed time is what matters in release.
    func testQuantizePerformance1000x700() {
        let img = TestImages.photoLike(width: 1000, height: 700)
        let opts = QuantizeOptions(maxColors: 16, mergeDistance: 6)
        let t0 = Date()
        let q = Quantizer.quantize(img, options: opts)
        let dt = Date().timeIntervalSince(t0)
        print(String(format: "quantize 1000x700 k=16: %.1f ms (%d colours)", dt * 1000, q.palette.count))
        XCTAssertLessThanOrEqual(q.palette.count, 16)
        XCTAssertGreaterThan(q.palette.count, 4)
        XCTAssertEqual(q.counts.reduce(0, +), 700_000)
        #if DEBUG
        XCTAssertLessThan(dt, 30)
        #else
        XCTAssertLessThan(dt, 1)
        #endif
    }
}
