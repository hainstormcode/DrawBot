import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import DrawBotCore

final class ImageLoaderTests: XCTestCase {
    /// Top half red, bottom half blue (CG user space is y-up, so the top half is y ≥ h/2).
    func redOverBlue(width: Int, height: Int) -> CGImage {
        TestImages.make(width: width, height: height) { ctx in
            TestImages.fill(ctx, CGRect(x: 0, y: height / 2, width: width, height: height - height / 2), 1, 0, 0)
            TestImages.fill(ctx, CGRect(x: 0, y: 0, width: width, height: height / 2), 0, 0, 1)
        }
    }

    func assertColor(_ img: RGBAImage, _ x: Int, _ y: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255,
                     tol: Int = 2, file: StaticString = #filePath, line: UInt = #line) {
        let p = TestImages.pixel(img, x, y)
        XCTAssertTrue(abs(Int(p.r) - Int(r)) <= tol && abs(Int(p.g) - Int(g)) <= tol &&
                      abs(Int(p.b) - Int(b)) <= tol && abs(Int(p.a) - Int(a)) <= tol,
                      "pixel (\(x),\(y)) = \(p), expected (\(r),\(g),\(b),\(a))", file: file, line: line)
    }

    func testOrientationTopRowIsTop() {
        let src = redOverBlue(width: 40, height: 40)
        for (w, h) in [(40, 40), (20, 20), (8, 8), (80, 80)] {  // same size, 2×, 5× down, 2× up
            let r = ImageLoader.rasterize(src, width: w, height: h)
            XCTAssertEqual(r.width, w); XCTAssertEqual(r.height, h)
            XCTAssertEqual(r.data.count, w * h * 4)
            assertColor(r, 0, 0, 255, 0, 0)
            assertColor(r, w - 1, 0, 255, 0, 0)
            assertColor(r, w / 2, h - 1, 0, 0, 255)
        }
    }

    func testAspectFitLetterboxIsTransparent() {
        // 100×50 opaque green into 20×20 → 20×10 centerd, rows 5..<15.
        let src = TestImages.make(width: 100, height: 50) { ctx in
            TestImages.fill(ctx, CGRect(x: 0, y: 0, width: 100, height: 50), 0, 1, 0)
        }
        let r = ImageLoader.rasterize(src, width: 20, height: 20)
        for y in 0..<20 {
            for x in 0..<20 {
                let a = TestImages.pixel(r, x, y).a
                if y < 5 || y >= 15 { XCTAssertEqual(a, 0, "(\(x),\(y))") }
                else { assertColor(r, x, y, 0, 255, 0) }
            }
        }
        // Tall image into wide raster → pillarbox.
        let tall = TestImages.make(width: 10, height: 40) { ctx in
            TestImages.fill(ctx, CGRect(x: 0, y: 0, width: 10, height: 40), 1, 1, 0)
        }
        let r2 = ImageLoader.rasterize(tall, width: 30, height: 12)  // → 3×12 at x 13..<16
        for x in 0..<30 {
            let a = TestImages.pixel(r2, x, 6).a
            XCTAssertEqual(a, (13..<16).contains(x) ? 255 : 0, "x=\(x)")
        }
    }

    func testStraightAlpha() {
        // 50%-alpha red: premultiplied would be (128,0,0,128); straight must be (255,0,0,~128).
        let src = TestImages.make(width: 16, height: 16) { ctx in
            TestImages.fill(ctx, CGRect(x: 0, y: 0, width: 16, height: 16), 1, 0, 0, 0.5)
        }
        for size in [16, 4] {
            let r = ImageLoader.rasterize(src, width: size, height: size)
            let p = TestImages.pixel(r, 1, 1)
            XCTAssertEqual(Int(p.a), 128, accuracy: 2)
            XCTAssertGreaterThanOrEqual(p.r, 252)
            XCTAssertEqual(p.g, 0); XCTAssertEqual(p.b, 0)
        }
        // Fully transparent source stays fully transparent with zero color.
        let clear = TestImages.make(width: 8, height: 8) { _ in }
        XCTAssertTrue(ImageLoader.rasterize(clear, width: 4, height: 4).data.allSatisfy { $0 == 0 })
    }

    func testLargeDownscaleKeepsThinDetail() {
        // White 400×400 with 1-px black vertical lines every 8 px → 25% / 12.5% ink coverage.
        let src = TestImages.make(width: 400, height: 400, opaque: true) { ctx in
            TestImages.fill(ctx, CGRect(x: 0, y: 0, width: 400, height: 400), 1, 1, 1)
            for x in stride(from: 0, to: 400, by: 8) { TestImages.fill(ctx, CGRect(x: x, y: 0, width: 1, height: 400), 0, 0, 0) }
        }
        let r = ImageLoader.rasterize(src, width: 25, height: 25)  // 16× downscale
        // Area average: each output pixel covers 16 source columns with 2 black → 255*14/16 ≈ 223.
        for y in [0, 12, 24] {
            for x in 0..<25 {
                let p = TestImages.pixel(r, x, y)
                XCTAssertEqual(Int(p.r), 223, accuracy: 3, "(\(x),\(y))")
                XCTAssertEqual(p.a, 255)
            }
        }
    }

    func testDownscaleAveragesColors() {
        // Checkerboard of red and blue 1-px cells downscaled 10× → uniform purple-ish (sRGB mean ≈ 128).
        let src = TestImages.make(width: 100, height: 100) { ctx in
            for y in 0..<100 { for x in 0..<100 {
                if (x + y) % 2 == 0 { TestImages.fill(ctx, CGRect(x: x, y: y, width: 1, height: 1), 1, 0, 0) }
                else { TestImages.fill(ctx, CGRect(x: x, y: y, width: 1, height: 1), 0, 0, 1) }
            } }
        }
        let r = ImageLoader.rasterize(src, width: 10, height: 10)
        for y in 0..<10 { for x in 0..<10 { assertColor(r, x, y, 128, 0, 128, tol: 2) } }
    }

    func testPixelArtUpscaleStaysCrisp() {
        // 4×4 two-color checkerboard upscaled 10× must contain only the two original colors.
        let src = TestImages.make(width: 4, height: 4) { ctx in
            for y in 0..<4 { for x in 0..<4 {
                let on = (x + y) % 2 == 0
                TestImages.fill(ctx, CGRect(x: x, y: y, width: 1, height: 1), on ? 1 : 0, on ? 1 : 0, 0)
            } }
        }
        let r = ImageLoader.rasterize(src, width: 40, height: 40)
        let q = Quantizer.quantize(r, options: QuantizeOptions(maxColors: 8, mergeDistance: 0))
        XCTAssertEqual(Set(q.palette), [RGB(r: 255, g: 255, b: 0), RGB(r: 0, g: 0, b: 0)])
        XCTAssertEqual(q.counts, [800, 800])
    }

    func testSizeClampAndDegenerate() {
        let src = redOverBlue(width: 10, height: 10)
        let r = ImageLoader.rasterize(src, width: 0, height: -5)
        XCTAssertEqual(r.width, 1); XCTAssertEqual(r.height, 1)
        XCTAssertEqual(r.data.count, 4)
        XCTAssertEqual(r.data[3], 255)
        // Extremely thin image into a square still yields ≥ 1 px of content.
        let thin = TestImages.make(width: 1000, height: 1) { ctx in
            TestImages.fill(ctx, CGRect(x: 0, y: 0, width: 1000, height: 1), 0, 0, 0)
        }
        let rt = ImageLoader.rasterize(thin, width: 10, height: 10)
        XCTAssertEqual(rt.width, 10)
        XCTAssertTrue((0..<10).contains { TestImages.pixel(rt, 5, $0).a > 0 })
    }

    // MARK: loading

    func writeImage(_ image: CGImage, type: UTType, orientation: Int? = nil) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DrawBotCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("img." + (type.preferredFilenameExtension ?? "img"))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        var props: [CFString: Any] = [:]
        if let o = orientation { props[kCGImagePropertyOrientation] = o }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testLoadPNGRoundTrip() throws {
        let src = redOverBlue(width: 30, height: 20)
        let url = try writeImage(src, type: .png)
        let img = try ImageLoader.loadCGImage(from: url)
        XCTAssertEqual(img.width, 30); XCTAssertEqual(img.height, 20)
        let r = ImageLoader.rasterize(img, width: 30, height: 20)
        assertColor(r, 0, 0, 255, 0, 0)
        assertColor(r, 0, 19, 0, 0, 255)
        // Data-based loading too.
        let data = try Data(contentsOf: url)
        let fromData = try XCTUnwrap(ImageLoader.loadCGImage(data: data))
        XCTAssertEqual(fromData.width, 30)
    }

    func testLoadAppliesEXIFOrientation() throws {
        // Stored pixels: 30 wide × 20 tall, red on top. Orientation 6 = "rotate 90° CW to display",
        // so the upright image is 20 wide × 30 tall with the stored top (red) on the RIGHT.
        let src = redOverBlue(width: 30, height: 20)
        let url = try writeImage(src, type: .jpeg, orientation: 6)
        let img = try ImageLoader.loadCGImage(from: url)
        XCTAssertEqual(img.width, 20)
        XCTAssertEqual(img.height, 30)
        let r = ImageLoader.rasterize(img, width: 20, height: 30)
        let right = TestImages.pixel(r, 18, 15), left = TestImages.pixel(r, 1, 15)
        XCTAssertGreaterThan(right.r, 200); XCTAssertLessThan(right.b, 60)
        XCTAssertGreaterThan(left.b, 200); XCTAssertLessThan(left.r, 60)
    }

    func testLoadErrors() throws {
        let missing = URL(fileURLWithPath: "/nonexistent/definitely-not-here.png")
        XCTAssertThrowsError(try ImageLoader.loadCGImage(from: missing)) { e in
            guard case ImageLoaderError.cannotOpen = e else { return XCTFail("\(e)") }
            XCTAssertNotNil((e as? LocalizedError)?.errorDescription)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DrawBotCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let junk = dir.appendingPathComponent("junk.png")
        try Data("this is not an image".utf8).write(to: junk)
        XCTAssertThrowsError(try ImageLoader.loadCGImage(from: junk)) { e in
            guard case ImageLoaderError.cannotDecode = e else { return XCTFail("\(e)") }
        }
        XCTAssertNil(ImageLoader.loadCGImage(data: Data([1, 2, 3])))
    }

    func testMakeCGImageRoundTrip() throws {
        let rgba = TestImages.rgba(width: 5, height: 3) { x, y in (UInt8(x * 50), UInt8(y * 100), 7, 255) }
        let cg = try XCTUnwrap(ImageLoader.makeCGImage(rgba))
        XCTAssertEqual(ImageLoader.rasterize(cg, width: 5, height: 3), rgba)
    }

    func testEndToEndPipeline() {
        let src = redOverBlue(width: 200, height: 96)  // → exactly 25×12, boundary on a row edge
        let layout = GridLayout(canvas: CGRect(x: 0, y: 0, width: 100, height: 100), penSize: 4)  // 25×25
        let raster = ImageLoader.rasterize(src, width: layout.columns, height: layout.rows)
        let q = Quantizer.quantize(raster, options: QuantizeOptions())
        XCTAssertEqual(q.palette.count, 2)
        let order = ColorMath.order(q, by: .lightToDark)
        XCTAssertEqual(order.count, 2)
        let total = order.reduce(0) { acc, i in acc + StrokePlanner.runs(for: i, in: q).reduce(0) { $0 + $1.length } }
        XCTAssertEqual(total, q.counts.reduce(0, +))
        let strokes = order.flatMap { StrokePlanner.strokes(for: $0, in: q, layout: layout) }
        XCTAssertTrue(strokes.allSatisfy { layout.canvas.contains($0.start) && layout.canvas.contains($0.end) })
        XCTAssertGreaterThan(TimeEstimator.estimate(strokes, speed: .normal), 0)
    }
}
