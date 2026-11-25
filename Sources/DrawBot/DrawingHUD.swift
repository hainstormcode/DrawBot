import AppKit
import DrawBotCore
import SwiftUI

struct HUDContent: Equatable {
    enum Mode: Equatable {
        case preparing
        case countdown(Int)
        case drawing(fraction: Double)
        /// Color Learn is selecting this step's color in the drawing app.
        case selectingColor
        /// Color Learn is trying out what it learned.
        case learnTrying
    }
    var mode: Mode
    var color: RGB?
    var stepNumber: Int
    var stepCount: Int
}

/// Small click-through, non-activating panel shown while preparing / counting down / drawing.
/// Placed in the corner of the canvas's screen furthest from the canvas.
final class DrawingHUDController {
    private let panel: NSPanel
    private let hosting: NSHostingView<HUDView>
    private var placedForCanvas: CGRect?
    /// Content size the panel was last placed for. (Not `panel.frame.size`: the hosting view's
    /// intrinsic-size constraints may already have resized the panel, growing it off its corner.)
    private var placedSize: CGSize?

    init() {
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 300, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hosting = NSHostingView(rootView: HUDView(content: HUDContent(mode: .preparing, color: nil, stepNumber: 0, stepCount: 0)))
        panel.contentView = hosting
    }

    func show(_ content: HUDContent, canvasCG: CGRect?) {
        hosting.rootView = HUDView(content: content)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        if placedSize != size || placedForCanvas != canvasCG || !panel.isVisible {
            panel.setContentSize(size)
            panel.setFrameOrigin(ScreenUtil.cornerPlacement(size: panel.frame.size, awayFromCanvasCG: canvasCG))
            placedForCanvas = canvasCG
            placedSize = size
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        panel.orderOut(nil)
        placedForCanvas = nil
        placedSize = nil
    }
}

struct HUDView: View {
    let content: HUDContent

    var body: some View {
        HStack(spacing: 10) {
            if let c = content.color {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: c.nsColor))
                    .frame(width: 22, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.3), lineWidth: 1))
            }
            Text(text)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .fixedSize()
    }

    private var text: String {
        let step = "color \(content.stepNumber)/\(content.stepCount)"
        switch content.mode {
        case .preparing:
            return "Getting ready · \(step) · Esc to cancel"
        case .countdown(let n) where n <= 0:
            return "Release the modifier keys to start · Esc to cancel"
        case .countdown(let n):
            return "Drawing \(step) in \(n)… · Esc to cancel"
        case .drawing(let f):
            let pct = Int((min(max(f, 0), 1) * 100).rounded(.down))
            return "Drawing \(step) · \(pct)% · Esc to stop"
        case .selectingColor:
            return "Selecting \(step) for you · hands off the mouse · Esc to cancel"
        case .learnTrying:
            return "Trying out your color picker · hands off the mouse · Esc to cancel"
        }
    }
}
