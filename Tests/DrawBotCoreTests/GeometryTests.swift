import XCTest
@testable import DrawBotCore

final class GeometryTests: XCTestCase {
    let H: CGFloat = 1080

    func testPointRoundTripAndKnownValues() {
        XCTAssertEqual(Geometry.cocoaToCG(CGPoint(x: 10, y: 1080), primaryScreenHeight: H), CGPoint(x: 10, y: 0))
        XCTAssertEqual(Geometry.cocoaToCG(CGPoint(x: 10, y: 0), primaryScreenHeight: H), CGPoint(x: 10, y: 1080))
        XCTAssertEqual(Geometry.cgToCocoa(CGPoint(x: 5, y: 80), primaryScreenHeight: H), CGPoint(x: 5, y: 1000))
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 123.5, y: 456.25), CGPoint(x: -1920, y: 2160), CGPoint(x: 3000, y: -500)] {
            XCTAssertEqual(Geometry.cgToCocoa(Geometry.cocoaToCG(p, primaryScreenHeight: H), primaryScreenHeight: H), p)
            XCTAssertEqual(Geometry.cocoaToCG(Geometry.cgToCocoa(p, primaryScreenHeight: H), primaryScreenHeight: H), p)
        }
    }

    func testRectPrimaryScreen() {
        // Full primary screen maps to itself.
        let full = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(Geometry.cocoaToCG(full, primaryScreenHeight: H), full)
        // A 100×50 rect whose bottom-left is at Cocoa (10, 20) has its top at Cocoa y=70 → CG y = 1010.
        let r = Geometry.cocoaToCG(CGRect(x: 10, y: 20, width: 100, height: 50), primaryScreenHeight: H)
        XCTAssertEqual(r, CGRect(x: 10, y: 1010, width: 100, height: 50))
    }

    func testRectSecondaryScreenAboveLeft() {
        // Secondary 1440×900 screen above-left of the primary: Cocoa frame origin (-1440, 1080).
        let cocoa = CGRect(x: -1440, y: 1080, width: 1440, height: 900)
        let cg = Geometry.cocoaToCG(cocoa, primaryScreenHeight: H)
        XCTAssertEqual(cg, CGRect(x: -1440, y: -900, width: 1440, height: 900))
        XCTAssertEqual(Geometry.cgToCocoa(cg, primaryScreenHeight: H), cocoa)
        // A rect inside it.
        let inner = CGRect(x: -1000, y: 1500, width: 200, height: 100)
        let innerCG = Geometry.cocoaToCG(inner, primaryScreenHeight: H)
        XCTAssertEqual(innerCG, CGRect(x: -1000, y: -520, width: 200, height: 100))
        XCTAssertTrue(cg.contains(innerCG))
        XCTAssertEqual(Geometry.cgToCocoa(innerCG, primaryScreenHeight: H), inner)
    }

    func testRectBelowPrimary() {
        let cocoa = CGRect(x: 200, y: -768, width: 1024, height: 768)
        let cg = Geometry.cocoaToCG(cocoa, primaryScreenHeight: H)
        XCTAssertEqual(cg, CGRect(x: 200, y: 1080, width: 1024, height: 768))
        XCTAssertEqual(Geometry.cgToCocoa(cg, primaryScreenHeight: H), cocoa)
    }

    func testRectFromCornersAnyOrderRoundsOutward() {
        let expected = CGRect(x: 10, y: 20, width: 91, height: 31)
        XCTAssertEqual(Geometry.rect(from: CGPoint(x: 10.7, y: 20.2), to: CGPoint(x: 100.1, y: 50.9)), expected)
        XCTAssertEqual(Geometry.rect(from: CGPoint(x: 100.1, y: 50.9), to: CGPoint(x: 10.7, y: 20.2)), expected)
        XCTAssertEqual(Geometry.rect(from: CGPoint(x: 100.1, y: 20.2), to: CGPoint(x: 10.7, y: 50.9)), expected)
        XCTAssertEqual(Geometry.rect(from: CGPoint(x: -10.5, y: -3.5), to: CGPoint(x: -1.5, y: 2.5)),
                       CGRect(x: -11, y: -4, width: 10, height: 7))
        XCTAssertEqual(Geometry.rect(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 5, y: 5)).size, .zero)
    }

    func testClamp() {
        let r = CGRect(x: 10, y: 20, width: 100, height: 50)
        XCTAssertEqual(Geometry.clamp(CGPoint(x: 0, y: 0), to: r), CGPoint(x: 10, y: 20))
        XCTAssertEqual(Geometry.clamp(CGPoint(x: 500, y: 500), to: r), CGPoint(x: 110, y: 70))
        XCTAssertEqual(Geometry.clamp(CGPoint(x: 50, y: 30), to: r), CGPoint(x: 50, y: 30))
        XCTAssertEqual(Geometry.clamp(CGPoint(x: 110, y: 70), to: r), CGPoint(x: 110, y: 70))
        XCTAssertEqual(Geometry.clamp(CGPoint(x: -5000, y: 45), to: CGRect(x: -1440, y: -900, width: 1440, height: 900)),
                       CGPoint(x: -1440, y: 0))
    }

    func testGridLayoutCentring() {
        let l = GridLayout(canvas: CGRect(x: 100, y: 200, width: 103, height: 52), penSize: 10)
        XCTAssertEqual(l.columns, 10)
        XCTAssertEqual(l.rows, 5)
        XCTAssertEqual(l.origin, CGPoint(x: 101.5, y: 201))
        XCTAssertEqual(l.cellCenter(col: 0, row: 0), CGPoint(x: 106.5, y: 206))
        XCTAssertEqual(l.cellCenter(col: 9, row: 4), CGPoint(x: 196.5, y: 246))
        // Grid is symmetric inside the canvas.
        let gridMaxX = Double(l.origin.x) + Double(l.columns) * l.penSize
        XCTAssertEqual(Double(l.origin.x) - 100, 203 - gridMaxX, accuracy: 1e-9)
    }

    func testGridLayoutNegativeCoordsAndTinyCanvas() {
        let l = GridLayout(canvas: CGRect(x: -1000, y: -520, width: 200, height: 100), penSize: 4)
        XCTAssertEqual(l.columns, 50)
        XCTAssertEqual(l.rows, 25)
        XCTAssertEqual(l.cellCenter(col: 0, row: 0), CGPoint(x: -998, y: -518))
        let tiny = GridLayout(canvas: CGRect(x: 0, y: 0, width: 2, height: 2), penSize: 10)
        XCTAssertEqual(tiny.columns, 1)
        XCTAssertEqual(tiny.rows, 1)
        XCTAssertEqual(tiny.cellCenter(col: 0, row: 0), CGPoint(x: 1, y: 1))
    }
}
