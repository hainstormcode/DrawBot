import AppKit
import DrawBotCore

/// A white surface that records mouse drags as round-capped lines into an offscreen bitmap,
/// so thousands of strokes stay cheap to display.
final class TestCanvasView: NSView {
    /// Color and width for new strokes (asked at mouse-down).
    var strokeStyle: () -> (NSColor, CGFloat) = { (.black, 4) }

    private var bitmap: CGContext?
    private var bitmapScale: CGFloat = 0
    private var lastPoint: CGPoint?
    private var currentColor: CGColor = NSColor.black.cgColor
    private var currentWidth: CGFloat = 4

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func clear() {
        bitmap = nil
        ensureBitmap()
        needsDisplay = true
    }

    private func ensureBitmap() {
        let scale = window?.backingScaleFactor ?? 2
        let w = max(1, Int((bounds.width * scale).rounded(.up)))
        let h = max(1, Int((bounds.height * scale).rounded(.up)))
        if let b = bitmap, b.width == w, b.height == h, bitmapScale == scale { return }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Keep existing drawing (anchored bottom-left, same as view coordinates).
        if let old = bitmap, let img = old.makeImage() {
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: CGFloat(old.width) * scale / max(bitmapScale, 0.01),
                                     height: CGFloat(old.height) * scale / max(bitmapScale, 0.01)))
        }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.interpolationQuality = .high
        bitmap = ctx
        bitmapScale = scale
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if window != nil { ensureBitmap() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        ensureBitmap()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        ensureBitmap()
        guard let g = NSGraphicsContext.current?.cgContext else { return }
        g.setFillColor(CGColor(gray: 1, alpha: 1))
        g.fill(dirtyRect)
        if let b = bitmap, let img = b.makeImage() {
            g.interpolationQuality = .none
            g.draw(img, in: CGRect(x: 0, y: 0, width: CGFloat(b.width) / bitmapScale, height: CGFloat(b.height) / bitmapScale))
        }
    }

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    private func segment(from a: CGPoint, to b: CGPoint) {
        ensureBitmap()
        guard let ctx = bitmap else { return }
        ctx.setStrokeColor(currentColor)
        ctx.setLineWidth(currentWidth)
        ctx.beginPath()
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()
        if a == b {
            ctx.setFillColor(currentColor)
            ctx.fillEllipse(in: CGRect(x: a.x - currentWidth / 2, y: a.y - currentWidth / 2, width: currentWidth, height: currentWidth))
        }
        let pad = currentWidth / 2 + 2
        let dirty = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).insetBy(dx: -pad, dy: -pad)
        setNeedsDisplay(dirty)
    }

    override func mouseDown(with event: NSEvent) {
        let (color, width) = strokeStyle()
        currentColor = (color.usingColorSpace(.sRGB) ?? color).cgColor
        currentWidth = max(0.5, width)
        let p = point(event)
        lastPoint = p
        segment(from: p, to: p)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        segment(from: lastPoint ?? p, to: p)
        lastPoint = p
    }

    override func mouseUp(with event: NSEvent) {
        let p = point(event)
        if let last = lastPoint, last != p { segment(from: last, to: p) }
        lastPoint = nil
    }
}

/// Handles ⌘A / ⌘C / ⌘V / ⌘X / ⌘Z itself: an accessory app has no Edit menu to route them, and
/// Color Learn may replay them into the picker's hex field.
final class EditingWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let chars = event.charactersIgnoringModifiers?.lowercased() {
            let action: Selector?
            switch chars {
            case "a": action = #selector(NSText.selectAll(_:))
            case "c": action = #selector(NSText.copy(_:))
            case "v": action = #selector(NSText.paste(_:))
            case "x": action = #selector(NSText.cut(_:))
            case "z": action = Selector(("undo:"))
            case "w": performClose(nil); return true
            case "q": NSApp.terminate(nil); return true
            default: action = nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The built-in Test Canvas: a normal window with a white drawing surface, Clear, and a small
/// color picker (square + hue strip + hex field) that Color Learn can learn.
final class TestCanvasWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    let window: NSWindow
    let canvasView: TestCanvasView
    private let picker = MiniColorPickerView(frame: CGRect(origin: .zero, size: MiniColorPickerView.preferredSize))
    private let hexField = NSTextField(string: "000000")
    private let swatch = SwatchView(frame: CGRect(x: 0, y: 0, width: 40, height: 22))

    /// The color selected in the Test Canvas's own picker.
    var pickedColor: RGB { picker.color }

    init(strokeStyle: @escaping () -> (NSColor, CGFloat)) {
        let sideWidth: CGFloat = 210
        let contentRect = CGRect(x: 0, y: 0, width: 800 + sideWidth, height: 600)
        window = EditingWindow(contentRect: contentRect, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
        window.title = "DrawBot Test Canvas"
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 300 + sideWidth, height: 300)
        ScreenUtil.applyAllSpaces(window)

        let barHeight: CGFloat = 36
        let container = NSView(frame: contentRect)
        canvasView = TestCanvasView(frame: CGRect(x: 0, y: 0, width: contentRect.width - sideWidth, height: contentRect.height - barHeight))
        canvasView.autoresizingMask = [.width, .height]
        canvasView.strokeStyle = strokeStyle

        let bar = NSView(frame: CGRect(x: 0, y: contentRect.height - barHeight, width: contentRect.width, height: barHeight))
        bar.autoresizingMask = [.width, .minYMargin]
        let clear = NSButton(title: "Clear", target: nil, action: nil)
        clear.bezelStyle = .rounded
        clear.sizeToFit()
        clear.frame.origin = CGPoint(x: 10, y: (barHeight - clear.frame.height) / 2)
        let label = NSTextField(labelWithString: "Select Canvas inside the white area, then Start Drawing.")
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        label.sizeToFit()
        label.frame.origin = CGPoint(x: clear.frame.maxX + 12, y: (barHeight - label.frame.height) / 2)
        label.autoresizingMask = [.maxXMargin]
        bar.addSubview(clear)
        bar.addSubview(label)

        let sep = NSBox(frame: CGRect(x: 0, y: contentRect.height - barHeight - 1, width: contentRect.width, height: 1))
        sep.boxType = .separator
        sep.autoresizingMask = [.width, .minYMargin]

        // Color picker column on the right.
        let sideHeight = contentRect.height - barHeight - 1
        let side = NSView(frame: CGRect(x: contentRect.width - sideWidth, y: 0, width: sideWidth, height: sideHeight))
        side.autoresizingMask = [.minXMargin, .height]
        let vsep = NSBox(frame: CGRect(x: 0, y: 0, width: 1, height: sideHeight))
        vsep.boxType = .separator
        vsep.autoresizingMask = [.height]
        side.addSubview(vsep)
        let title = NSTextField(labelWithString: "Color picker")
        title.font = .boldSystemFont(ofSize: 12)
        title.sizeToFit()
        var y = sideHeight - 14 - title.frame.height
        title.frame.origin = CGPoint(x: 16, y: y)
        title.autoresizingMask = [.minYMargin]
        side.addSubview(title)
        y -= 8 + MiniColorPickerView.preferredSize.height
        picker.frame.origin = CGPoint(x: 16, y: y)
        picker.autoresizingMask = [.minYMargin]
        side.addSubview(picker)
        let hexLabel = NSTextField(labelWithString: "Hex #")
        hexLabel.font = .systemFont(ofSize: 12)
        hexLabel.sizeToFit()
        y -= 14 + 22
        hexLabel.frame.origin = CGPoint(x: 16, y: y + 3)
        hexLabel.autoresizingMask = [.minYMargin]
        hexField.frame = CGRect(x: hexLabel.frame.maxX + 4, y: y, width: 76, height: 22)
        hexField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        hexField.autoresizingMask = [.minYMargin]
        swatch.frame.origin = CGPoint(x: hexField.frame.maxX + 8, y: y)
        swatch.autoresizingMask = [.minYMargin]
        side.addSubview(hexLabel)
        side.addSubview(hexField)
        side.addSubview(swatch)
        let help = NSTextField(wrappingLabelWithString: "With Color selection set to automatic, DrawBot paints with this picker's color. Teach it with Learn Color Picker… in the DrawBot panel.")
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        help.frame = CGRect(x: 16, y: y - 12 - 70, width: sideWidth - 28, height: 70)
        help.autoresizingMask = [.minYMargin]
        side.addSubview(help)

        container.addSubview(canvasView)
        container.addSubview(side)
        container.addSubview(bar)
        container.addSubview(sep)
        window.contentView = container
        super.init()
        clear.target = self
        clear.action = #selector(clearCanvas)
        hexField.target = self
        hexField.action = #selector(hexEntered)
        hexField.delegate = self
        picker.onChange = { [weak self] c in self?.pickerChanged(c) }
        pickerChanged(picker.color)
        window.delegate = self
        window.center()
    }

    @objc func clearCanvas() { canvasView.clear() }

    private func pickerChanged(_ c: RGB) {
        swatch.color = c
        if window.firstResponder !== hexField.currentEditor() {
            hexField.stringValue = c.hexNoHash
        }
    }

    @objc private func hexEntered() {
        applyHex(hexField.stringValue)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        applyHex(hexField.stringValue)
    }

    private func applyHex(_ text: String) {
        let s = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard s.count == 6, let v = Int(s, radix: 16) else {
            hexField.stringValue = picker.color.hexNoHash
            return
        }
        let c = RGB(r: UInt8((v >> 16) & 255), g: UInt8((v >> 8) & 255), b: UInt8(v & 255))
        picker.setColor(c)
        swatch.color = c
        hexField.stringValue = c.hexNoHash
    }

    var isVisible: Bool { window.isVisible && !window.isMiniaturized }

    /// The drawing surface's frame in CG global coordinates.
    var canvasFrameCG: CGRect {
        let inWindow = canvasView.convert(canvasView.bounds, to: nil)
        return ScreenUtil.toCG(window.convertToScreen(inWindow))
    }

    func show() {
        ScreenUtil.activateSelf()
        window.makeKeyAndOrderFront(nil)
    }
}
