import AppKit
import CoreGraphics
import DrawBotCore
import ScreenCaptureKit

/// Screenshots of a screen rectangle, for learning fixed color palettes (Color Learn watches
/// which color the app shows after each swatch click). Needs the Screen Recording permission
/// (System Settings → Privacy & Security → Screen & System Audio Recording) and macOS 14.
public enum ScreenSampler {
    public static var isSupported: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    /// Never prompts.
    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt (or adds DrawBot to the list, switched off). macOS usually only
    /// applies a new grant after the app relaunches.
    public static func requestPermission() { _ = CGRequestScreenCaptureAccess() }

    public enum CaptureError: Error { case unsupported, noDisplay, noImage }

    /// Captures `rect` (CG global points) at one pixel per point as sRGB, leaving out DrawBot's
    /// own windows and the cursor.
    public static func capture(_ rect: CGRect) async throws -> RGBAImage {
        guard #available(macOS 14.0, *) else { throw CaptureError.unsupported }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let display = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(center) }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        let bounds = CGDisplayBounds(display.displayID)
        let clipped = rect.intersection(bounds).integral
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { throw CaptureError.noImage }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = clipped.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
        config.width = Int(clipped.width)
        config.height = Int(clipped.height)
        config.showsCursor = false
        config.colorSpaceName = CGColorSpace.sRGB
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return rgba(image, width: Int(clipped.width), height: Int(clipped.height))
    }

    /// Draws `image` into an sRGB RGBA buffer of the given size.
    static func rgba(_ image: CGImage, width: Int, height: Int) -> RGBAImage {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        data.withUnsafeMutableBytes { buf in
            if let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                   space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .none
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        return RGBAImage(width: width, height: height, data: data)
    }
}
