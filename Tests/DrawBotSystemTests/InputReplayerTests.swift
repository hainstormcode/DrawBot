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
    func sleep(_ seconds: TimeInterval) {}
}

final class InputReplayerTests: XCTestCase {
    func run(_ actions: [ReplayAction], sink: RecordingReplaySink) -> InputReplayer.Outcome {
        let replayer = InputReplayer(sink: { sink })
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
