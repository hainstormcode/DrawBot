import CoreGraphics
import DrawBotCore
import Foundation

// MARK: - Event sink seam (internal; lets tests run the engine without touching real input)

/// The kind of synthetic left-button event.
enum SyntheticMouseEventKind: Equatable {
    case moved, down, dragged, up
}

/// One synthetic event, as handed to a `MouseEventSink`.
struct SyntheticMouseEvent: Equatable {
    var kind: SyntheticMouseEventKind
    /// CG global coordinates (already clamped by the driver, if it has a clampRect).
    var point: CGPoint
    /// Integer delta from the previously posted point (moved / dragged only; 0 otherwise).
    var deltaX: Int64
    var deltaY: Int64
}

/// Where a MouseDriver's events go. The live implementation posts CGEvents; tests record them.
protocol MouseEventSink: AnyObject {
    func post(_ event: SyntheticMouseEvent)
    /// Current cursor position (CG global), or nil if it can't be read right now.
    func cursorLocation() -> CGPoint?
}

/// Posts real CGEvents to the HID event tap from one shared `.hidSystemState` source.
final class CGEventPostingSink: MouseEventSink {
    private let source: CGEventSource?

    init() {
        let source = CGEventSource(stateID: .hidSystemState)
        if let source {
            // Never freeze the user's hardware mouse/keyboard after one of our events. The header
            // says the default filter already passes local events through, but the default
            // suppression interval is 0.25 s and the behaviour has differed across macOS releases,
            // so we set both explicitly. This matters for two reasons: (1) the physical mouse must
            // keep moving the cursor during a drawing pass, or user-movement detection (pause)
            // can't see it; (2) the physical Esc key must keep reaching the key-state table and
            // the Carbon hotkey.
            source.localEventsSuppressionInterval = 0
            let permitAll: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
            source.setLocalEventsFilterDuringSuppressionState(permitAll, state: .eventSuppressionStateSuppressionInterval)
            source.setLocalEventsFilterDuringSuppressionState(permitAll, state: .eventSuppressionStateRemoteMouseDrag)
        }
        self.source = source
    }

    func post(_ e: SyntheticMouseEvent) {
        let type: CGEventType
        switch e.kind {
        case .moved: type = .mouseMoved
        case .down: type = .leftMouseDown
        case .dragged: type = .leftMouseDragged
        case .up: type = .leftMouseUp
        }
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: e.point, mouseButton: .left) else { return }
        // No modifiers, whatever the user is holding (e.g. ⌃⌥⌘ still held from the Continue
        // hotkey): ⌃-click is a right-click and ⇧-drag constrains lines in many apps.
        event.flags = []
        switch e.kind {
        case .down:
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.setDoubleValueField(.mouseEventPressure, value: 1.0)
        case .up:
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.setDoubleValueField(.mouseEventPressure, value: 0.0)
        case .dragged:
            event.setDoubleValueField(.mouseEventPressure, value: 1.0)
            event.setIntegerValueField(.mouseEventDeltaX, value: e.deltaX)
            event.setIntegerValueField(.mouseEventDeltaY, value: e.deltaY)
        case .moved:
            event.setIntegerValueField(.mouseEventDeltaX, value: e.deltaX)
            event.setIntegerValueField(.mouseEventDeltaY, value: e.deltaY)
        }
        event.post(tap: .cghidEventTap)
    }

    func cursorLocation() -> CGPoint? {
        CGEvent(source: nil)?.location
    }
}

// MARK: - MouseDriver

/// Posts synthetic left-button mouse events at CG global coordinates (points, top-left origin).
/// Not thread-safe; used from the DrawingEngine's single worker thread.
public final class MouseDriver {
    public var speed: SpeedSettings
    /// True between mouseDown and mouseUp.
    public private(set) var isButtonDown: Bool = false
    /// The last point this driver posted an event at (after clamping), or nil before the first event.
    public private(set) var lastPostedLocation: CGPoint?
    /// When set, every posted point is clamped into this rect (CG global, max edges inclusive).
    public var clampRect: CGRect?

    let sink: MouseEventSink

    public init(speed: SpeedSettings) {
        self.speed = speed
        self.sink = CGEventPostingSink()
    }

    init(speed: SpeedSettings, sink: MouseEventSink) {
        self.speed = speed
        self.sink = sink
    }

    /// Current cursor position, CG global coordinates.
    public func currentCursorLocation() -> CGPoint {
        sink.cursorLocation() ?? lastPostedLocation ?? .zero
    }

    /// Hover move. Posts `.mouseMoved`, or `.leftMouseDragged` if the button is down (so we never
    /// emit a button-up move while the window server believes the button is pressed, and never a
    /// drag while it is up).
    public func move(to p: CGPoint) {
        if isButtonDown {
            post(.dragged, at: p)
        } else {
            post(.moved, at: p)
        }
    }

    public func mouseDown(at p: CGPoint) {
        if isButtonDown { mouseUp(at: lastPostedLocation ?? p) }
        // A down at a new spot is preceded by a hover move so apps see the cursor arrive first.
        if let last = lastPostedLocation, last != constrain(p) { post(.moved, at: p) }
        post(.down, at: p)
        isButtonDown = true
    }

    /// Posts `.leftMouseDragged` while the button is down; a plain `.mouseMoved` otherwise.
    public func drag(to p: CGPoint) {
        move(to: p)
    }

    /// Posts `.leftMouseUp` (always, even if we think the button is already up — a redundant
    /// release is harmless; a missing one is not).
    public func mouseUp(at p: CGPoint) {
        if isButtonDown, let last = lastPostedLocation, last != constrain(p) {
            post(.dragged, at: p)
        }
        post(.up, at: p)
        isButtonDown = false
    }

    /// If the button is down, releases it at the last posted location. Safe to call any time.
    public func releaseIfNeeded() {
        guard isButtonDown else { return }
        mouseUp(at: lastPostedLocation ?? currentCursorLocation())
    }

    // MARK: Private

    private func constrain(_ p: CGPoint) -> CGPoint {
        guard let r = clampRect else { return sanitize(p, fallback: lastPostedLocation ?? .zero) }
        return MouseDriver.clamp(p, to: r)
    }

    private func sanitize(_ p: CGPoint, fallback: CGPoint) -> CGPoint {
        CGPoint(x: p.x.isFinite ? p.x : fallback.x, y: p.y.isFinite ? p.y : fallback.y)
    }

    private func post(_ kind: SyntheticMouseEventKind, at raw: CGPoint) {
        let p = constrain(raw)
        var dx: Int64 = 0, dy: Int64 = 0
        if kind == .moved || kind == .dragged {
            let prev = lastPostedLocation ?? sink.cursorLocation() ?? p
            dx = Int64((p.x.rounded() - prev.x.rounded()))
            dy = Int64((p.y.rounded() - prev.y.rounded()))
        }
        sink.post(SyntheticMouseEvent(kind: kind, point: p, deltaX: dx, deltaY: dy))
        lastPostedLocation = p
    }

    /// Clamps `p` into `r` (standardized; max edges inclusive). Non-finite coordinates map to the
    /// rect's centre. A null / non-finite rect leaves finite points unchanged.
    public static func clamp(_ p: CGPoint, to r: CGRect) -> CGPoint {
        let r = r.standardized
        guard !r.isNull, r.minX.isFinite, r.maxX.isFinite, r.minY.isFinite, r.maxY.isFinite else {
            return CGPoint(x: p.x.isFinite ? p.x : 0, y: p.y.isFinite ? p.y : 0)
        }
        let x = p.x.isFinite ? min(max(p.x, r.minX), r.maxX) : r.midX
        let y = p.y.isFinite ? min(max(p.y, r.minY), r.maxY) : r.midY
        return CGPoint(x: x, y: y)
    }
}
