import CoreGraphics
import XCTest
@testable import DrawBotCore

/// Simulated users demonstrating colours on simulated colour pickers.
final class ColorLearnerTests: XCTestCase {
    let screens = [CGRect(x: 0, y: 0, width: 1512, height: 982)]
    let canvas = CGRect(x: 20, y: 300, width: 400, height: 400)
    let a = ColorLearner.demoColors[0]
    let b = ColorLearner.demoColors[1]

    // MARK: Simulated pickers

    /// Photoshop-like: 256-pt saturation × brightness square + vertical hue strip on its right.
    struct SquareAndStrip {
        var origin = CGPoint(x: 600, y: 200)
        var side = 256.0
        var stripX = 880.0
        func squarePoint(_ c: RGB) -> CGPoint {
            let hsb = ColorMath.hsb(c)
            return CGPoint(x: Double(origin.x) + hsb.s / 100 * side, y: Double(origin.y) + (1 - hsb.b / 100) * side)
        }
        func stripPoint(_ c: RGB) -> CGPoint {
            CGPoint(x: stripX, y: Double(origin.y) + ColorMath.hsb(c).h / 360 * side)
        }
        func color(square p: CGPoint, strip q: CGPoint) -> RGB {
            let s = (Double(p.x) - Double(origin.x)) / side * 100
            let v = (1 - (Double(p.y) - Double(origin.y)) / side) * 100
            let h = (Double(q.y) - Double(origin.y)) / side * 360
            return ColorMath.rgb(hue: h, saturation: s, brightness: v)
        }
    }

    func click(_ p: CGPoint, at t: inout Double, count: Int = 1) -> [RecordedInput] {
        defer { t += 0.6 }
        return [.mouse(.mouseDown, at: p, time: t, clickCount: count), .mouse(.mouseUp, at: p, time: t + 0.08, clickCount: count)]
    }

    func drag(_ from: CGPoint, _ to: CGPoint, at t: inout Double) -> [RecordedInput] {
        var out: [RecordedInput] = [.mouse(.mouseDown, at: from, time: t)]
        for i in 1...10 {
            let f = CGFloat(i) / 10
            out.append(.mouse(.mouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f), time: t + 0.02 * Double(i)))
        }
        out.append(.mouse(.mouseUp, at: to, time: t + 0.25))
        t += 0.8
        return out
    }

    func type(_ s: String, at t: inout Double) -> [RecordedInput] {
        s.map { ch -> RecordedInput in
            let k = VirtualKey.stroke(for: ch)
            t += 0.1
            return .key(k.keyCode, String(ch), time: t, modifiers: k.modifiers)
        }
    }

    func key(_ code: UInt16, _ chars: String, _ mods: KeyModifiers = [], at t: inout Double, paste: String? = nil) -> RecordedInput {
        t += 0.15
        return .key(code, chars, time: t, modifiers: mods, pasteText: paste)
    }

    func learn(_ demos: [ColorDemo], rejected: Set<String> = []) throws -> ColorPickerProfile {
        switch ColorLearner.learn(demos: demos, canvas: canvas, screens: screens, appKey: "test", appName: "Test",
                                  rejected: rejected) {
        case .success(let p): return p
        case .failure(let f): XCTFail(f.message); throw f
        }
    }

    /// Plays `actions` against a picker: last click on the square / strip wins.
    func simulate(_ actions: [ReplayAction], on picker: SquareAndStrip, startingFrom start: RGB) -> RGB {
        var sq = picker.squarePoint(start), st = picker.stripPoint(start)
        let squareRect = CGRect(x: picker.origin.x, y: picker.origin.y, width: picker.side, height: picker.side)
        func land(_ p: CGPoint) {
            if squareRect.insetBy(dx: -2, dy: -2).contains(p) {
                sq = CGPoint(x: min(max(p.x, squareRect.minX), squareRect.maxX), y: min(max(p.y, squareRect.minY), squareRect.maxY))
            } else if abs(p.x - picker.stripX) <= 10 {
                st = CGPoint(x: picker.stripX, y: min(max(p.y, squareRect.minY), squareRect.maxY))
            }
        }
        for a in actions {
            switch a {
            case .click(let p, _, _, _): land(p)
            case .drag(let from, let to, _, _):
                // The control is chosen at mouse-down; the drag clamps inside it.
                if squareRect.insetBy(dx: -2, dy: -2).contains(from) {
                    sq = CGPoint(x: min(max(to.x, squareRect.minX), squareRect.maxX), y: min(max(to.y, squareRect.minY), squareRect.maxY))
                } else { land(from); land(to) }
            default: break
            }
        }
        return picker.color(square: sq, strip: st)
    }

    func assertClose(_ x: RGB, _ y: RGB, tolerance: Int = 4, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(abs(Int(x.r) - Int(y.r)), tolerance, "\(x.hex) vs \(y.hex)", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(Int(x.g) - Int(y.g)), tolerance, "\(x.hex) vs \(y.hex)", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(Int(x.b) - Int(y.b)), tolerance, "\(x.hex) vs \(y.hex)", file: file, line: line)
    }

    // MARK: Tests

    func testDemoColoursDifferInEveryParameter() {
        for p in ColorParam.allCases {
            let d = abs(p.value(of: a) - p.value(of: b))
            XCTAssertGreaterThan(d, 0.1 * p.range, "\(p) barely differs between the demo colours")
        }
    }

    func testHSBRoundTrip() {
        let c = ColorMath.rgb(hue: 30, saturation: 80, brightness: 90)
        XCTAssertEqual(c, RGB(r: 230, g: 138, b: 46))
        let hsb = ColorMath.hsb(c)
        XCTAssertEqual(hsb.h, 30, accuracy: 0.5)
        XCTAssertEqual(hsb.s, 80, accuracy: 0.5)
        XCTAssertEqual(hsb.b, 90, accuracy: 0.5)
    }

    func testLearnsSquareAndHueStrip() throws {
        let picker = SquareAndStrip()
        let swatch = CGPoint(x: 60, y: 120), ok = CGPoint(x: 800, y: 520)
        func demo(_ c: RGB, prev: RGB?, jitter: CGFloat) -> ColorDemo {
            var t = 0.0
            var e = click(CGPoint(x: swatch.x + jitter, y: swatch.y), at: &t)
            e += click(picker.stripPoint(c), at: &t)
            e += click(picker.squarePoint(c), at: &t)
            e += click(CGPoint(x: ok.x - jitter, y: ok.y + jitter), at: &t)
            return ColorDemo(color: c, previousColor: prev, inputs: e)
        }
        let profile = try learn([demo(a, prev: nil, jitter: 0), demo(b, prev: a, jitter: 3)])
        XCTAssertEqual(profile.space, .hsb)
        XCTAssertFalse(profile.isExact)
        XCTAssertEqual(profile.steps.count, 4)
        for test in ColorLearner.testColors + [RGB(r: 0, g: 0, b: 0), RGB(r: 255, g: 0, b: 0), RGB(r: 128, g: 128, b: 128)] {
            let got = simulate(profile.actions(for: test, previous: b), on: picker, startingFrom: b)
            assertClose(got, test)
        }
    }

    func testLearnsSquareAndStripWithDragsAndCorrections() throws {
        let picker = SquareAndStrip()
        func demo(_ c: RGB, prev: RGB?, dab: CGPoint) -> ColorDemo {
            var t = 0.0
            // Rough click on the square, then a correction 5 pt away, then a drag on the strip.
            var e = click(CGPoint(x: picker.squarePoint(c).x - 5, y: picker.squarePoint(c).y + 2), at: &t)
            e += click(picker.squarePoint(c), at: &t)
            e += drag(CGPoint(x: picker.stripX, y: 260), picker.stripPoint(c), at: &t)
            // A test stroke on the canvas (must not be replayed).
            e += drag(dab, CGPoint(x: dab.x + 30, y: dab.y + 5), at: &t)
            return ColorDemo(color: c, previousColor: prev, inputs: e)
        }
        let profile = try learn([demo(a, prev: nil, dab: CGPoint(x: 200, y: 500)), demo(b, prev: a, dab: CGPoint(x: 120, y: 420))])
        XCTAssertEqual(profile.steps.count, 2)
        for test in ColorLearner.testColors {
            assertClose(simulate(profile.actions(for: test, previous: nil), on: picker, startingFrom: b), test)
        }
    }

    func testLearnsHexTyping() throws {
        let field = CGPoint(x: 1000, y: 150)
        func demo(_ c: RGB, dx: CGFloat) -> ColorDemo {
            var t = 0.0
            var e = click(CGPoint(x: field.x + dx, y: field.y), at: &t)
            e.append(key(VirtualKey.a, "a", [.command], at: &t))
            e += type("#" + c.hexNoHash.lowercased(), at: &t)
            e.append(key(VirtualKey.returnKey, "\r", at: &t))
            e.append(.key(VirtualKey.returnKey, "\r", time: t + 1, modifiers: [.control, .option, .command]))  // DrawBot's hotkey
            return ColorDemo(color: c, inputs: e)
        }
        let profile = try learn([demo(a, dx: 0), demo(b, dx: 20)])
        XCTAssertTrue(profile.isExact)
        XCTAssertTrue(profile.summary.contains("hex"), profile.summary)
        let test = RGB(r: 0x12, g: 0xAB, b: 0xEF)
        let actions = profile.actions(for: test, previous: nil)
        let typed = actions.compactMap { a -> String? in
            if case .key(let k) = a, !k.isShortcut, k.keyCode != VirtualKey.returnKey { return k.characters }
            return nil
        }.joined()
        XCTAssertEqual(typed, "#12abef")
        XCTAssertTrue(actions.contains { if case .key(let k) = $0 { return k.keyCode == VirtualKey.a && k.modifiers == [.command] }; return false })
        XCTAssertTrue(actions.contains { if case .key(let k) = $0 { return k.keyCode == VirtualKey.returnKey }; return false })
        XCTAssertEqual(actions.filter { if case .click = $0 { return true }; return false }.count, 1)
    }

    func testLearnsRGBFieldsWithTabs() throws {
        func demo(_ c: RGB) -> ColorDemo {
            var t = 0.0
            var e = click(CGPoint(x: 900, y: 400), at: &t, count: 2)
            e += type(String(c.r), at: &t)
            e.append(key(VirtualKey.tab, "\t", at: &t))
            e += type(String(c.g) + "9", at: &t)
            e.append(key(VirtualKey.delete, "\u{7F}", at: &t))   // typo fixed with backspace
            e.append(key(VirtualKey.tab, "\t", at: &t))
            e += type(String(c.b), at: &t)
            e.append(key(VirtualKey.returnKey, "\r", at: &t))
            return ColorDemo(color: c, inputs: e)
        }
        let profile = try learn([demo(a), demo(b)])
        XCTAssertTrue(profile.isExact)
        let test = RGB(r: 7, g: 200, b: 99)
        let typed = profile.actions(for: test, previous: nil).compactMap { a -> String? in
            if case .key(let k) = a { return k.characters }
            return nil
        }.joined()
        XCTAssertEqual(typed, "7\t200\t99\r")
    }

    func testLearnsPaste() throws {
        func demo(_ c: RGB) -> ColorDemo {
            var t = 0.0
            var e = click(CGPoint(x: 1000, y: 150), at: &t, count: 3)
            e.append(key(VirtualKey.v, "v", [.command], at: &t, paste: c.hexNoHash))
            e.append(key(VirtualKey.returnKey, "\r", at: &t))
            return ColorDemo(color: c, inputs: e)
        }
        let profile = try learn([demo(a), demo(b)])
        let test = RGB(r: 1, g: 2, b: 3)
        let actions = profile.actions(for: test, previous: nil)
        XCTAssertTrue(actions.contains(.setClipboard("010203")))
        XCTAssertTrue(actions.contains(.click(at: CGPoint(x: 1000, y: 150), button: .left, count: 3, modifiers: [])))
    }

    func testLearnsRGBSliders() throws {
        // Three horizontal sliders, 0 at x = 1000, 255 at x = 1255.
        func pt(_ v: UInt8, row: Int) -> CGPoint { CGPoint(x: 1000 + Double(v), y: 600 + Double(row) * 30) }
        func demo(_ c: RGB) -> ColorDemo {
            var t = 0.0
            var e = click(pt(c.r, row: 0), at: &t)
            e += click(pt(c.g, row: 1), at: &t)
            e += click(pt(c.b, row: 2), at: &t)
            return ColorDemo(color: c, inputs: e)
        }
        let profile = try learn([demo(a), demo(b)])
        XCTAssertEqual(profile.space, .rgb)
        let test = RGB(r: 10, g: 128, b: 250)
        let ends = profile.actions(for: test, previous: nil).compactMap { a -> CGPoint? in
            if case .drag(_, let to, _, _) = a { return to }
            return nil
        }
        XCTAssertEqual(ends.count, 3)
        XCTAssertEqual(Double(ends[0].x), 1010, accuracy: 0.5)
        XCTAssertEqual(Double(ends[1].x), 1128, accuracy: 0.5)
        XCTAssertEqual(Double(ends[2].x), 1250, accuracy: 0.5)
    }

    func testWheelIsLearnedOnceAThirdDemoRulesOutTheSquare() throws {
        // macOS-style: hue = angle, saturation = radius (100 pt), brightness slider below the wheel.
        let centre = CGPoint(x: 1100, y: 300)
        func wheel(_ c: RGB) -> CGPoint {
            let hsb = ColorMath.hsb(c)
            let ang = hsb.h * .pi / 180
            return CGPoint(x: Double(centre.x) + 100 * hsb.s / 100 * cos(ang), y: Double(centre.y) - 100 * hsb.s / 100 * sin(ang))
        }
        func slider(_ c: RGB) -> CGPoint { CGPoint(x: 1000 + 200 * ColorMath.hsb(c).b / 100, y: 450) }
        func demo(_ c: RGB) -> ColorDemo {
            var t = 0.0
            var e = click(wheel(c), at: &t)
            e += click(slider(c), at: &t)
            return ColorDemo(color: c, inputs: e)
        }
        let c = ColorLearner.testColors[0]
        var demos = [demo(a), demo(b)]
        var rejected = Set<String>()
        var profile = try learn(demos)
        // The simulated user says "no" until the wheel is right (at most two more demos).
        for test in ColorLearner.testColors.prefix(3) {
            let target = profile.actions(for: test, previous: nil).compactMap { a -> CGPoint? in
                if case .drag(_, let to, _, _) = a { return to }
                return nil
            }
            if let first = target.first, hypot(first.x - wheel(test).x, first.y - wheel(test).y) < 2 { break }
            rejected.insert(profile.hypothesisKey)
            demos.append(demo(test))
            profile = try learn(demos, rejected: rejected)
        }
        XCTAssertLessThanOrEqual(demos.count, 4)
        let test = ColorMath.rgb(hue: 250, saturation: 40, brightness: 50)
        let ends = profile.actions(for: test, previous: nil).compactMap { a -> CGPoint? in
            if case .drag(_, let to, _, _) = a { return to }
            return nil
        }
        XCTAssertEqual(ends.count, 2)
        XCTAssertEqual(Double(ends[0].x), Double(wheel(test).x), accuracy: 1.5)
        XCTAssertEqual(Double(ends[0].y), Double(wheel(test).y), accuracy: 1.5)
        XCTAssertEqual(Double(ends[1].x), Double(slider(test).x), accuracy: 1.5)
        _ = c
    }

    func testNothingChangedFails() {
        var t = 0.0
        let same = click(CGPoint(x: 900, y: 100), at: &t)
        let r = ColorLearner.learn(demos: [ColorDemo(color: a, inputs: same), ColorDemo(color: b, inputs: same)],
                                   canvas: canvas, screens: screens, appKey: "k", appName: "K")
        guard case .failure(let f) = r else { return XCTFail("expected failure") }
        XCTAssertTrue(f.message.contains("Nothing changed"), f.message)
    }

    func testCanvasOnlyDemoFails() {
        var t = 0.0
        let inCanvas = click(CGPoint(x: 100, y: 400), at: &t)
        let r = ColorLearner.learn(demos: [ColorDemo(color: a, inputs: inCanvas), ColorDemo(color: b, inputs: inCanvas)],
                                   canvas: canvas, screens: screens, appKey: "k", appName: "K")
        guard case .failure = r else { return XCTFail("expected failure") }
    }

    func testProfileIsCodable() throws {
        let picker = SquareAndStrip()
        func demo(_ c: RGB) -> ColorDemo {
            var t = 0.0
            return ColorDemo(color: c, inputs: click(picker.squarePoint(c), at: &t) + click(picker.stripPoint(c), at: &t))
        }
        let profile = try learn([demo(a), demo(b)])
        let data = try JSONEncoder().encode(profile)
        let back = try JSONDecoder().decode(ColorPickerProfile.self, from: data)
        XCTAssertEqual(back, profile)
    }
}
