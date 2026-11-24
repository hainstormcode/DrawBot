import CoreGraphics
import XCTest
@testable import DrawBotCore

/// Regression tests built from real demonstrations recorded in web paint apps (coordinates are
/// the page's CSS pixels, which is all the learner needs: one consistent frame).
///
/// Sumo Paint (paint.sumo.app): the colour picker is a popover that opens ON TOP of the canvas
/// (toolbar button at 803,727). Inside: a hue ring (centre 682,380, radius 110.5, red at the top,
/// clockwise) around a saturation × brightness square (617–747 × 315–445), and a hex field at
/// 636–728 × 512–542 that only accepts a value with "#".
final class RecordedPickerTests: XCTestCase {
    let canvas = CGRect(x: 102, y: 154, width: 819, height: 460)   // the white document area
    let screen = [CGRect(x: 0, y: 0, width: 1024, height: 768)]
    let a = ColorLearner.demoColors[0]
    let b = ColorLearner.demoColors[1]
    let toolbarButton = CGPoint(x: 803, y: 727)

    func clicks(_ p: CGPoint, at t: Double, counts: [Int] = [1]) -> [RecordedInput] {
        counts.enumerated().flatMap { i, c in
            [RecordedInput.mouse(.mouseDown, at: p, time: t + 0.003 * Double(i), clickCount: c),
             RecordedInput.mouse(.mouseUp, at: p, time: t + 0.003 * Double(i) + 0.001, clickCount: c)]
        }
    }

    func typing(_ s: String, at t: Double) -> [RecordedInput] {
        s.enumerated().map { i, ch in
            let k = VirtualKey.stroke(for: ch)
            return .key(k.keyCode, String(ch), time: t + 0.004 * Double(i), modifiers: k.modifiers)
        }
    }

    func learn(_ demos: [ColorDemo]) -> Result<ColorPickerProfile, ColorLearner.Failure> {
        ColorLearner.learn(demos: demos, canvas: canvas, screens: screen, appKey: "sumo", appName: "Sumo Paint")
    }

    /// Ring + square on the real geometry.
    func sumoColor(ring: CGPoint, square: CGPoint) -> RGB {
        var ang = atan2(Double(ring.y) - 380, Double(ring.x) - 682) * 180 / .pi + 90
        if ang < 0 { ang += 360 }
        let s = min(max((Double(square.x) - 617.3) / 129.3, 0), 1) * 100
        let v = (1 - min(max((Double(square.y) - 315.3) / 129.3, 0), 1)) * 100
        return ColorMath.rgb(hue: ang, saturation: s, brightness: v)
    }

    // Recorded: the user opened the picker for the first colour and left it open, so the second
    // demo has no "open" click. DrawBot must explain instead of learning a profile that never
    // opens or closes the picker (and would then draw into it).
    func testPopoverLeftOpenBetweenDemosIsExplained() {
        let d1 = clicks(toolbarButton, at: 29.55) + clicks(CGPoint(x: 738, y: 283), at: 30.58) + clicks(CGPoint(x: 719, y: 329), at: 31.59)
        let d2 = clicks(CGPoint(x: 628, y: 477), at: 39.95) + clicks(CGPoint(x: 662, y: 388), at: 40.97)
        guard case .failure(let f) = learn([ColorDemo(color: a, inputs: d1), ColorDemo(color: b, previousColor: a, inputs: d2)]) else {
            return XCTFail("expected an explanation")
        }
        XCTAssertTrue(f.message.contains("start with the picker closed"), f.message)
    }

    func testPopoverLeftOpenAtTheEndIsExplained() {
        let d1 = clicks(toolbarButton, at: 1) + clicks(CGPoint(x: 738, y: 283), at: 2) + clicks(CGPoint(x: 719, y: 329), at: 3)
        let d2 = clicks(toolbarButton, at: 1) + clicks(CGPoint(x: 628, y: 477), at: 2) + clicks(CGPoint(x: 662, y: 388), at: 3)
        guard case .failure(let f) = learn([ColorDemo(color: a, inputs: d1), ColorDemo(color: b, inputs: d2)]) else {
            return XCTFail("expected an explanation")
        }
        XCTAssertTrue(f.message.contains("still open"), f.message)
    }

    // Recorded: open, ring, square, close — for both colours. Clicks inside the canvas rectangle
    // are picker clicks here and must not be thrown away.
    func testSumoRingAndSquareByClicking() throws {
        let d1 = clicks(toolbarButton, at: 182.40) + clicks(CGPoint(x: 737, y: 284), at: 183.43)
            + clicks(CGPoint(x: 721, y: 328), at: 184.44) + clicks(toolbarButton, at: 185.46)
        let d2 = clicks(toolbarButton, at: 191.22) + clicks(CGPoint(x: 628, y: 475), at: 192.24)
            + clicks(CGPoint(x: 660, y: 389), at: 193.26) + clicks(toolbarButton, at: 194.29)
        let profile = try learn([ColorDemo(color: a, inputs: d1), ColorDemo(color: b, previousColor: a, inputs: d2)]).get()
        XCTAssertEqual(profile.space, .hsb)
        XCTAssertTrue(profile.summary.contains("hue ring"), profile.summary)
        let squareRect = CGRect(x: 617.3, y: 315.3, width: 129.3, height: 129.3)
        for test in ColorLearner.testColors + [RGB(r: 0, g: 0, b: 0), RGB(r: 255, g: 255, b: 255), RGB(r: 255, g: 0, b: 0)] {
            let acts = profile.actions(for: test, previous: nil)
            let pointer = acts.filter { if case .wait = $0 { return false }; return true }
            XCTAssertEqual(pointer.count, 4)
            guard case .click(let open, _, _, _) = pointer[0], case .drag(let ringFrom, _, _, _) = pointer[1],
                  case .drag(let sqFrom, let sqTo, _, _) = pointer[2], case .click(let close, _, _, _) = pointer[3] else {
                return XCTFail("unexpected actions \(pointer)")
            }
            XCTAssertEqual(open, toolbarButton)
            XCTAssertEqual(close, toolbarButton)
            // The press must land inside the real square even for colours on its edges (the
            // fitted edges are ~5 pt off because the demos were only approximate).
            XCTAssertTrue(squareRect.contains(sqFrom), "press outside the square for \(test.hex): \(sqFrom)")
            // The square clamps drags, so the colour is decided by where the drag ends.
            let clampedEnd = CGPoint(x: min(max(sqTo.x, squareRect.minX), squareRect.maxX),
                                     y: min(max(sqTo.y, squareRect.minY), squareRect.maxY))
            let got = sumoColor(ring: ringFrom, square: clampedEnd)
            XCTAssertLessThanOrEqual(ColorMath.deltaE(got, test), 6, "\(test.hex) → \(got.hex)")
        }
    }

    // Recorded: open, triple-click the hex field, "#" + hex, Return, close. The event source
    // reported every press of the triple click as a single click; DrawBot must still replay a
    // triple click (otherwise the old value isn't selected and the new one is inserted into it).
    func testSumoHexFieldWithTripleClickAndUnreliableClickCounts() throws {
        let field = CGPoint(x: 676, y: 527)
        func demo(_ c: RGB, prev: RGB?, t: Double) -> ColorDemo {
            ColorDemo(color: c, previousColor: prev, inputs: clicks(toolbarButton, at: t) + clicks(field, at: t + 1, counts: [1, 1, 1])
                      + typing("#" + c.hexNoHash.lowercased() + "\r", at: t + 1.02) + clicks(toolbarButton, at: t + 1.6))
        }
        let profile = try learn([demo(a, prev: nil, t: 1), demo(b, prev: a, t: 4)]).get()
        XCTAssertTrue(profile.isExact)
        let acts = profile.actions(for: RGB(r: 0x50, g: 0xB3, b: 0x69), previous: nil)
        XCTAssertTrue(acts.contains(.click(at: field, button: .left, count: 3, modifiers: [])), "\(acts)")
        let typed = acts.compactMap { a -> String? in if case .key(let k) = a { return k.characters } else { return nil } }.joined()
        XCTAssertEqual(typed, "#50b369\r")
    }

    // MARK: PaintZ (paintz.app)
    //
    // A modal "Colors" dialog over the canvas, opened by the colour button at (763,49) and closed
    // with Save at (783,527). Primary picker: a 256 × 256 saturation × value square at (214,138.5)
    // and a 32-pt hue strip at x 474–506. The strip is linear but offset: hue = 360·f + 15°, so
    // its red seam is 4% from the bottom, not at an end. Its number fields are HSV and R, G, B.

    let paintzCanvas = CGRect(x: 15, y: 128, width: 640, height: 480)
    let paintzButton = CGPoint(x: 763, y: 49)
    let paintzSave = CGPoint(x: 783, y: 527)

    func paintzColor(strip: CGPoint, square: CGPoint) -> RGB {
        let f = min(max((Double(strip.y) - 138.5) / 256, 0), 1)
        let s = min(max((Double(square.x) - 214) / 256, 0), 1) * 100
        let v = (1 - min(max((Double(square.y) - 138.5) / 256, 0), 1)) * 100
        return ColorMath.rgb(hue: (360 * f + 15).truncatingRemainder(dividingBy: 360), saturation: s, brightness: v)
    }

    // Recorded: open, hue strip, square, Save — the user aimed by watching the preview swatch.
    func testPaintZHueStripAndSquareByClicking() throws {
        let d1 = clicks(paintzButton, at: 112.40) + clicks(CGPoint(x: 490, y: 149), at: 113.41)
            + clicks(CGPoint(x: 419, y: 164), at: 113.92) + clicks(paintzSave, at: 114.44)
        let d2 = clicks(paintzButton, at: 115.46) + clicks(CGPoint(x: 490, y: 277), at: 116.48)
            + clicks(CGPoint(x: 304, y: 279), at: 117.00) + clicks(paintzSave, at: 117.51)
        let profile = try ColorLearner.learn(demos: [ColorDemo(color: a, inputs: d1), ColorDemo(color: b, previousColor: a, inputs: d2)],
                                             canvas: paintzCanvas, screens: screen, appKey: "paintz", appName: "PaintZ").get()
        XCTAssertEqual(profile.space, .hsb)
        XCTAssertTrue(profile.summary.contains("hue slider"), profile.summary)
        // Measured in the app: green → #4fb269, purple → #a24eb2. Check the model agrees for a spread
        // of colours away from the strip's red seam.
        for test in [RGB(r: 0x50, g: 0xB3, b: 0x69), RGB(r: 0xA3, g: 0x4F, b: 0xB3), ColorMath.rgb(hue: 200, saturation: 70, brightness: 40)] {
            let pts = profile.actions(for: test, previous: nil).compactMap { a -> CGPoint? in
                if case .drag(_, let to, _, _) = a { return to } else { return nil }
            }
            XCTAssertEqual(pts.count, 2)
            let got = paintzColor(strip: pts[0], square: pts[1])
            XCTAssertLessThanOrEqual(ColorMath.deltaE(got, test), 5, "\(test.hex) → \(got.hex)")
        }
        // The dialog needs ~0.6 s after opening before it takes clicks; the user waited ~1 s, and
        // DrawBot must keep most of that.
        let waits = profile.actions(for: a, previous: nil).compactMap { a -> Double? in if case .wait(let t) = a { return t } else { return nil } }
        XCTAssertGreaterThanOrEqual(waits[1], 0.75)
    }

    // Recorded: open, triple-click R (reported as three single clicks), type R Tab G Tab B Tab, Save.
    func testPaintZRGBFieldsWithTabs() throws {
        func demo(_ c: RGB, prev: RGB?, t: Double) -> ColorDemo {
            ColorDemo(color: c, previousColor: prev, inputs: clicks(paintzButton, at: t) + clicks(CGPoint(x: 452, y: 422), at: t + 1, counts: [1, 1, 1])
                      + typing("\(c.r)\t\(c.g)\t\(c.b)\t", at: t + 1.02) + clicks(paintzSave, at: t + 1.6))
        }
        let profile = try ColorLearner.learn(demos: [demo(a, prev: nil, t: 323), demo(b, prev: a, t: 335)],
                                             canvas: paintzCanvas, screens: screen, appKey: "paintz", appName: "PaintZ").get()
        XCTAssertTrue(profile.isExact)
        XCTAssertEqual(profile.summary, "Types the colour's red value, green value and blue value, plus 3 fixed clicks.")
        let acts = profile.actions(for: RGB(r: 0x50, g: 0xB3, b: 0x69), previous: nil)
        XCTAssertTrue(acts.contains(.click(at: CGPoint(x: 452, y: 422), button: .left, count: 3, modifiers: [])))
        let typed = acts.compactMap { a -> String? in if case .key(let k) = a { return k.characters } else { return nil } }.joined()
        XCTAssertEqual(typed, "80\t179\t105\t")
    }
}
