import CoreGraphics
import Foundation

/// Cocoa global coordinates: origin bottom-left of the PRIMARY screen (NSScreen.screens[0]), y up.
/// CG global coordinates: origin top-left of the primary screen, y down. Both in points.
public enum Geometry {
    public static func cocoaToCG(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        let r = rect.standardized
        return CGRect(x: r.origin.x, y: primaryScreenHeight - (r.origin.y + r.height),
                      width: r.width, height: r.height)
    }

    public static func cgToCocoa(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        // The flip is its own inverse.
        let r = rect.standardized
        return CGRect(x: r.origin.x, y: primaryScreenHeight - (r.origin.y + r.height),
                      width: r.width, height: r.height)
    }

    public static func cocoaToCG(_ point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    public static func cgToCocoa(_ point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    /// Rect spanned by two drag corners (any order), rounded outward to whole points.
    public static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        let minX = floor(min(a.x, b.x)), minY = floor(min(a.y, b.y))
        let maxX = ceil(max(a.x, b.x)), maxY = ceil(max(a.y, b.y))
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Clamp a point into a rect (inclusive of max edges).
    public static func clamp(_ p: CGPoint, to r: CGRect) -> CGPoint {
        let s = r.standardized
        return CGPoint(x: min(max(p.x, s.minX), s.maxX), y: min(max(p.y, s.minY), s.maxY))
    }
}
