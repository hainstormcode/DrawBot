import AppKit
import DrawBotCore
import SwiftUI

/// Screen / coordinate helpers. All Cocoa ⇄ CG conversion goes through `Geometry` using the
/// height of the PRIMARY screen (`NSScreen.screens.first`, never `NSScreen.main`).
enum ScreenUtil {
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    static func toCG(_ cocoaRect: CGRect) -> CGRect {
        Geometry.cocoaToCG(cocoaRect, primaryScreenHeight: primaryHeight)
    }

    static func toCocoa(_ cgRect: CGRect) -> CGRect {
        Geometry.cgToCocoa(cgRect, primaryScreenHeight: primaryHeight)
    }

    static func cgFrame(of screen: NSScreen) -> CGRect { toCG(screen.frame) }

    /// The screen whose frame contains `cgPoint` (CG global), else the primary screen.
    static func screen(containingCG cgPoint: CGPoint) -> NSScreen? {
        for s in NSScreen.screens where cgFrame(of: s).contains(cgPoint) { return s }
        return NSScreen.screens.first
    }

    static func screen(forCanvas canvasCG: CGRect) -> NSScreen? {
        screen(containingCG: CGPoint(x: canvasCG.midX, y: canvasCG.midY))
    }

    /// True if `canvasCG` lies entirely on one connected screen.
    static func isOnConnectedScreen(_ canvasCG: CGRect) -> Bool {
        NSScreen.screens.contains { cgFrame(of: $0).insetBy(dx: -0.5, dy: -0.5).contains(canvasCG) }
    }

    /// Picks a Cocoa-global origin for a window of `size` on the canvas's screen that avoids the
    /// canvas if at all possible (least overlap first, then furthest from the canvas). When the
    /// canvas covers the whole screen, falls back to the top-right corner.
    static func placement(size: CGSize, avoidingCanvasCG canvasCG: CGRect?, margin: CGFloat = 16) -> CGPoint {
        let screen = canvasCG.flatMap { screen(forCanvas: $0) } ?? NSScreen.screens.first
        guard let screen else { return .zero }
        let vf = screen.visibleFrame
        let w = min(size.width, vf.width), h = min(size.height, vf.height)
        let topRight = CGPoint(x: vf.maxX - w - margin, y: vf.maxY - h - margin)
        guard let canvasCG else { return topRight }
        let canvas = toCocoa(canvasCG)

        var candidates: [CGPoint] = [
            topRight,
            CGPoint(x: vf.minX + margin, y: vf.maxY - h - margin),           // top-left
            CGPoint(x: vf.maxX - w - margin, y: vf.minY + margin),           // bottom-right
            CGPoint(x: vf.minX + margin, y: vf.minY + margin),               // bottom-left
            CGPoint(x: vf.midX - w / 2, y: vf.maxY - h - margin),            // top-center
            CGPoint(x: vf.midX - w / 2, y: vf.minY + margin),                // bottom-center
            CGPoint(x: vf.minX + margin, y: vf.midY - h / 2),                // left-center
            CGPoint(x: vf.maxX - w - margin, y: vf.midY - h / 2),            // right-center
        ]
        // Right next to the canvas (keeps the prompt close to where the user is looking).
        let cy = min(max(canvas.maxY - h, vf.minY + margin), vf.maxY - h - margin)
        let cx = min(max(canvas.midX - w / 2, vf.minX + margin), vf.maxX - w - margin)
        candidates += [
            CGPoint(x: canvas.maxX + margin, y: cy),
            CGPoint(x: canvas.minX - w - margin, y: cy),
            CGPoint(x: cx, y: canvas.maxY + margin),
            CGPoint(x: cx, y: canvas.minY - h - margin),
        ]

        let center = CGPoint(x: canvas.midX, y: canvas.midY)
        var best = topRight
        var bestScore: (CGFloat, CGFloat) = (.greatestFiniteMagnitude, 0)
        for c in candidates {
            let r = CGRect(origin: c, size: CGSize(width: w, height: h))
            guard vf.insetBy(dx: -0.5, dy: -0.5).contains(r) else { continue }
            let overlap = r.intersection(canvas)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            let dist = hypot(r.midX - center.x, r.midY - center.y)
            // Lower overlap wins; among equal overlap, larger distance wins.
            if area < bestScore.0 - 0.5 || (abs(area - bestScore.0) <= 0.5 && dist > bestScore.1) {
                best = c
                bestScore = (area, dist)
            }
        }
        if bestScore.0 > 0 {
            // Canvas covers (nearly) the whole screen — top-right corner anyway.
            return topRight
        }
        return best
    }

    /// Like `placement`, but only the four screen corners, choosing the one furthest from the
    /// canvas (the HUD rule from the spec). Top-right if every corner overlaps.
    static func cornerPlacement(size: CGSize, awayFromCanvasCG canvasCG: CGRect?, margin: CGFloat = 12) -> CGPoint {
        let screen = canvasCG.flatMap { screen(forCanvas: $0) } ?? NSScreen.screens.first
        guard let screen else { return .zero }
        let vf = screen.visibleFrame
        let w = size.width, h = size.height
        let corners = [
            CGPoint(x: vf.maxX - w - margin, y: vf.maxY - h - margin),
            CGPoint(x: vf.minX + margin, y: vf.maxY - h - margin),
            CGPoint(x: vf.maxX - w - margin, y: vf.minY + margin),
            CGPoint(x: vf.minX + margin, y: vf.minY + margin),
        ]
        guard let canvasCG else { return corners[0] }
        let canvas = toCocoa(canvasCG)
        let center = CGPoint(x: canvas.midX, y: canvas.midY)
        let clear = corners.filter { !CGRect(origin: $0, size: size).intersects(canvas) }
        guard !clear.isEmpty else { return corners[0] }
        return clear.max { a, b in
            hypot(a.x + w / 2 - center.x, a.y + h / 2 - center.y) < hypot(b.x + w / 2 - center.x, b.y + h / 2 - center.y)
        } ?? corners[0]
    }

    /// Applies the collection behavior every DrawBot window needs to appear over full-screen apps.
    static func applyAllSpaces(_ window: NSWindow) {
        window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
    }

    static func activateSelf() {
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension RGB {
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

/// NSHostingView that takes the first click even when its window is not key / the app is
/// inactive, so ONE click on a button in a non-activating panel works.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Clicks on SwiftUI controls must never start a window drag.
    override var mouseDownCanMoveWindow: Bool { false }
}
