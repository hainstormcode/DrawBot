import XCTest
@testable import DrawBotCore

final class ColorMathTests: XCTestCase {
    func testLabKnownValues() {
        let white = ColorMath.lab(RGB(r: 255, g: 255, b: 255))
        XCTAssertEqual(white.L, 100, accuracy: 0.01)
        XCTAssertEqual(white.a, 0, accuracy: 0.01)
        XCTAssertEqual(white.b, 0, accuracy: 0.01)
        let black = ColorMath.lab(RGB(r: 0, g: 0, b: 0))
        XCTAssertEqual(black.L, 0, accuracy: 0.01)
        XCTAssertEqual(black.a, 0, accuracy: 0.01)
        let red = ColorMath.lab(RGB(r: 255, g: 0, b: 0))
        XCTAssertEqual(red.L, 53.24, accuracy: 0.05)
        XCTAssertEqual(red.a, 80.09, accuracy: 0.05)
        XCTAssertEqual(red.b, 67.20, accuracy: 0.05)
        let green = ColorMath.lab(RGB(r: 0, g: 255, b: 0))
        XCTAssertEqual(green.L, 87.73, accuracy: 0.05)
        XCTAssertEqual(green.a, -86.18, accuracy: 0.05)
        XCTAssertEqual(green.b, 83.18, accuracy: 0.05)
        let blue = ColorMath.lab(RGB(r: 0, g: 0, b: 255))
        XCTAssertEqual(blue.L, 32.30, accuracy: 0.05)
        XCTAssertEqual(blue.a, 79.19, accuracy: 0.05)
        XCTAssertEqual(blue.b, -107.86, accuracy: 0.05)
        let grey = ColorMath.lab(RGB(r: 128, g: 128, b: 128))
        XCTAssertEqual(grey.L, 53.59, accuracy: 0.05)
        XCTAssertEqual(grey.a, 0, accuracy: 0.01)
    }

    func testLabRoundTrip() {
        var rng = SplitMix64(seed: 7)
        for _ in 0..<2000 {
            let c = RGB(r: UInt8(rng.next() & 255), g: UInt8(rng.next() & 255), b: UInt8(rng.next() & 255))
            XCTAssertEqual(ColorMath.rgb(ColorMath.lab(c)), c)
        }
        // Out-of-gamut Lab clamps instead of crashing.
        let clamped = ColorMath.rgb(LabColor(L: 150, a: 200, b: -200))
        XCTAssertEqual(clamped.r, 255)
        XCTAssertEqual(ColorMath.rgb(LabColor(L: -20, a: 0, b: 0)), RGB(r: 0, g: 0, b: 0))
    }

    func testDeltaE() {
        let w = RGB(r: 255, g: 255, b: 255), k = RGB(r: 0, g: 0, b: 0)
        XCTAssertEqual(ColorMath.deltaE(w, k), 100, accuracy: 0.01)
        XCTAssertEqual(ColorMath.deltaE(w, w), 0)
        let a = RGB(r: 200, g: 30, b: 90), b = RGB(r: 20, g: 200, b: 180)
        XCTAssertEqual(ColorMath.deltaE(a, b), ColorMath.deltaE(b, a), accuracy: 1e-12)
    }

    func testIsNearWhite() {
        XCTAssertTrue(ColorMath.isNearWhite(RGB(r: 255, g: 255, b: 255)))
        XCTAssertTrue(ColorMath.isNearWhite(RGB(r: 245, g: 245, b: 240)))
        XCTAssertFalse(ColorMath.isNearWhite(RGB(r: 200, g: 200, b: 200)))  // L≈81
        XCTAssertFalse(ColorMath.isNearWhite(RGB(r: 255, g: 255, b: 0)))    // bright yellow, high chroma
        XCTAssertFalse(ColorMath.isNearWhite(RGB(r: 255, g: 220, b: 230)))  // pink, chroma > 8
        XCTAssertFalse(ColorMath.isNearWhite(RGB(r: 0, g: 0, b: 0)))
    }

    func testHSB() {
        func check(_ c: RGB, _ h: Double, _ s: Double, _ b: Double, file: StaticString = #filePath, line: UInt = #line) {
            let v = ColorMath.hsb(c)
            XCTAssertEqual(v.h, h, accuracy: 0.1, file: file, line: line)
            XCTAssertEqual(v.s, s, accuracy: 0.1, file: file, line: line)
            XCTAssertEqual(v.b, b, accuracy: 0.1, file: file, line: line)
        }
        check(RGB(r: 255, g: 0, b: 0), 0, 100, 100)
        check(RGB(r: 0, g: 255, b: 0), 120, 100, 100)
        check(RGB(r: 0, g: 0, b: 255), 240, 100, 100)
        check(RGB(r: 255, g: 255, b: 0), 60, 100, 100)
        check(RGB(r: 255, g: 0, b: 255), 300, 100, 100)
        check(RGB(r: 255, g: 0, b: 1), 359.76, 100, 100)
        check(RGB(r: 0, g: 0, b: 0), 0, 0, 0)
        check(RGB(r: 255, g: 255, b: 255), 0, 0, 100)
        check(RGB(r: 128, g: 128, b: 128), 0, 0, 50.2)
        check(RGB(r: 255, g: 128, b: 0), 30.1, 100, 100)
        check(RGB(r: 100, g: 50, b: 50), 0, 50, 39.2)
        var rng = SplitMix64(seed: 99)
        for _ in 0..<500 {
            let v = ColorMath.hsb(RGB(r: UInt8(rng.next() & 255), g: UInt8(rng.next() & 255), b: UInt8(rng.next() & 255)))
            XCTAssertTrue(v.h >= 0 && v.h < 360)
        }
    }

    func testApproximateName() {
        let cases: [(RGB, String)] = [
            (RGB(r: 0, g: 0, b: 0), "black"),
            (RGB(r: 255, g: 255, b: 255), "white"),
            (RGB(r: 128, g: 128, b: 128), "grey"),
            (RGB(r: 210, g: 210, b: 210), "light grey"),
            (RGB(r: 60, g: 60, b: 60), "dark grey"),
            (RGB(r: 255, g: 0, b: 0), "red"),
            (RGB(r: 128, g: 0, b: 0), "dark red"),
            (RGB(r: 255, g: 192, b: 203), "pale pink"),
            (RGB(r: 255, g: 140, b: 160), "pink"),
            (RGB(r: 255, g: 140, b: 0), "orange"),
            (RGB(r: 139, g: 69, b: 19), "brown"),
            (RGB(r: 90, g: 50, b: 20), "dark brown"),
            (RGB(r: 255, g: 230, b: 0), "yellow"),
            (RGB(r: 180, g: 255, b: 0), "lime"),
            (RGB(r: 0, g: 200, b: 0), "green"),
            (RGB(r: 0, g: 100, b: 0), "dark green"),
            (RGB(r: 150, g: 255, b: 150), "light green"),
            (RGB(r: 0, g: 160, b: 130), "teal"),
            (RGB(r: 0, g: 255, b: 255), "cyan"),
            (RGB(r: 0, g: 0, b: 255), "blue"),
            (RGB(r: 0, g: 0, b: 128), "dark blue"),
            (RGB(r: 173, g: 216, b: 230), "pale blue"),
            (RGB(r: 128, g: 0, b: 255), "purple"),
            (RGB(r: 255, g: 0, b: 255), "magenta"),
            (RGB(r: 255, g: 20, b: 147), "pink"),
        ]
        for (c, name) in cases {
            XCTAssertEqual(ColorMath.approximateName(c), name, "\(c.hex)")
        }
        // Never empty for any colour.
        var rng = SplitMix64(seed: 3)
        for _ in 0..<1000 {
            let c = RGB(r: UInt8(rng.next() & 255), g: UInt8(rng.next() & 255), b: UInt8(rng.next() & 255))
            XCTAssertFalse(ColorMath.approximateName(c).isEmpty)
        }
    }

    func testOrder() {
        let palette = [RGB(r: 128, g: 128, b: 128), RGB(r: 255, g: 255, b: 255), RGB(r: 0, g: 0, b: 0),
                       RGB(r: 128, g: 128, b: 128), RGB(r: 255, g: 0, b: 0)]
        let counts = [5, 10, 5, 0, 7]
        let q = QuantizedImage(width: 0, height: 0, labels: [], palette: palette, counts: counts)
        // Index 3 has count 0 → excluded. Indices 0 and 3 tie on L, 0 and 2 tie on count.
        XCTAssertEqual(ColorMath.order(q, by: .lightToDark), [1, 0, 4, 2])  // L: 100, 53.6, 53.2, 0
        XCTAssertEqual(ColorMath.order(q, by: .darkToLight), [2, 4, 0, 1])
        XCTAssertEqual(ColorMath.order(q, by: .mostPixelsFirst), [1, 4, 0, 2])
        XCTAssertEqual(ColorMath.order(q, by: .fewestPixelsFirst), [0, 2, 4, 1])
        // Equal-L ties are broken by index.
        let q2 = QuantizedImage(width: 0, height: 0, labels: [], palette: [palette[0], palette[1], palette[0]], counts: [1, 1, 1])
        XCTAssertEqual(ColorMath.order(q2, by: .lightToDark), [1, 0, 2])
        XCTAssertEqual(ColorMath.order(q2, by: .darkToLight), [0, 2, 1])
        let empty = QuantizedImage(width: 0, height: 0, labels: [], palette: [], counts: [])
        for o in ColorOrder.allCases { XCTAssertEqual(ColorMath.order(empty, by: o), []) }
    }
}
