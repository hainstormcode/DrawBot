import CoreGraphics
import DrawBotCore
@testable import DrawBotSystem
import XCTest

/// A simulated window server: records events instead of posting them, and answers cursor reads
/// from the recorded events (optionally lagging, rounding, or offset by a simulated user).
/// Never touches real input.
final class FakeWorld: MouseEventSink {
    private let lock = NSLock()
    private var _events: [SyntheticMouseEvent] = []
    private var readsSincePost = 0
    private var _time: TimeInterval = 1000

    let initialCursor: CGPoint
    /// Simulated physical-mouse offset, applied to reads until our next post overrides it.
    var userOffset = CGVector.zero
    /// The first `lagReads` cursor reads after each post return the point posted `lag` events earlier.
    var lag = 0
    var lagReads = 1
    /// Simulated continuous physical motion (points/second of fake time), starting once
    /// `userVelocityFrom` events have been posted. Each of our posts puts the cursor back.
    var userVelocity = CGVector.zero
    var userVelocityFrom = Int.max
    /// Reads return the initial cursor until fake time reaches this (a slow start).
    var ignoreEventsUntil: TimeInterval = 0
    private var lastPostTime: TimeInterval = 0
    /// Round cursor reads to multiples of this (simulates window-server rounding).
    var rounding: CGFloat?
    /// Cursor never moves (simulates macOS dropping our events).
    var ignoreEvents = false
    var trusted = true
    var escapeDown = false
    /// Called on the worker thread after each post with (event index, event).
    var onPost: ((Int, SyntheticMouseEvent) -> Void)?

    init(cursor: CGPoint = CGPoint(x: 700, y: 700)) { initialCursor = cursor }

    var events: [SyntheticMouseEvent] { lock.lock(); defer { lock.unlock() }; return _events }

    func post(_ event: SyntheticMouseEvent) {
        lock.lock()
        _events.append(event)
        let index = _events.count - 1
        readsSincePost = 0
        lastPostTime = _time
        userOffset = .zero // our absolute-position event puts the cursor back
        let hook = onPost
        lock.unlock()
        hook?(index, event)
    }

    func cursorLocation() -> CGPoint? {
        lock.lock()
        defer { lock.unlock() }
        var p: CGPoint
        if ignoreEvents || _events.isEmpty || _time < ignoreEventsUntil {
            p = initialCursor
        } else if lag > 0 && readsSincePost < lagReads {
            let i = _events.count - 1 - lag
            p = i >= 0 ? _events[i].point : initialCursor
        } else {
            p = _events[_events.count - 1].point
        }
        readsSincePost += 1
        p.x += userOffset.dx
        p.y += userOffset.dy
        if _events.count >= userVelocityFrom {
            p.x += userVelocity.dx * (_time - lastPostTime)
            p.y += userVelocity.dy * (_time - lastPostTime)
        }
        if let r = rounding {
            p.x = (p.x / r).rounded() * r
            p.y = (p.y / r).rounded() * r
        }
        return p
    }

    func setUserOffset(_ v: CGVector) { lock.lock(); userOffset = v; lock.unlock() }
    func setTrusted(_ v: Bool) { lock.lock(); trusted = v; lock.unlock() }
    func setEscape(_ v: Bool) { lock.lock(); escapeDown = v; lock.unlock() }
    private func isTrusted() -> Bool { lock.lock(); defer { lock.unlock() }; return trusted }
    private func isEscape() -> Bool { lock.lock(); defer { lock.unlock() }; return escapeDown }
    private func advance(_ s: TimeInterval) { lock.lock(); _time += max(0, s); lock.unlock() }
    private func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return _time }

    var environment: DrawingEnvironment {
        DrawingEnvironment(makeSink: { self },
                           isTrusted: { self.isTrusted() },
                           isEscapeDown: { self.isEscape() },
                           sleep: { self.advance($0) },
                           now: { self.now() },
                           deliver: { DispatchQueue.main.async(execute: $0) })
    }
}

let testSpeed = SpeedSettings(stepSize: 4, eventDelay: 0.001, downDelay: 0.002, upDelay: 0.002, moveDelay: 0.002)
let bigRect = CGRect(x: 0, y: 0, width: 1000, height: 1000)

final class DrawingEngineTests: XCTestCase {
    struct RunResult {
        var outcome: DrawingEngine.Outcome
        var progress: [DrawingEngine.Progress]
        var completions: Int
        var events: [SyntheticMouseEvent]
    }

    func run(_ world: FakeWorld, _ strokes: [ScreenStroke], startingAt: Int = 0, clampRect: CGRect = bigRect,
             speed: SpeedSettings = testSpeed, configure: (DrawingEngine) -> Void = { _ in }) -> RunResult {
        let engine = DrawingEngine(speed: speed, environment: world.environment)
        configure(engine)
        var progress: [DrawingEngine.Progress] = []
        var outcomes: [DrawingEngine.Outcome] = []
        let done = expectation(description: "completion")
        engine.draw(strokes: strokes, startingAt: startingAt, clampRect: clampRect, progress: { p in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(outcomes.isEmpty, "progress after completion")
            progress.append(p)
        }, completion: { outcome in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertFalse(engine.isRunning, "isRunning must be false when completion runs")
            outcomes.append(outcome)
            done.fulfill()
        })
        XCTAssertTrue(engine.isRunning, "isRunning must be set synchronously")
        wait(for: [done], timeout: 10)
        // Give any (buggy) duplicate deliveries a chance to arrive.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(outcomes.count, 1, "completion must be called exactly once")
        return RunResult(outcome: outcomes.first ?? .completed, progress: progress, completions: outcomes.count,
                         events: world.events)
    }

    /// Structural invariants every event stream must satisfy.
    func assertWellFormed(_ events: [SyntheticMouseEvent], in rect: CGRect = bigRect,
                          file: StaticString = #filePath, line: UInt = #line) {
        var down = false
        for (i, e) in events.enumerated() {
            XCTAssertTrue(e.point.x >= rect.minX && e.point.x <= rect.maxX && e.point.y >= rect.minY && e.point.y <= rect.maxY,
                          "event \(i) \(e.point) outside clamp rect", file: file, line: line)
            switch e.kind {
            case .moved: XCTAssertFalse(down, "move while button down at \(i)", file: file, line: line)
            case .dragged: XCTAssertTrue(down, "drag while button up at \(i)", file: file, line: line)
            case .down: XCTAssertFalse(down, "double down at \(i)", file: file, line: line); down = true
            case .up: XCTAssertTrue(down, "up without down at \(i)", file: file, line: line); down = false
            }
        }
        XCTAssertFalse(down, "button left down", file: file, line: line)
    }

    // MARK: Sequencing

    func testStrokeSequence() {
        let world = FakeWorld()
        let r = run(world, [ScreenStroke(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 30, y: 10))])
        XCTAssertEqual(r.outcome, .completed)
        XCTAssertEqual(r.events.map(\.kind), [.moved, .down, .dragged, .dragged, .dragged, .dragged, .dragged, .up])
        XCTAssertEqual(r.events.map(\.point.x), [10, 10, 14, 18, 22, 26, 30, 30])
        XCTAssertEqual(r.events[2].deltaX, 4)
        XCTAssertEqual(r.events[2].deltaY, 0)
        // First move's delta is relative to where the cursor was.
        XCTAssertEqual(r.events[0].deltaX, 10 - 700)
        assertWellFormed(r.events)
    }

    func testDiagonalStrokeSpacingAndExactEnd() {
        let world = FakeWorld()
        let a = CGPoint(x: 100.25, y: 200.5), b = CGPoint(x: 137.75, y: 171.0)
        let r = run(world, [ScreenStroke(start: a, end: b)])
        XCTAssertEqual(r.outcome, .completed)
        let drags = r.events.filter { $0.kind == .dragged }.map(\.point)
        var prev = a
        for p in drags {
            XCTAssertLessThanOrEqual(Double(hypot(p.x - prev.x, p.y - prev.y)), 4 + 1e-9)
            prev = p
        }
        XCTAssertEqual(drags.last, b)
        XCTAssertEqual(r.events.last?.kind, .up)
        XCTAssertEqual(r.events.last?.point, b)
        assertWellFormed(r.events)
    }

    func testDotSequence() {
        let world = FakeWorld()
        let p = CGPoint(x: 50, y: 60)
        let r = run(world, [ScreenStroke(start: p, end: p)])
        XCTAssertEqual(r.outcome, .completed)
        XCTAssertEqual(r.events.map(\.kind), [.moved, .down, .dragged, .dragged, .up])
        XCTAssertEqual(r.events.map(\.point), [p, p, CGPoint(x: 50.5, y: 60), p, p])
    }

    func testDotAtRightEdgeWigglesInward() {
        let world = FakeWorld()
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let p = CGPoint(x: 100, y: 50)
        let r = run(world, [ScreenStroke(start: p, end: p)], clampRect: rect)
        XCTAssertEqual(r.events.map(\.point), [p, p, CGPoint(x: 99.5, y: 50), p, p])
        assertWellFormed(r.events, in: rect)
    }

    func testClamping() {
        let world = FakeWorld()
        let rect = CGRect(x: 10, y: 20, width: 100, height: 50)
        let strokes = [
            ScreenStroke(start: CGPoint(x: -50, y: 40), end: CGPoint(x: 500, y: 40)),
            ScreenStroke(start: CGPoint(x: 60, y: -10), end: CGPoint(x: 60, y: 900)),
            ScreenStroke(start: CGPoint(x: 9999, y: 9999), end: CGPoint(x: 9999, y: 9999)),
        ]
        let r = run(world, strokes, clampRect: rect)
        XCTAssertEqual(r.outcome, .completed)
        assertWellFormed(r.events, in: rect)
        XCTAssertEqual(r.events.first?.point, CGPoint(x: 10, y: 40))
        XCTAssertTrue(r.events.contains { $0.kind == .up && $0.point == CGPoint(x: 110, y: 40) })
        XCTAssertTrue(r.events.contains { $0.kind == .up && $0.point == CGPoint(x: 60, y: 70) })
        XCTAssertEqual(r.events.last?.point, CGPoint(x: 110, y: 70))
    }

    func testBetweenStrokesOnlyMovesAndCursorStaysAtEnd() {
        let world = FakeWorld()
        let strokes = [
            ScreenStroke(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 50, y: 10)),
            ScreenStroke(start: CGPoint(x: 50, y: 14), end: CGPoint(x: 10, y: 14)),
            ScreenStroke(start: CGPoint(x: 300, y: 300), end: CGPoint(x: 300, y: 300)),
        ]
        let r = run(world, strokes)
        XCTAssertEqual(r.outcome, .completed)
        assertWellFormed(r.events)
        XCTAssertEqual(r.events.filter { $0.kind == .down }.count, 3)
        XCTAssertEqual(r.events.filter { $0.kind == .up }.count, 3)
        // Nothing after the final mouse-up: the cursor is left where it is.
        XCTAssertEqual(r.events.last?.kind, .up)
        XCTAssertEqual(r.events.last?.point, CGPoint(x: 300, y: 300))
    }

    func testResumeStartsAtIndex() {
        let world = FakeWorld()
        let strokes = (0..<5).map { i in
            ScreenStroke(start: CGPoint(x: 10, y: 10 + 4 * Double(i)), end: CGPoint(x: 40, y: 10 + 4 * Double(i)))
        }
        let r = run(world, strokes, startingAt: 3)
        XCTAssertEqual(r.outcome, .completed)
        XCTAssertEqual(r.events.first?.point, strokes[3].start)
        XCTAssertEqual(r.events.filter { $0.kind == .down }.count, 2)
        XCTAssertEqual(r.progress.first, DrawingEngine.Progress(strokesDone: 3, strokesTotal: 5))
        XCTAssertEqual(r.progress.last, DrawingEngine.Progress(strokesDone: 5, strokesTotal: 5))
    }

    func testEmptyAndOutOfRangeStart() {
        XCTAssertEqual(run(FakeWorld(), []).outcome, .completed)
        let one = [ScreenStroke(start: .init(x: 1, y: 1), end: .init(x: 5, y: 1))]
        let r = run(FakeWorld(), one, startingAt: 7)
        XCTAssertEqual(r.outcome, .completed)
        XCTAssertTrue(r.events.isEmpty)
        XCTAssertEqual(r.progress.last, DrawingEngine.Progress(strokesDone: 1, strokesTotal: 1))
    }

    // MARK: Stop / pause / escape / permission

    func testRequestStopReleasesButton() {
        let world = FakeWorld()
        let engineBox = EngineBox()
        world.onPost = { i, _ in if i == 4 { engineBox.engine?.requestStop(reason: "User stop") } }
        let strokes = [ScreenStroke(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 90, y: 10)),
                       ScreenStroke(start: CGPoint(x: 10, y: 20), end: CGPoint(x: 90, y: 20))]
        let r = run(world, strokes) { engineBox.engine = $0 }
        XCTAssertEqual(r.outcome, .stopped(reason: "User stop"))
        assertWellFormed(r.events)
        XCTAssertEqual(r.events.count, 6) // moved, down, 3 drags, up
        XCTAssertEqual(r.events.last?.kind, .up)
        XCTAssertEqual(r.events.last?.point, r.events[4].point) // released at last posted point
        XCTAssertEqual(r.progress.last, DrawingEngine.Progress(strokesDone: 0, strokesTotal: 2))
    }

    func testStopWinsOverPause() {
        let world = FakeWorld()
        let engineBox = EngineBox()
        world.onPost = { i, _ in
            if i == 3 {
                engineBox.engine?.requestStop(reason: "S")
                engineBox.engine?.requestPause(reason: "P")
            }
        }
        let r = run(world, [ScreenStroke(start: .init(x: 10, y: 10), end: .init(x: 90, y: 10))]) { engineBox.engine = $0 }
        XCTAssertEqual(r.outcome, .stopped(reason: "S"))
        assertWellFormed(r.events)
    }

    func testRequestPauseGivesCurrentStroke() {
        let world = FakeWorld()
        let engineBox = EngineBox()
        let strokes = (0..<4).map { i in
            ScreenStroke(start: CGPoint(x: 10, y: 10 + 4 * Double(i)), end: CGPoint(x: 40, y: 10 + 4 * Double(i)))
        }
        // Stroke = moved, down, 8 drags, up = 11 events; pause during the 3rd stroke.
        world.onPost = { i, _ in if i == 25 { engineBox.engine?.requestPause() } }
        let r = run(world, strokes) { engineBox.engine = $0 }
        XCTAssertEqual(r.outcome, .paused(resumeIndex: 2, reason: "Paused"))
        assertWellFormed(r.events)
        XCTAssertEqual(r.progress.last, DrawingEngine.Progress(strokesDone: 2, strokesTotal: 4))
    }

    func testEscapeStops() {
        let world = FakeWorld()
        world.onPost = { i, _ in if i == 3 { world.setEscape(true) } }
        let r = run(world, [ScreenStroke(start: .init(x: 10, y: 10), end: .init(x: 90, y: 10))])
        XCTAssertEqual(r.outcome, .stopped(reason: DrawingEngine.Reason.escape))
        assertWellFormed(r.events)
        XCTAssertEqual(r.events.count, 5)
    }

    func testMissingPermissionPostsNothing() {
        let world = FakeWorld()
        world.trusted = false
        let r = run(world, [ScreenStroke(start: .init(x: 10, y: 10), end: .init(x: 90, y: 10))])
        XCTAssertEqual(r.outcome, .stopped(reason: "Accessibility permission is missing"))
        XCTAssertTrue(r.events.isEmpty)
    }

    func testPermissionLostMidDraw() {
        let world = FakeWorld()
        world.onPost = { i, _ in if i == 2 { world.setTrusted(false) } }
        // 0.1 s per drag → the 2 s re-check happens ~20 events later.
        let slow = SpeedSettings(stepSize: 4, eventDelay: 0.1, downDelay: 0.01, upDelay: 0.01, moveDelay: 0.01)
        let r = run(world, [ScreenStroke(start: .init(x: 0, y: 10), end: .init(x: 400, y: 10))], speed: slow)
        XCTAssertEqual(r.outcome, .stopped(reason: DrawingEngine.Reason.permissionLost))
        assertWellFormed(r.events)
        XCTAssertLessThan(r.events.count, 30)
    }

    func testInvalidClampRect() {
        let r = run(FakeWorld(), [ScreenStroke(start: .init(x: 1, y: 1), end: .init(x: 2, y: 1))], clampRect: .null)
        XCTAssertEqual(r.outcome, .stopped(reason: DrawingEngine.Reason.invalidCanvas))
        XCTAssertTrue(r.events.isEmpty)
    }

    func testDrawWhileRunningIsIgnored() {
        let world = FakeWorld()
        let engine = DrawingEngine(speed: testSpeed, environment: world.environment)
        var completions = 0
        var secondCalled = false
        let done = expectation(description: "done")
        let strokes = [ScreenStroke(start: .init(x: 10, y: 10), end: .init(x: 200, y: 10))]
        engine.draw(strokes: strokes, clampRect: bigRect, progress: { _ in }, completion: { _ in completions += 1; done.fulfill() })
        engine.draw(strokes: strokes, clampRect: bigRect, progress: { _ in }, completion: { _ in secondCalled = true })
        wait(for: [done], timeout: 10)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(completions, 1)
        XCTAssertFalse(secondCalled)
        XCTAssertEqual(world.events.filter { $0.kind == .down }.count, 1)
    }

    // MARK: User movement

    func testPauseOnUserMovement() {
        let world = FakeWorld()
        let strokes = (0..<3).map { i in
            ScreenStroke(start: CGPoint(x: 100, y: 100 + 4 * Double(i)), end: CGPoint(x: 140, y: 100 + 4 * Double(i)))
        }
        // Stroke = moved, down, 10 drags, up = 13 events. Event 16 = 2nd drag of stroke 1.
        world.onPost = { i, _ in if i == 16 { world.setUserOffset(CGVector(dx: 0, dy: 40)) } }
        let r = run(world, strokes)
        XCTAssertEqual(r.outcome, .paused(resumeIndex: 1, reason: "Mouse moved"))
        assertWellFormed(r.events)
        XCTAssertEqual(r.events.count, 19) // ...+ drag to user's spot + up
        let userSpot = CGPoint(x: r.events[16].point.x, y: r.events[16].point.y + 40)
        XCTAssertEqual(r.events.last, SyntheticMouseEvent(kind: .up, point: userSpot, deltaX: 0, deltaY: 0))
        XCTAssertEqual(r.progress.last, DrawingEngine.Progress(strokesDone: 1, strokesTotal: 3))
    }

    func testUserMovementWhileHoveringPausesWithoutButtonEvents() {
        let world = FakeWorld()
        let strokes = [ScreenStroke(start: CGPoint(x: 100, y: 100), end: CGPoint(x: 120, y: 100)),
                       ScreenStroke(start: CGPoint(x: 300, y: 300), end: CGPoint(x: 320, y: 300))]
        // Stroke 0 = moved, down, 5 drags, up (events 0-7). Event 8 = hover move to stroke 1's start.
        world.onPost = { i, e in if i == 8 { XCTAssertEqual(e.kind, .moved); world.setUserOffset(CGVector(dx: 25, dy: 25)) } }
        let r = run(world, strokes)
        XCTAssertEqual(r.outcome, .paused(resumeIndex: 1, reason: "Mouse moved"))
        XCTAssertEqual(r.events.count, 9)
        assertWellFormed(r.events)
    }

    func testRepeatedSmallUserNudgesPause() {
        let world = FakeWorld()
        let strokes = [ScreenStroke(start: CGPoint(x: 100, y: 100), end: CGPoint(x: 300, y: 100))]
        world.onPost = { i, _ in if (10...12).contains(i) { world.setUserOffset(CGVector(dx: 0, dy: 6)) } }
        let r = run(world, strokes)
        XCTAssertEqual(r.outcome, .paused(resumeIndex: 0, reason: "Mouse moved"))
        assertWellFormed(r.events)
    }

    func testSingleSmallNudgeDoesNotPause() {
        let world = FakeWorld()
        let strokes = [ScreenStroke(start: CGPoint(x: 100, y: 100), end: CGPoint(x: 300, y: 100))]
        world.onPost = { i, _ in if i == 10 { world.setUserOffset(CGVector(dx: 0, dy: 6)) } }
        XCTAssertEqual(run(world, strokes).outcome, .completed)
    }

    func testPauseDisabledIgnoresMovement() {
        let world = FakeWorld()
        let strokes = [ScreenStroke(start: CGPoint(x: 100, y: 100), end: CGPoint(x: 200, y: 100))]
        world.onPost = { i, _ in if i == 5 { world.setUserOffset(CGVector(dx: 0, dy: 50)) } }
        let r = run(world, strokes) { $0.pauseOnUserMouseMove = false }
        XCTAssertEqual(r.outcome, .completed)
    }

    /// A realistic picture: serpentine rows plus far jumps between runs.
    func manyStrokes() -> [ScreenStroke] {
        var s: [ScreenStroke] = []
        for row in 0..<40 {
            let y = 50 + Double(row) * 4.0
            let x0 = 30.0 + Double((row * 37) % 50), x1 = 600.0 - Double((row * 53) % 200)
            s.append(row % 2 == 0 ? ScreenStroke(start: .init(x: x0, y: y), end: .init(x: x1, y: y))
                                  : ScreenStroke(start: .init(x: x1, y: y), end: .init(x: x0, y: y)))
            if row % 5 == 0 { s.append(ScreenStroke(start: .init(x: 900, y: 900 - y), end: .init(x: 900, y: 900 - y))) }
        }
        return s
    }

    func testNoFalsePauseFromOwnMotionWithLag() {
        for lag in [0, 1, 2, 3, 8, 20] {
            let world = FakeWorld()
            world.lag = lag
            let r = run(world, manyStrokes(), speed: .ludicrous)
            XCTAssertEqual(r.outcome, .completed, "lag \(lag)")
            assertWellFormed(r.events)
        }
    }

    func testNoFalsePauseWithRounding() {
        for rounding: CGFloat in [0.5, 1] {
            let world = FakeWorld()
            world.rounding = rounding
            world.lag = 1
            XCTAssertEqual(run(world, manyStrokes(), speed: .normal).outcome, .completed, "rounding \(rounding)")
        }
    }

    func testDroppedEventsAreReported() {
        let world = FakeWorld(cursor: CGPoint(x: 900, y: 50))
        world.ignoreEvents = true
        let r = run(world, manyStrokes())
        XCTAssertEqual(r.outcome, .stopped(reason: DrawingEngine.Reason.eventsIgnored))
        assertWellFormed(r.events)
    }

    /// Steady, moderate movement only ever shows up as ~2 pt per read (each of our absolute
    /// events puts the cursor back), below every per-read threshold; it must still pause.
    func testSteadyModerateUserMotionMidStrokePauses() {
        let world = FakeWorld()
        world.userVelocity = CGVector(dx: 0, dy: 700) // 2.1 pt per 3 ms read
        world.userVelocityFrom = 20
        let strokes = [ScreenStroke(start: CGPoint(x: 100, y: 100), end: CGPoint(x: 900, y: 100))]
        let r = run(world, strokes, speed: .normal)
        XCTAssertEqual(r.outcome, .paused(resumeIndex: 0, reason: DrawingEngine.Reason.mouseMoved))
        XCTAssertLessThan(r.events.count, 40, "should pause within a few events of the motion starting")
        assertWellFormed(r.events)
    }

    /// Moving back along the stroke lies on our own path, so it looks like window-server lag at a
    /// glance; lag only ever catches up forwards, so a cursor sliding backwards is the user.
    func testUserMotionBackAlongStrokePauses() {
        let world = FakeWorld()
        world.userVelocity = CGVector(dx: -600, dy: 0)
        world.userVelocityFrom = 30
        let strokes = [ScreenStroke(start: CGPoint(x: 100, y: 100), end: CGPoint(x: 900, y: 100))]
        let r = run(world, strokes, speed: .normal)
        XCTAssertEqual(r.outcome, .paused(resumeIndex: 0, reason: DrawingEngine.Reason.mouseMoved))
        XCTAssertLessThan(r.events.count, 60)
        assertWellFormed(r.events)
    }

    /// A window server that stays several events behind for more than one read is still lag.
    func testNoFalsePauseWhenWindowServerStaysBehind() {
        for lag in [6, 8, 12] {
            let world = FakeWorld()
            world.lag = lag
            world.lagReads = 2
            let r = run(world, manyStrokes(), speed: .normal)
            XCTAssertEqual(r.outcome, .completed, "lag \(lag)")
            assertWellFormed(r.events)
        }
    }

    func testDroppedEventsReportedWhenFirstStrokeStartsAtCursor() {
        let strokes = manyStrokes()
        let world = FakeWorld(cursor: strokes[0].start)
        world.ignoreEvents = true
        let r = run(world, strokes)
        XCTAssertEqual(r.outcome, .stopped(reason: DrawingEngine.Reason.eventsIgnored))
        assertWellFormed(r.events)
    }

    func testDroppedEventsReportedWithPauseDisabled() {
        let world = FakeWorld(cursor: CGPoint(x: 900, y: 50))
        world.ignoreEvents = true
        let r = run(world, manyStrokes()) { $0.pauseOnUserMouseMove = false }
        XCTAssertEqual(r.outcome, .stopped(reason: DrawingEngine.Reason.eventsIgnored))
    }

    /// The cursor not following for the first ~0.1 s (busy window server, Space switch) must
    /// not be mistaken for dropped events.
    func testSlowStartIsNotReportedAsDroppedEvents() {
        for speed in [SpeedSettings.normal, .ludicrous] {
            let world = FakeWorld(cursor: CGPoint(x: 900, y: 50))
            world.ignoreEventsUntil = 1000 + 0.1
            let r = run(world, manyStrokes(), speed: speed)
            XCTAssertEqual(r.outcome, .completed)
        }
    }

    // MARK: Progress

    func testProgressThrottledAndFinal() {
        let world = FakeWorld()
        let strokes = manyStrokes()
        // 0.1 ms of (fake) time per event: several strokes per 1/30 s.
        let r = run(world, strokes, speed: SpeedSettings(stepSize: 16, eventDelay: 0.0001, downDelay: 0.0001, upDelay: 0.0001, moveDelay: 0.0001))
        XCTAssertEqual(r.outcome, .completed)
        XCTAssertEqual(r.progress.last, DrawingEngine.Progress(strokesDone: strokes.count, strokesTotal: strokes.count))
        XCTAssertLessThan(r.progress.count, strokes.count / 2)
        XCTAssertEqual(r.progress.map(\.strokesDone), r.progress.map(\.strokesDone).sorted())
    }
}

final class EngineBox: @unchecked Sendable {
    weak var engine: DrawingEngine?
}

final class MouseDriverTests: XCTestCase {
    func testReleaseIfNeededAndDragWhileUp() {
        let world = FakeWorld()
        let d = MouseDriver(speed: testSpeed, sink: world)
        d.releaseIfNeeded()
        XCTAssertTrue(world.events.isEmpty)
        d.drag(to: CGPoint(x: 5, y: 5)) // button up → plain move
        XCTAssertEqual(world.events.last?.kind, .moved)
        d.mouseDown(at: CGPoint(x: 5, y: 5))
        XCTAssertTrue(d.isButtonDown)
        d.move(to: CGPoint(x: 9, y: 5)) // button down → drag
        XCTAssertEqual(world.events.last?.kind, .dragged)
        d.releaseIfNeeded()
        XCTAssertEqual(world.events.last, SyntheticMouseEvent(kind: .up, point: CGPoint(x: 9, y: 5), deltaX: 0, deltaY: 0))
        XCTAssertFalse(d.isButtonDown)
        d.releaseIfNeeded()
        XCTAssertEqual(world.events.count, 4)
    }

    func testDriverClampRect() {
        let world = FakeWorld()
        let d = MouseDriver(speed: testSpeed, sink: world)
        d.clampRect = CGRect(x: 0, y: 0, width: 10, height: 10)
        d.move(to: CGPoint(x: -5, y: 50))
        XCTAssertEqual(d.lastPostedLocation, CGPoint(x: 0, y: 10))
    }

    func testClampHandlesNonFinite() {
        let r = CGRect(x: 10, y: 10, width: 20, height: 20)
        XCTAssertEqual(MouseDriver.clamp(CGPoint(x: CGFloat.nan, y: 100), to: r), CGPoint(x: 20, y: 30))
        XCTAssertEqual(MouseDriver.clamp(CGPoint(x: 15, y: 15), to: r), CGPoint(x: 15, y: 15))
        XCTAssertEqual(MouseDriver.clamp(CGPoint(x: 30, y: 30), to: r), CGPoint(x: 30, y: 30))
    }
}

final class WindowInspectorTests: XCTestCase {
    func w(_ id: CGWindowID, pid: pid_t, _ owner: String, _ r: CGRect, layer: Int = 0, alpha: Double = 1) -> OnScreenWindow {
        OnScreenWindow(windowID: id, pid: pid, ownerName: owner, bounds: r, layer: layer, alpha: alpha)
    }

    func testFilterEligible() {
        let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let list = [
            w(1, pid: 1, "Window Server", CGRect(x: 0, y: 0, width: 1728, height: 33), layer: 24),
            w(2, pid: 2, "Dock", display, layer: 20),
            w(3, pid: 2, "Dock", CGRect(x: 400, y: 1050, width: 900, height: 67), layer: 20),
            w(4, pid: 3, "Overlay", CGRect(x: 0, y: 0, width: 500, height: 500), alpha: 0.01),
            w(5, pid: 3, "Tiny", CGRect(x: 0, y: 0, width: 2, height: 2)),
            w(6, pid: 4, "Paint", CGRect(x: 0, y: 33, width: 1728, height: 1084)),
            w(7, pid: 5, "Status", CGRect(x: 0, y: 0, width: 100, height: 30), layer: 25),
            w(8, pid: 9, "Window Server", CGRect(x: 0, y: 0, width: 100, height: 100), layer: 0),
        ]
        let ids = WindowInspector.filterEligible(list, displays: [display]).map(\.windowID)
        XCTAssertEqual(ids, [3, 6])
    }

    func testParse() {
        let info: [[String: Any]] = [[
            kCGWindowNumber as String: NSNumber(value: 42),
            kCGWindowOwnerPID as String: NSNumber(value: 77),
            kCGWindowOwnerName as String: "Paint",
            kCGWindowBounds as String: CGRect(x: 1, y: 2, width: 300, height: 400).dictionaryRepresentation,
            kCGWindowLayer as String: NSNumber(value: 0),
            kCGWindowAlpha as String: NSNumber(value: 1.0),
        ], [kCGWindowNumber as String: NSNumber(value: 1)]]
        XCTAssertEqual(WindowInspector.parse(info),
                       [OnScreenWindow(windowID: 42, pid: 77, ownerName: "Paint", bounds: CGRect(x: 1, y: 2, width: 300, height: 400), layer: 0, alpha: 1)])
    }

    func testSamplePointsInsideCanvas() {
        let canvas = CGRect(x: 100, y: 100, width: 600, height: 300)
        let pts = WindowInspector.samplePoints(in: canvas)
        XCTAssertEqual(pts.count, 49)
        XCTAssertEqual(pts.first, CGPoint(x: 102, y: 102))
        XCTAssertEqual(pts.last, CGPoint(x: 698, y: 398))
        XCTAssertTrue(pts.allSatisfy { canvas.contains($0) })
    }

    func testObstructions() {
        let canvas = CGRect(x: 100, y: 100, width: 600, height: 600)
        let windows = [
            w(10, pid: 50, "Colors", CGRect(x: 90, y: 90, width: 200, height: 200), layer: 3), // covers a corner
            w(11, pid: 50, "Colors", CGRect(x: 2000, y: 2000, width: 50, height: 50)),          // elsewhere
            w(12, pid: 40, "Paint", CGRect(x: 0, y: 0, width: 1000, height: 1000)),
            w(13, pid: 60, "Behind", CGRect(x: 0, y: 0, width: 1000, height: 1000)),
        ]
        let obs = WindowInspector.obstructions(in: windows, canvas: canvas, targetPID: 40)
        XCTAssertEqual(obs.map(\.windowID), [10])
        XCTAssertTrue(WindowInspector.obstructions(in: Array(windows.dropFirst()), canvas: canvas, targetPID: 40).isEmpty)
    }

    func testTargetAppFloatingPaletteOverCanvasIsAnObstruction() {
        let canvas = CGRect(x: 100, y: 100, width: 600, height: 600)
        let palette = w(20, pid: 40, "Paint", CGRect(x: 500, y: 500, width: 300, height: 300), layer: 3)
        let doc = w(21, pid: 40, "Paint", CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let tooltipElsewhere = w(22, pid: 40, "Paint", CGRect(x: 1500, y: 0, width: 100, height: 20), layer: 3)
        XCTAssertEqual(WindowInspector.obstructions(in: [tooltipElsewhere, palette, doc], canvas: canvas, targetPID: 40).map(\.windowID), [20])
        // The canvas window itself never counts, whatever its layer.
        XCTAssertTrue(WindowInspector.obstructions(in: [doc], canvas: canvas, targetPID: 40).isEmpty)
        let floatingCanvas = w(23, pid: 40, "Paint", CGRect(x: 0, y: 0, width: 1000, height: 1000), layer: 3)
        XCTAssertTrue(WindowInspector.obstructions(in: [floatingCanvas], canvas: canvas, targetPID: 40).isEmpty)
    }

    func testTargetWindowPrefersNormalWindowsAndSkipsOwnPanels() {
        let canvas = CGRect(x: 100, y: 100, width: 400, height: 400) // centre (300, 300)
        let own: pid_t = 99
        let windows = [
            w(1, pid: own, "DrawBot", CGRect(x: 0, y: 0, width: 800, height: 800), layer: 3),   // our floating panel
            w(2, pid: own, "DrawBot", CGRect(x: 0, y: 0, width: 800, height: 800)),             // click-through
            w(3, pid: 70, "NotificationCenter", CGRect(x: 200, y: 200, width: 300, height: 200), layer: 23),
            w(4, pid: 40, "Paint", CGRect(x: 0, y: 0, width: 1000, height: 1000)),
        ]
        XCTAssertEqual(WindowInspector.targetWindow(in: windows, canvas: canvas, ownPID: own, ownClickThrough: [2])?.windowID, 4)
        // Our own normal window (the Test Canvas) is a valid target.
        XCTAssertEqual(WindowInspector.targetWindow(in: windows, canvas: canvas, ownPID: own, ownClickThrough: [])?.windowID, 2)
        // Only a floating window there: use it rather than nothing.
        XCTAssertEqual(WindowInspector.targetWindow(in: [windows[2]], canvas: canvas, ownPID: own, ownClickThrough: [])?.windowID, 3)
        XCTAssertNil(WindowInspector.targetWindow(in: [windows[0]], canvas: canvas, ownPID: own, ownClickThrough: []))
    }

    func testLiveWindowListDoesNotCrash() {
        // Read-only query of the real window list; asserts only basic sanity.
        let all = WindowInspector.onScreenWindows()
        XCTAssertTrue(all.allSatisfy { $0.layer < 24 && $0.alpha >= 0.05 })
        _ = WindowInspector.topWindow(at: CGPoint(x: 10, y: 100))
        _ = WindowInspector.obstructions(of: CGRect(x: 100, y: 100, width: 50, height: 50), targetPID: 1)
    }
}
