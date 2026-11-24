import AppKit
import Carbon.HIToolbox
import CoreGraphics
import DrawBotCore
import Foundation

/// Where the replayer's events go. The live implementation posts CGEvents; tests record them.
protocol ReplayEventSink: AnyObject {
    func postMouse(_ type: CGEventType, at p: CGPoint, button: PointerButton, clickState: Int64, modifiers: KeyModifiers,
                   delta: (Int64, Int64))
    func postKey(_ stroke: KeyStroke, down: Bool)
    func setClipboard(_ s: String)
    func cursorLocation() -> CGPoint?
    func escapePressed() -> Bool
    func isTrusted() -> Bool
    func sleep(_ seconds: TimeInterval)
}

final class LiveReplaySink: ReplayEventSink {
    private let source: CGEventSource?

    init() {
        let source = CGEventSource(stateID: .hidSystemState)
        if let source {
            // Same as the drawing sink: never freeze the user's hardware input after our events.
            source.localEventsSuppressionInterval = 0
            let permitAll: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
            source.setLocalEventsFilterDuringSuppressionState(permitAll, state: .eventSuppressionStateSuppressionInterval)
            source.setLocalEventsFilterDuringSuppressionState(permitAll, state: .eventSuppressionStateRemoteMouseDrag)
        }
        self.source = source
    }

    static func flags(_ m: KeyModifiers) -> CGEventFlags {
        var f: CGEventFlags = []
        if m.contains(.shift) { f.insert(.maskShift) }
        if m.contains(.control) { f.insert(.maskControl) }
        if m.contains(.option) { f.insert(.maskAlternate) }
        if m.contains(.command) { f.insert(.maskCommand) }
        return f
    }

    func postMouse(_ type: CGEventType, at p: CGPoint, button: PointerButton, clickState: Int64, modifiers: KeyModifiers,
                   delta: (Int64, Int64)) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p,
                              mouseButton: button == .right ? .right : .left) else { return }
        e.flags = Self.flags(modifiers)
        switch type {
        case .leftMouseDown, .rightMouseDown:
            e.setIntegerValueField(.mouseEventClickState, value: clickState)
            e.setDoubleValueField(.mouseEventPressure, value: 1)
        case .leftMouseUp, .rightMouseUp:
            e.setIntegerValueField(.mouseEventClickState, value: clickState)
            e.setDoubleValueField(.mouseEventPressure, value: 0)
        case .leftMouseDragged, .rightMouseDragged:
            e.setDoubleValueField(.mouseEventPressure, value: 1)
            e.setIntegerValueField(.mouseEventDeltaX, value: delta.0)
            e.setIntegerValueField(.mouseEventDeltaY, value: delta.1)
        default:
            e.setIntegerValueField(.mouseEventDeltaX, value: delta.0)
            e.setIntegerValueField(.mouseEventDeltaY, value: delta.1)
        }
        e.post(tap: .cghidEventTap)
    }

    func postKey(_ stroke: KeyStroke, down: Bool) {
        let code: CGKeyCode = stroke.keyCode == 0xFFFF ? 0 : CGKeyCode(stroke.keyCode)
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        e.flags = Self.flags(stroke.modifiers)
        if !stroke.isShortcut, !stroke.characters.isEmpty {
            let utf16 = Array(stroke.characters.utf16)
            utf16.withUnsafeBufferPointer { buf in
                e.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            }
        }
        e.post(tap: .cghidEventTap)
    }

    func setClipboard(_ s: String) {
        let work = {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(s, forType: .string)
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
    }

    func cursorLocation() -> CGPoint? { CGEvent(source: nil)?.location }

    func escapePressed() -> Bool {
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Escape))
    }

    func isTrusted() -> Bool { Permissions.isAccessibilityTrusted }

    func sleep(_ seconds: TimeInterval) { PreciseClock.sleep(seconds) }
}

/// Plays Colour Learn `ReplayAction`s (clicks, drags, keystrokes, clipboard) on a worker thread.
///
/// Call `run` from the main thread; `completion` is called on the main queue exactly once. Stops
/// early on Escape, `requestStop`, a lost Accessibility permission, or (when
/// `stopOnUserMouseMove`) when the user moves the mouse away from where DrawBot put it. The
/// mouse button is always released.
public final class InputReplayer {
    public enum Outcome: Equatable {
        case completed
        case stopped(reason: String)
    }

    public private(set) var isRunning = false
    public var stopOnUserMouseMove = true
    /// Slower pacing for laggy apps.
    public var careful = false

    private let makeSink: () -> ReplayEventSink
    private let lock = NSLock()
    private var stopReason: String?  // guarded by lock

    public init() {
        makeSink = { LiveReplaySink() }
    }

    init(sink: @escaping () -> ReplayEventSink) {
        makeSink = sink
    }

    public func run(_ actions: [ReplayAction], completion: @escaping (Outcome) -> Void) {
        guard !isRunning else { return }
        isRunning = true
        lock.lock(); stopReason = nil; lock.unlock()
        let sink = makeSink()
        let detectMove = stopOnUserMouseMove
        let pace = careful ? 1.8 : 1.0
        let thread = Thread { [self] in
            let worker = ReplayWorker(sink: sink, detectMove: detectMove, pace: pace, stopRequested: { [self] in
                lock.lock(); defer { lock.unlock() }
                return stopReason
            })
            let outcome = worker.run(actions)
            DispatchQueue.main.async { [self] in
                isRunning = false
                completion(outcome)
            }
        }
        thread.name = "DrawBot.InputReplayer"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Thread-safe.
    public func requestStop(reason: String = "Stopped") {
        lock.lock()
        if stopReason == nil { stopReason = reason }
        lock.unlock()
    }
}

private struct ReplayInterrupt: Error {
    let reason: String
}

final class ReplayWorker {
    let sink: ReplayEventSink
    let detectMove: Bool
    let pace: Double
    let stopRequested: () -> String?
    private var lastPosted: CGPoint?
    private var buttonDown: (PointerButton, KeyModifiers)?
    private var ignoreEscapeUntil: TimeInterval = 0
    private static let moveThreshold = 14.0

    init(sink: ReplayEventSink, detectMove: Bool, pace: Double, stopRequested: @escaping () -> String?) {
        self.sink = sink
        self.detectMove = detectMove
        self.pace = pace
        self.stopRequested = stopRequested
    }

    func run(_ actions: [ReplayAction]) -> InputReplayer.Outcome {
        guard sink.isTrusted() else { return .stopped(reason: DrawingEngine.Reason.permissionMissing) }
        do {
            for action in actions {
                try checkpoint()
                switch action {
                case .wait(let t):
                    try wait(t * pace)
                case .click(let p, let button, let count, let mods):
                    try moveTo(p)
                    try wait(0.04 * pace)
                    for i in 1...max(1, min(count, 3)) {
                        post(button == .right ? .rightMouseDown : .leftMouseDown, p, button, Int64(i), mods)
                        buttonDown = (button, mods)
                        sink.sleep(0.025 * pace)
                        post(button == .right ? .rightMouseUp : .leftMouseUp, p, button, Int64(i), mods)
                        buttonDown = nil
                        sink.sleep(0.03 * pace)
                    }
                case .drag(let from, let to, let button, let mods):
                    try moveTo(from)
                    try wait(0.04 * pace)
                    post(button == .right ? .rightMouseDown : .leftMouseDown, from, button, 1, mods)
                    buttonDown = (button, mods)
                    sink.sleep(0.03 * pace)
                    let dragType: CGEventType = button == .right ? .rightMouseDragged : .leftMouseDragged
                    let len = Double(hypot(to.x - from.x, to.y - from.y))
                    if len < 0.5 {
                        post(dragType, CGPoint(x: from.x + 0.5, y: from.y), button, 1, mods)
                        sink.sleep(0.01 * pace)
                        post(dragType, to, button, 1, mods)
                    } else {
                        // 3-pt steps, then 1-pt steps for the last 10 pt: pickers that stop
                        // tracking once the pointer leaves the control keep the last position
                        // inside it, which is then within a point of the edge.
                        for d in Self.dragDistances(length: len) {
                            let f = CGFloat(d / len)
                            post(dragType, CGPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f), button, 1, mods)
                            sink.sleep(0.006 * pace)
                            if let reason = stopRequested() { throw ReplayInterrupt(reason: reason) }
                        }
                    }
                    sink.sleep(0.03 * pace)
                    post(button == .right ? .rightMouseUp : .leftMouseUp, to, button, 1, mods)
                    buttonDown = nil
                    sink.sleep(0.04 * pace)
                case .key(let stroke):
                    if stroke.keyCode == VirtualKey.escape { ignoreEscapeUntil = PreciseClock.now() + 0.4 }
                    sink.postKey(stroke, down: true)
                    sink.sleep(0.012 * pace)
                    sink.postKey(stroke, down: false)
                    sink.sleep(0.03 * pace)
                case .setClipboard(let s):
                    sink.setClipboard(s)
                    sink.sleep(0.05)
                case .move(let p):
                    try moveTo(p)
                    sink.sleep(0.03 * pace)
                }
            }
            return .completed
        } catch let i as ReplayInterrupt {
            release()
            return .stopped(reason: i.reason)
        } catch {
            release()
            return .stopped(reason: "Stopped")
        }
    }

    /// Distances along a drag of `length` at which to post drag events (the last one is `length`).
    static func dragDistances(length: Double) -> [Double] {
        guard length > 0 else { return [] }
        let fineFrom = max(0, length - 10)
        var out: [Double] = []
        var d = 0.0
        while d + 3 < fineFrom { d += 3; out.append(d) }
        if d < fineFrom { d = fineFrom; out.append(d) }
        while d + 1 < length { d += 1; out.append(d) }
        out.append(length)
        return out
    }

    private func release() {
        guard let (button, mods) = buttonDown else { return }
        post(button == .right ? .rightMouseUp : .leftMouseUp, lastPosted ?? sink.cursorLocation() ?? .zero, button, 1, mods)
        buttonDown = nil
    }

    private func post(_ type: CGEventType, _ p: CGPoint, _ button: PointerButton, _ clickState: Int64, _ mods: KeyModifiers) {
        var delta: (Int64, Int64) = (0, 0)
        if let last = lastPosted {
            delta = (Int64(p.x.rounded() - last.x.rounded()), Int64(p.y.rounded() - last.y.rounded()))
        }
        sink.postMouse(type, at: p, button: button, clickState: clickState, modifiers: mods, delta: delta)
        lastPosted = p
    }

    private func moveTo(_ p: CGPoint) throws {
        try checkUserMovement()
        post(.mouseMoved, p, .left, 0, [])
    }

    private func wait(_ t: TimeInterval) throws {
        var left = t
        while left > 0 {
            let slice = min(0.01, left)
            sink.sleep(slice)
            left -= slice
            try checkpoint()
        }
    }

    private func checkpoint() throws {
        if let reason = stopRequested() { throw ReplayInterrupt(reason: reason) }
        if PreciseClock.now() >= ignoreEscapeUntil && sink.escapePressed() {
            throw ReplayInterrupt(reason: DrawingEngine.Reason.escape)
        }
        if !sink.isTrusted() { throw ReplayInterrupt(reason: DrawingEngine.Reason.permissionLost) }
    }

    /// The cursor should still be where we last put it. Re-check a few times (the window
    /// server may lag behind our last event) before concluding the user moved the mouse.
    private func checkUserMovement() throws {
        guard detectMove, let expected = lastPosted else { return }
        for attempt in 0..<4 {
            guard let cur = sink.cursorLocation() else { return }
            if Double(hypot(cur.x - expected.x, cur.y - expected.y)) <= Self.moveThreshold { return }
            if attempt < 3 { sink.sleep(0.04) }
        }
        throw ReplayInterrupt(reason: DrawingEngine.Reason.mouseMoved)
    }
}
