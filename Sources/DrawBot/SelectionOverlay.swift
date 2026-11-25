import AppKit
import DrawBotCore

/// Borderless, transparent, key-capable window covering one screen.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Full-screen drag-to-select overlay: one window per NSScreen. Reports the selected rectangle
/// in CG global coordinates (top-left origin), or nil when canceled.
final class SelectionOverlay {
    private var windows: [OverlayWindow] = []
    private var completion: ((CGRect?) -> Void)?
    private var finished = false

    var isActive: Bool { !windows.isEmpty }

    func begin(completion: @escaping (CGRect?) -> Void) {
        cancelSilently()
        self.completion = completion
        finished = false
        for screen in NSScreen.screens {
            let w = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = false
            w.acceptsMouseMovedEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.setFrame(screen.frame, display: false)
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.autoresizingMask = [.width, .height]
            view.overlay = self
            w.contentView = view
            windows.append(w)
        }
        ScreenUtil.activateSelf()
        // Put the window under the mouse last so it ends up key (Esc goes there).
        let mouse = NSEvent.mouseLocation
        let ordered = windows.filter { !$0.frame.contains(mouse) } + windows.filter { $0.frame.contains(mouse) }
        for w in ordered {
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(w.contentView)
        }
        NSCursor.crosshair.set()
    }

    /// Esc / external cancel.
    func cancel() { finish(nil) }

    private func cancelSilently() {
        completion = nil
        closeWindows()
    }

    private func closeWindows() {
        let old = windows
        windows.removeAll()
        for w in old { w.orderOut(nil) }
        // finish() usually runs inside one of these windows' own mouseUp / keyDown: keep them
        // alive until that event has been fully dispatched, then close (and release) them.
        DispatchQueue.main.async {
            for w in old { w.close() }
        }
        NSCursor.arrow.set()
    }

    fileprivate func finish(_ cocoaRect: CGRect?) {
        guard !finished else { return }
        finished = true
        let cb = completion
        completion = nil
        closeWindows()
        guard let cocoaRect else { cb?(nil); return }
        // Cocoa global → CG global, rounded outward to whole points.
        let a = Geometry.cocoaToCG(CGPoint(x: cocoaRect.minX, y: cocoaRect.minY), primaryScreenHeight: ScreenUtil.primaryHeight)
        let b = Geometry.cocoaToCG(CGPoint(x: cocoaRect.maxX, y: cocoaRect.maxY), primaryScreenHeight: ScreenUtil.primaryHeight)
        cb?(Geometry.rect(from: a, to: b))
    }

    /// Other overlay windows hide their size label etc. while a drag is in progress elsewhere.
    fileprivate func dragBegan(in view: SelectionView) {
        for w in windows {
            if let v = w.contentView as? SelectionView, v !== view { v.clearSelection() }
        }
    }
}

final class SelectionView: NSView {
    weak var overlay: SelectionOverlay?
    /// View-local drag corners.
    private var anchor: CGPoint?
    private var current: CGPoint?
    private var trackingArea: NSTrackingArea?

    static let minSize: CGFloat = 8

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .cursorUpdate, .mouseEnteredAndExited],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseEntered(with event: NSEvent) { NSCursor.crosshair.set() }

    func clearSelection() {
        anchor = nil
        current = nil
        needsDisplay = true
    }

    private func localPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        // Constrain to this view (= the screen where the drag began).
        return CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
    }

    private var selectionRect: CGRect? {
        guard let a = anchor, let c = current else { return nil }
        return CGRect(x: min(a.x, c.x), y: min(a.y, c.y), width: abs(a.x - c.x), height: abs(a.y - c.y))
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.crosshair.set()
        overlay?.dragBegan(in: self)
        let p = localPoint(event)
        anchor = p
        current = p
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard anchor != nil else { return }
        current = localPoint(event)
        NSCursor.crosshair.set()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard anchor != nil else { return }
        current = localPoint(event)
        guard let r = selectionRect, r.width >= Self.minSize, r.height >= Self.minSize, let window else {
            // Too small (or a plain click): keep the overlay up.
            clearSelection()
            return
        }
        // view-local → window → screen (Cocoa global).
        let inWindow = convert(r, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        overlay?.finish(onScreen)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { overlay?.cancel() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { overlay?.cancel() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        bounds.fill(using: .copy)
        let dim = NSColor.black.withAlphaComponent(0.15)
        let sel = selectionRect

        let path = NSBezierPath(rect: bounds)
        if let sel, sel.width > 0, sel.height > 0 {
            path.append(NSBezierPath(rect: sel))
            path.windingRule = .evenOdd
        }
        dim.setFill()
        path.fill()

        if let sel, sel.width > 0, sel.height > 0 {
            // 1 px white + 1 px black outline just outside the selection.
            let px = 1 / max(1, window?.backingScaleFactor ?? 1)
            NSColor.white.setStroke()
            let inner = NSBezierPath(rect: sel.insetBy(dx: -px / 2, dy: -px / 2))
            inner.lineWidth = px
            inner.stroke()
            NSColor.black.setStroke()
            let outer = NSBezierPath(rect: sel.insetBy(dx: -px * 1.5, dy: -px * 1.5))
            outer.lineWidth = px
            outer.stroke()

            drawLabel("\(Int(sel.width.rounded())) × \(Int(sel.height.rounded())) pt", near: sel)
        } else {
            drawInstruction()
        }
    }

    private func pill(_ text: String, font: NSFont) -> (NSAttributedString, CGSize) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        return (s, CGSize(width: size.width + 20, height: size.height + 10))
    }

    private func drawPill(_ s: NSAttributedString, size: CGSize, at origin: CGPoint) {
        let r = CGRect(origin: origin, size: size)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: r, xRadius: size.height / 2, yRadius: size.height / 2).fill()
        s.draw(at: CGPoint(x: r.minX + 10, y: r.minY + 5))
    }

    private func drawInstruction() {
        let (s, size) = pill("Drag to select the drawing area · Esc to cancel", font: .systemFont(ofSize: 15, weight: .medium))
        drawPill(s, size: size, at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    private func drawLabel(_ text: String, near sel: CGRect) {
        let (s, size) = pill(text, font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium))
        var origin = CGPoint(x: sel.minX, y: sel.minY - size.height - 6)
        if origin.y < bounds.minY + 4 { origin.y = sel.maxY + 6 }
        if origin.y + size.height > bounds.maxY - 4 { origin.y = sel.minY + 6 }
        origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - size.width - 4)
        drawPill(s, size: size, at: origin)
    }
}
