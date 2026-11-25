import Carbon.HIToolbox
import CoreGraphics
import DrawBotCore
import Darwin
import Foundation

/// Plays strokes as synthetic press-drag-release gestures on a dedicated worker thread.
///
/// Threading: call `draw` from the main thread (`isRunning` is main-thread state). `speed`,
/// `pauseOnUserMouseMove` and `userMoveThreshold` are snapshotted when `draw` is called; changing
/// them mid-run affects the next run only. `requestStop` / `requestPause` may be called from any
/// thread.
///
/// Progress: `strokesDone` / `strokesTotal` are ABSOLUTE indices into the `strokes` array (so a
/// resumed run continues from `startingAt`, not 0). The final progress callback (always sent,
/// right before completion) carries `strokes.count` when completed, or the index of the
/// interrupted stroke when paused / stopped.
///
/// User-movement detection: every posted mouse event carries an absolute position, so the
/// physical mouse's motion is wiped out by our next event; all we ever see is how far the user
/// moved the cursor since our LAST post (a few ms). So before every posted event the real cursor
/// is compared with the last few points WE posted (as points, not as a polyline: the window
/// server only ever shows a point it was given, so lag lands exactly on one of them, while a
/// user moving along the stroke does not). A deviation > `userMoveThreshold`, three > max(3,
/// threshold/3) within 0.5 s, or deviations > 1.5 pt adding up to more than the threshold within
/// 0.3 s (steady slow movement) trigger a CONFIRMATION: the cursor is re-read every 30 ms (up to
/// 4×) with nothing posted. Lag resolves to our last segment, or to one of our ~32 recent points
/// moving forward along our path; only a cursor that is off all of them (or moving backwards
/// along them) pauses the run. The button is then released where the user's cursor is
/// (clamped). If the cursor never once reached any point we posted and stays where it was before
/// the run for 0.25 s, macOS is dropping our events (typically a stale Accessibility grant after
/// a rebuild); that finishes `.stopped(eventsIgnored)` instead of a misleading "Mouse moved". That
/// diagnosis runs even when `pauseOnUserMouseMove` is off (until our events are seen to land).
///
/// While a run is active the process holds a user-initiated, latency-critical activity (no App
/// Nap timer throttling, no idle display sleep / screen saver eating the clicks).
public final class DrawingEngine {
    public enum Outcome: Equatable {
        /// Every stroke was drawn.
        case completed
        /// Stopped for good (Escape pressed, requestStop(), permission lost…).
        case stopped(reason: String)
        /// Interrupted but resumable: call draw again with startingAt: resumeIndex.
        /// The interrupted stroke is redrawn in full on resume (harmless — same color).
        case paused(resumeIndex: Int, reason: String)
    }

    public struct Progress: Equatable {
        public let strokesDone: Int
        public let strokesTotal: Int
        public init(strokesDone: Int, strokesTotal: Int) { self.strokesDone = strokesDone; self.strokesTotal = strokesTotal }
        public var fraction: Double { strokesTotal == 0 ? 1 : Double(strokesDone) / Double(strokesTotal) }
    }

    /// Reasons used in outcomes (stable strings, so the UI may match on them if it wants).
    public enum Reason {
        public static let escape = "Escape pressed"
        public static let mouseMoved = "Mouse moved"
        public static let permissionMissing = "Accessibility permission is missing"
        public static let permissionLost = "Accessibility permission was turned off"
        public static let eventsIgnored = "macOS ignored DrawBot's mouse events. In System Settings → Privacy & Security → Accessibility, remove DrawBot, add it again, then relaunch DrawBot."
        public static let invalidCanvas = "Invalid canvas rectangle"
    }

    public var speed: SpeedSettings
    /// Pause when the physical mouse moves the cursor away from where we put it.
    public var pauseOnUserMouseMove: Bool = true
    /// Distance in points between expected and actual cursor that counts as user movement.
    public var userMoveThreshold: Double = 12
    public private(set) var isRunning: Bool = false

    let environment: DrawingEnvironment
    private let controlLock = NSLock()
    private var currentControl: RunControl? // guarded by controlLock

    public init(speed: SpeedSettings) {
        self.speed = speed
        self.environment = .live
    }

    init(speed: SpeedSettings, environment: DrawingEnvironment) {
        self.speed = speed
        self.environment = environment
    }

    /// Draws strokes[startingAt...] on a dedicated background thread. Every posted point is
    /// clamped into `clampRect` (CG global). Polls Escape (→ .stopped) and user mouse movement
    /// (→ .paused). Always leaves the mouse button released. `progress` (throttled, ≤ 30 Hz) and
    /// `completion` (exactly once) are called on the main queue. Calling draw while running is a
    /// programming error and is ignored.
    public func draw(strokes: [ScreenStroke], startingAt: Int = 0, clampRect: CGRect,
                     progress: @escaping (Progress) -> Void,
                     completion: @escaping (Outcome) -> Void) {
        guard !isRunning else { return }
        isRunning = true

        let control = RunControl()
        controlLock.lock()
        currentControl = control
        controlLock.unlock()

        let config = RunConfig(strokes: strokes,
                               startIndex: min(max(0, startingAt), strokes.count),
                               clampRect: clampRect,
                               speed: DrawingEngine.sanitized(speed),
                               pauseOnUserMouseMove: pauseOnUserMouseMove,
                               userMoveThreshold: userMoveThreshold.isFinite ? max(2, userMoveThreshold) : 12)
        let env = environment
        let finish: (Outcome) -> Void = { [self] outcome in
            env.deliver { [self] in
                controlLock.lock()
                if currentControl === control { currentControl = nil }
                controlLock.unlock()
                isRunning = false
                completion(outcome)
            }
        }
        let thread = Thread {
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled],
                reason: "DrawBot is drawing")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let worker = DrawingWorker(config: config, control: control, env: env, progress: progress)
            let outcome = worker.run()
            finish(outcome)
        }
        thread.name = "DrawBot.DrawingEngine"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Thread-safe. Finishes with .stopped(reason) as soon as the current event is posted.
    public func requestStop(reason: String = "Stopped") {
        controlLock.lock()
        let control = currentControl
        controlLock.unlock()
        control?.request(.stop(reason))
    }

    /// Thread-safe. Finishes with .paused(resumeIndex: current stroke, reason).
    public func requestPause(reason: String = "Paused") {
        controlLock.lock()
        let control = currentControl
        controlLock.unlock()
        control?.request(.pause(reason))
    }

    static func sanitized(_ s: SpeedSettings) -> SpeedSettings {
        func delay(_ d: Double) -> Double { d.isFinite ? min(max(0, d), 1) : 0 }
        let step = s.stepSize.isFinite && s.stepSize > 0 ? max(0.5, s.stepSize) : 4
        return SpeedSettings(stepSize: step, eventDelay: delay(s.eventDelay), downDelay: delay(s.downDelay),
                             upDelay: delay(s.upDelay), moveDelay: delay(s.moveDelay), endDelay: delay(s.endDelay))
    }
}

// MARK: - Environment seam (internal; tests inject fakes so no real events are posted)

struct DrawingEnvironment {
    var makeSink: () -> MouseEventSink
    var isTrusted: () -> Bool
    var isEscapeDown: () -> Bool
    /// Precise sleep, seconds.
    var sleep: (TimeInterval) -> Void
    /// Monotonic clock, seconds.
    var now: () -> TimeInterval
    /// Runs a block asynchronously on the main queue.
    var deliver: (@escaping () -> Void) -> Void

    static var live: DrawingEnvironment {
        DrawingEnvironment(
            makeSink: { CGEventPostingSink() },
            isTrusted: { Permissions.isAccessibilityTrusted },
            isEscapeDown: { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Escape)) },
            sleep: { PreciseClock.sleep($0) },
            now: { PreciseClock.now() },
            deliver: { DispatchQueue.main.async(execute: $0) })
    }
}

enum PreciseClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func now() -> TimeInterval {
        let t = mach_absolute_time()
        return Double(t) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    /// Sleeps until `seconds` have elapsed (mach_wait_until; resumes after spurious wake-ups).
    static func sleep(_ seconds: TimeInterval) {
        guard seconds > 0, seconds.isFinite else { return }
        let ticks = UInt64(seconds * 1e9 * Double(timebase.denom) / Double(timebase.numer))
        let deadline = mach_absolute_time() &+ ticks
        while mach_absolute_time() < deadline {
            mach_wait_until(deadline)
        }
    }
}

// MARK: - Run state

struct RunConfig {
    let strokes: [ScreenStroke]
    let startIndex: Int
    let clampRect: CGRect
    let speed: SpeedSettings
    let pauseOnUserMouseMove: Bool
    let userMoveThreshold: Double
}

/// Stop/pause flags shared between the main thread and the worker. Stop wins over pause.
final class RunControl: @unchecked Sendable { // all state behind `lock`
    enum Request: Equatable {
        case stop(String)
        case pause(String)
    }

    private let lock = NSLock()
    private var pending: Request?

    func request(_ r: Request) {
        lock.lock()
        defer { lock.unlock() }
        switch (pending, r) {
        case (.stop?, _): break // a stop is final
        default: pending = r
        }
    }

    func current() -> Request? {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }
}

private enum Interrupt: Error {
    case stop(String)
    case pause(String)
    /// Confirmed user movement; associated value is where the user's cursor is.
    case userMoved(CGPoint)
    case eventsIgnored
}

/// Runs on the worker thread only.
private final class DrawingWorker {
    let config: RunConfig
    let control: RunControl
    let env: DrawingEnvironment
    let progressHandler: (DrawingEngine.Progress) -> Void
    let driver: MouseDriver
    let sink: MouseEventSink

    // Movement detection state
    private var history: [CGPoint] = [] // last posted points, oldest first (≤ historyLength)
    /// Points kept for recognizing window-server lag while confirming.
    private static let historyLength = 32
    /// Points the cursor may lag behind by without even triggering a confirmation.
    private static let recentLength = 6
    /// Deviations at or below this are rounding / edge-constraint noise, never accumulated.
    private static let noiseFloor = 1.5
    private static let accumulationWindow: TimeInterval = 0.3
    private static let confirmInterval: TimeInterval = 0.03
    private static let confirmChecks = 4
    /// How long the cursor must stay at its pre-run spot before we conclude events are dropped.
    private static let eventsIgnoredAfter: TimeInterval = 0.25
    private var initialCursor: CGPoint?
    private var sawOwnEvent = false
    private var minorHits: [TimeInterval] = []
    private var excess: [(t: TimeInterval, d: Double)] = []

    private var lastPermissionCheck: TimeInterval = 0
    private var lastProgress: TimeInterval = -.infinity

    init(config: RunConfig, control: RunControl, env: DrawingEnvironment,
         progress: @escaping (DrawingEngine.Progress) -> Void) {
        self.config = config
        self.control = control
        self.env = env
        self.progressHandler = progress
        self.sink = env.makeSink()
        self.driver = MouseDriver(speed: config.speed, sink: sink)
    }

    func run() -> DrawingEngine.Outcome {
        let total = config.strokes.count
        var index = config.startIndex
        let outcome: DrawingEngine.Outcome

        let rect = config.clampRect.standardized
        if rect.isNull || rect.isInfinite || !rect.minX.isFinite || !rect.minY.isFinite
            || !rect.maxX.isFinite || !rect.maxY.isFinite {
            outcome = .stopped(reason: DrawingEngine.Reason.invalidCanvas)
        } else if !env.isTrusted() {
            outcome = .stopped(reason: DrawingEngine.Reason.permissionMissing)
        } else {
            driver.clampRect = rect
            lastPermissionCheck = env.now()
            initialCursor = sink.cursorLocation()
            if let c = initialCursor { history = [c] }
            report(done: index, force: false)
            do {
                while index < total {
                    try drawStroke(config.strokes[index])
                    index += 1
                    report(done: index, force: false)
                }
                outcome = .completed
            } catch let interrupt as Interrupt {
                switch interrupt {
                case .stop(let reason):
                    driver.releaseIfNeeded()
                    outcome = .stopped(reason: reason)
                case .pause(let reason):
                    driver.releaseIfNeeded()
                    outcome = .paused(resumeIndex: index, reason: reason)
                case .userMoved(let actual):
                    // Release where the user's cursor is, so the app doesn't get a drag back.
                    if driver.isButtonDown { driver.mouseUp(at: actual) }
                    outcome = .paused(resumeIndex: index, reason: DrawingEngine.Reason.mouseMoved)
                case .eventsIgnored:
                    driver.releaseIfNeeded()
                    outcome = .stopped(reason: DrawingEngine.Reason.eventsIgnored)
                }
            } catch {
                driver.releaseIfNeeded()
                outcome = .stopped(reason: "\(error)")
            }
        }
        driver.releaseIfNeeded() // belt and braces: never leave the button down
        report(done: index, force: true)
        return outcome
    }

    // MARK: Strokes

    private func drawStroke(_ stroke: ScreenStroke) throws {
        let rect = config.clampRect.standardized
        let path = stroke.points.map { MouseDriver.clamp($0, to: rect) }
        let a = path[0]
        let b = path[path.count - 1]
        let s = config.speed

        try checkpoint()
        driver.move(to: a)
        posted()
        env.sleep(s.moveDelay)

        try checkpoint()
        driver.mouseDown(at: a)
        posted()
        env.sleep(s.downDelay)

        if stroke.isDot || path.allSatisfy({ $0 == a }) {
            // Many apps ignore a down/up with no motion: wiggle half a point and come back.
            var q = MouseDriver.clamp(CGPoint(x: a.x + 0.5, y: a.y), to: rect)
            if q == a { q = MouseDriver.clamp(CGPoint(x: a.x - 0.5, y: a.y), to: rect) }
            for p in [q, a] {
                try checkpoint()
                driver.drag(to: p)
                posted()
                env.sleep(s.eventDelay)
            }
        } else {
            // Each straight segment in steps of at most stepSize, landing exactly on every corner.
            for i in 1..<path.count {
                let from = path[i - 1], to = path[i]
                let length = Double(hypot(to.x - from.x, to.y - from.y))
                guard length > 0 else { continue }
                let n = max(1, Int((length / s.stepSize).rounded(.up)))
                for k in 1...n {
                    let p: CGPoint
                    if k == n {
                        p = to
                    } else {
                        let t = CGFloat(k) / CGFloat(n)
                        p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                    }
                    try checkpoint()
                    driver.drag(to: p)
                    posted()
                    env.sleep(s.eventDelay)
                }
                // Hold each corner for a frame: apps read the pointer once per frame and join
                // the positions with straight lines, so without the pause a fast pen would cut
                // the corner (and paint across a neighboring color).
                if i < path.count - 1 { env.sleep(s.endDelay) }
            }
        }

        env.sleep(s.endDelay)
        try checkpoint()
        driver.mouseUp(at: b)
        posted()
        env.sleep(s.upDelay)
    }

    // MARK: Checks

    private func checkpoint() throws {
        switch control.current() {
        case .stop(let reason)?: throw Interrupt.stop(reason)
        case .pause(let reason)?: throw Interrupt.pause(reason)
        case nil: break
        }
        if env.isEscapeDown() { throw Interrupt.stop(DrawingEngine.Reason.escape) }
        let t = env.now()
        if t - lastPermissionCheck >= 2 {
            lastPermissionCheck = t
            if !env.isTrusted() { throw Interrupt.stop(DrawingEngine.Reason.permissionLost) }
        }
        // With pausing off, keep checking only until our events are seen to land (dropped-events
        // diagnosis).
        if config.pauseOnUserMouseMove || !sawOwnEvent { try checkUserMovement(now: t) }
    }

    private func posted() {
        guard let p = driver.lastPostedLocation else { return }
        history.append(p)
        if history.count > DrawingWorker.historyLength { history.removeFirst(history.count - DrawingWorker.historyLength) }
    }

    private func checkUserMovement(now t: TimeInterval) throws {
        guard driver.lastPostedLocation != nil, let actual = sink.cursorLocation() else { return }
        noteOwnEvent(actual)
        let deviation = DrawingWorker.distance(from: actual, toNearestOf: history.suffix(DrawingWorker.recentLength))
        let threshold = config.userMoveThreshold
        let minor = max(3, threshold / 3)
        if deviation > threshold {
            try confirmUserMovement()
            return
        }
        if deviation > minor {
            minorHits.append(t)
            minorHits.removeAll { t - $0 > 0.5 }
            if minorHits.count >= 3 {
                try confirmUserMovement()
                return
            }
        }
        if deviation > DrawingWorker.noiseFloor {
            excess.append((t, deviation))
            excess.removeAll { t - $0.t > DrawingWorker.accumulationWindow }
            if excess.reduce(0, { $0 + $1.d }) > threshold { try confirmUserMovement() }
        }
    }

    /// Records that the cursor sits on one of our posted points. A point within 1.5 pt of where the
    /// cursor was before the run proves nothing (a run may start right where the cursor is).
    private func noteOwnEvent(_ p: CGPoint) {
        guard !sawOwnEvent, DrawingWorker.distance(from: p, toNearestOf: history[...]) <= 1.5 else { return }
        if let initial = initialCursor, distance(p, initial) <= 1.5 { return }
        sawOwnEvent = true
    }

    private func clearHits() {
        minorHits.removeAll()
        excess.removeAll()
    }

    /// Re-reads the cursor with nothing posted, giving the window server time to catch up. Throws
    /// only if the cursor is off our recent path (or moving backwards along it), or never left its
    /// pre-run spot (events dropped).
    private func confirmUserMovement() throws {
        var waited: TimeInterval = 0
        var checks = 0
        var lastMatch = -1
        while true {
            env.sleep(DrawingWorker.confirmInterval)
            waited += DrawingWorker.confirmInterval
            checks += 1
            guard let last = driver.lastPostedLocation, let again = sink.cursorLocation() else { return }
            let prev = history.count >= 2 ? history[history.count - 2] : last
            if DrawingWorker.distance(from: again, toSegment: prev, last) <= 2 {
                noteOwnEvent(again)
                clearHits()
                return // just lag
            }
            if !sawOwnEvent, let initial = initialCursor, distance(again, initial) <= 1 {
                if waited >= DrawingWorker.eventsIgnoredAfter - 1e-9 { throw Interrupt.eventsIgnored }
                continue // a slow start, or nothing we post arrives: wait longer before deciding
            }
            // On one of our earlier points: the window server is behind. It can only catch up
            // FORWARD along our path; a cursor sliding back along it is the user.
            if let i = DrawingWorker.latestIndex(of: again, in: history, tolerance: 2), i >= lastMatch {
                lastMatch = i
                noteOwnEvent(again)
                if checks >= DrawingWorker.confirmChecks { break } // persistent lag, not the user
                continue
            }
            if config.pauseOnUserMouseMove { throw Interrupt.userMoved(again) }
            break
        }
        clearHits()
    }

    // MARK: Progress

    private func report(done: Int, force: Bool) {
        let t = env.now()
        guard force || t - lastProgress >= 1.0 / 30.0 else { return }
        lastProgress = t
        let p = DrawingEngine.Progress(strokesDone: done, strokesTotal: config.strokes.count)
        let handler = progressHandler
        env.deliver { handler(p) }
    }

    // MARK: Geometry helpers

    private func distance(_ p: CGPoint, _ q: CGPoint) -> Double {
        Double(hypot(p.x - q.x, p.y - q.y))
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return Double(hypot(p.x - a.x, p.y - a.y)) }
        let t = min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return Double(hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy)))
    }

    /// Distance from `p` to the nearest of `pts` (0 when `pts` is empty).
    static func distance(from p: CGPoint, toNearestOf pts: ArraySlice<CGPoint>) -> Double {
        guard !pts.isEmpty else { return 0 }
        return pts.reduce(Double.infinity) { min($0, Double(hypot(p.x - $1.x, p.y - $1.y))) }
    }

    /// Index of the most recent point of `pts` within `tolerance` of `p`, or nil.
    static func latestIndex(of p: CGPoint, in pts: [CGPoint], tolerance: Double) -> Int? {
        pts.indices.last { Double(hypot(p.x - pts[$0].x, p.y - pts[$0].y)) <= tolerance }
    }
}
