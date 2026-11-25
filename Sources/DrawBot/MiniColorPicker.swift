import AppKit
import DrawBotCore

/// The Test Canvas's color picker: a saturation × brightness square and a hue strip, like the
/// pickers of most paint apps, so Color Learn can be tried without one.
final class MiniColorPickerView: NSView {
    private(set) var hue: Double = 0
    private(set) var saturation: Double = 0
    private(set) var brightness: Double = 0
    var onChange: (RGB) -> Void = { _ in }

    private enum Region { case square, strip }
    private var dragging: Region?

    static let side: CGFloat = 150
    static let stripWidth: CGFloat = 18
    static let gap: CGFloat = 10
    static var preferredSize: CGSize { CGSize(width: side + gap + stripWidth, height: side) }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    var color: RGB { ColorMath.rgb(hue: hue, saturation: saturation, brightness: brightness) }

    func setColor(_ c: RGB, notify: Bool = false) {
        let hsb = ColorMath.hsb(c)
        // Keep the current hue for grays (their hue is undefined).
        if hsb.s > 0 && hsb.b > 0 { hue = hsb.h }
        saturation = hsb.s
        brightness = hsb.b
        needsDisplay = true
        if notify { onChange(color) }
    }

    private var squareRect: CGRect { CGRect(x: 0, y: 0, width: Self.side, height: Self.side) }
    private var stripRect: CGRect { CGRect(x: Self.side + Self.gap, y: 0, width: Self.stripWidth, height: Self.side) }

    override func draw(_ dirtyRect: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext else { return }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        // Square: pure hue, white → transparent left to right, transparent → black top to bottom.
        let sq = squareRect
        g.saveGState()
        g.addRect(sq)
        g.clip()
        g.setFillColor(ColorMath.rgb(hue: hue, saturation: 100, brightness: 100).cgColor)
        g.fill(sq)
        if let white = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1]) {
            g.drawLinearGradient(white, start: CGPoint(x: sq.minX, y: sq.midY), end: CGPoint(x: sq.maxX, y: sq.midY), options: [])
        }
        if let black = CGGradient(colorsSpace: space, colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1)] as CFArray, locations: [0, 1]) {
            g.drawLinearGradient(black, start: CGPoint(x: sq.midX, y: sq.minY), end: CGPoint(x: sq.midX, y: sq.maxY), options: [])
        }
        g.restoreGState()
        // Hue strip: 0° at the top, 360° at the bottom.
        let st = stripRect
        let stops = stride(from: 0.0, through: 360.0, by: 30.0).map { ColorMath.rgb(hue: $0, saturation: 100, brightness: 100).cgColor }
        let locs: [CGFloat] = stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { CGFloat($0) }
        if let hues = CGGradient(colorsSpace: space, colors: stops as CFArray, locations: locs) {
            g.saveGState()
            g.addRect(st)
            g.clip()
            g.drawLinearGradient(hues, start: CGPoint(x: st.midX, y: st.minY), end: CGPoint(x: st.midX, y: st.maxY), options: [])
            g.restoreGState()
        }
        g.setStrokeColor(NSColor.separatorColor.cgColor)
        g.setLineWidth(1)
        g.stroke(sq.insetBy(dx: 0.5, dy: 0.5))
        g.stroke(st.insetBy(dx: 0.5, dy: 0.5))
        // Markers.
        let p = CGPoint(x: sq.minX + saturation / 100 * sq.width, y: sq.minY + (1 - brightness / 100) * sq.height)
        g.setStrokeColor(CGColor(gray: brightness > 55 && saturation < 45 ? 0 : 1, alpha: 1))
        g.setLineWidth(1.5)
        g.strokeEllipse(in: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
        let hy = st.minY + hue / 360 * st.height
        g.setStrokeColor(CGColor(gray: 0, alpha: 1))
        g.stroke(CGRect(x: st.minX - 2, y: hy - 2, width: st.width + 4, height: 4))
    }

    private func update(at p: CGPoint) {
        switch dragging {
        case .square:
            let sq = squareRect
            saturation = Double(min(max((p.x - sq.minX) / sq.width, 0), 1)) * 100
            brightness = Double(1 - min(max((p.y - sq.minY) / sq.height, 0), 1)) * 100
        case .strip:
            let st = stripRect
            hue = Double(min(max((p.y - st.minY) / st.height, 0), 1)) * 360
            if hue >= 360 { hue = 0 }
        case nil:
            return
        }
        needsDisplay = true
        onChange(color)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if squareRect.insetBy(dx: -3, dy: -3).contains(p) {
            dragging = .square
        } else if stripRect.insetBy(dx: -4, dy: -3).contains(p) {
            dragging = .strip
        } else {
            dragging = nil
        }
        update(at: p)
    }

    override func mouseDragged(with event: NSEvent) { update(at: convert(event.locationInWindow, from: nil)) }

    override func mouseUp(with event: NSEvent) {
        update(at: convert(event.locationInWindow, from: nil))
        dragging = nil
    }
}

/// A plain color swatch.
final class SwatchView: NSView {
    var color: RGB = RGB(r: 0, g: 0, b: 0) { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        color.nsColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
    }
}
