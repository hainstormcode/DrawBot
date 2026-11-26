import CoreGraphics
import XCTest
import DrawBotCore
@testable import DrawBotSystem

final class RecordingReplaySink: ReplayEventSink {
    var mouse: [(CGEventType, CGPoint, Int64)] = []
    var keys: [(KeyStroke, Bool)] = []
    var clipboard: [String] = []
    var cursorOverride: CGPoint?
    var escape = false
    var onKey: ((KeyStroke) -> Void)?

    func postMouse(_ type: CGEventType, at p: CGPoint, button: PointerButton, clickState: Int64, modifiers: KeyModifiers,
                   delta: (Int64, Int64)) {
        mouse.append((type, p, clickState))
    }
    func postKey(_ stroke: KeyStroke, down: Bool) { keys.append((stroke, down)); if down { onKey?(stroke) } }
    func setClipboard(_ s: String) { clipboard.append(s) }
    func cursorLocation() -> CGPoint? { cursorOverride ?? mouse.last?.1 }
    func escapePressed() -> Bool { escape }
    func isTrusted() -> Bool { true }
    var slept: TimeInterval = 0
    func sleep(_ seconds: TimeInterval) { slept += seconds }
}

final class InputReplayerTests: XCTestCase {
    func run(_ actions: [ReplayAction], sink: RecordingReplaySink, pace: Double = 1) -> InputReplayer.Outcome {
        let replayer = InputReplayer(sink: { sink })
        replayer.pace = pace
        let done = expectation(description: "done")
        var outcome: InputReplayer.Outcome?
        replayer.run(actions) { outcome = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        return outcome!
    }

    func testPlaysClicksDragsKeysAndClipboard() {
        let sink = RecordingReplaySink()
        let outcome = run([
            .click(at: CGPoint(x: 10, y: 10), button: .left, count: 2, modifiers: []),
            .drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 110, y: 100), button: .left, modifiers: []),
            .setClipboard("ABCDEF"),
            .key(KeyStroke(keyCode: VirtualKey.v, characters: "v", modifiers: [.command])),
            .wait(0.01),
        ], sink: sink)
        XCTAssertEqual(outcome, .completed)
        let types = sink.mouse.map(\.0)
        XCTAssertEqual(types.filter { $0 == .leftMouseDown }.count, 3)
        XCTAssertEqual(types.filter { $0 == .leftMouseUp }.count, 3)
        // Double click: click states 1 then 2.
        XCTAssertEqual(sink.mouse.filter { $0.0 == .leftMouseDown }.map(\.2).prefix(2), [1, 2])
        XCTAssertEqual(sink.mouse.last?.1, CGPoint(x: 110, y: 100))
        XCTAssertTrue(types.contains(.leftMouseDragged))
        XCTAssertEqual(sink.clipboard, ["ABCDEF"])
        XCTAssertEqual(sink.keys.count, 2)
    }

    func testPaceScalesEveryPause() {
        let actions: [ReplayAction] = [
            .click(at: CGPoint(x: 10, y: 10), button: .left, count: 1, modifiers: []),
            .wait(0.5),
            .key(KeyStroke(keyCode: VirtualKey.returnKey, characters: "\r", modifiers: [])),
            .drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 130, y: 100), button: .left, modifiers: []),
        ]
        let normal = RecordingReplaySink(), quick = RecordingReplaySink(), slow = RecordingReplaySink()
        XCTAssertEqual(run(actions, sink: normal), .completed)
        XCTAssertEqual(run(actions, sink: quick, pace: 0.25), .completed)
        XCTAssertEqual(run(actions, sink: slow, pace: 1.8), .completed)
        XCTAssertEqual(quick.slept, normal.slept * 0.25, accuracy: 0.02)
        XCTAssertEqual(slow.slept, normal.slept * 1.8, accuracy: 0.03)
        XCTAssertEqual(quick.mouse.count, normal.mouse.count, "same input, only faster")
    }

    func testEstimatedDurationMatchesTheReplay() {
        let actions: [ReplayAction] = [
            .click(at: CGPoint(x: 10, y: 10), button: .left, count: 3, modifiers: []),
            .wait(0.3),
            .key(KeyStroke(keyCode: VirtualKey.returnKey, characters: "\r", modifiers: [])),
            .drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 160, y: 120), button: .left, modifiers: []),
        ]
        for pace in [0.25, 1, 1.8] {
            let sink = RecordingReplaySink()
            XCTAssertEqual(run(actions, sink: sink, pace: pace), .completed)
            XCTAssertEqual(InputReplayer.estimatedDuration(of: actions, pace: pace), sink.slept, accuracy: 1e-9)
        }
        XCTAssertGreaterThan(InputReplayer.estimatedDuration(of: actions), 0.3)
    }

    func testDragApproachesTheEndInFineSteps() {
        let sink = RecordingReplaySink()
        XCTAssertEqual(run([.drag(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 40, y: 0), button: .left, modifiers: [])], sink: sink), .completed)
        let xs = sink.mouse.filter { $0.0 == .leftMouseDragged }.map { Double($0.1.x) }
        XCTAssertEqual(xs.last, 40)
        // Coarse early on, never more than 1 pt apart over the last 10 pt.
        XCTAssertLessThan(xs.count, 25)
        for (a, b) in zip(xs, xs.dropFirst()) where a >= 30 { XCTAssertLessThanOrEqual(b - a, 1.0001) }
        XCTAssertEqual(ReplayWorker.dragDistances(length: 2.5), [1, 2, 2.5])
    }

    func testMouseMoveStopsAndReleases() {
        let sink = RecordingReplaySink()
        sink.onKey = { _ in sink.cursorOverride = CGPoint(x: 500, y: 500) }   // the user grabs the mouse
        let outcome = run([
            .click(at: CGPoint(x: 10, y: 10), button: .left, count: 1, modifiers: []),
            .key(KeyStroke(keyCode: 0, characters: "a")),
            .click(at: CGPoint(x: 20, y: 20), button: .left, count: 1, modifiers: []),
        ], sink: sink)
        XCTAssertEqual(outcome, .stopped(reason: DrawingEngine.Reason.mouseMoved))
        XCTAssertEqual(sink.mouse.filter { $0.0 == .leftMouseDown }.count, 1)
        XCTAssertEqual(sink.mouse.filter { $0.0 == .leftMouseDown }.count, sink.mouse.filter { $0.0 == .leftMouseUp }.count)
    }

    func testEscapeStops() {
        let sink = RecordingReplaySink()
        sink.escape = true
        XCTAssertEqual(run([.wait(0.05), .key(KeyStroke(keyCode: 0, characters: "a"))], sink: sink),
                       .stopped(reason: DrawingEngine.Reason.escape))
        XCTAssertTrue(sink.keys.isEmpty)
    }
}

