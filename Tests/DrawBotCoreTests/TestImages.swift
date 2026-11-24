import CoreGraphics
import Foundation
@testable import DrawBotCore

/// Builders for synthetic test images (no fixture files).
enum TestImages {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Draws with CoreGraphics into a width×height context. Note: CG user space has y UP,
    /// so `CGRect(x: 0, y: height/2, …)` is the TOP half of the picture.
    static func make(width: Int, height: Int, opaque: Bool = false,
                     _ body: (CGContext) -> Void) -> CGImage {
        let info = (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: sRGB, bitmapInfo: info)!
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        body(ctx)
        return ctx.makeImage()!
    }

    static func fill(_ ctx: CGContext, _ rect: CGRect, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) {
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: a))
        ctx.fill(rect)
    }

    /// RGBAImage directly from a pixel function (row 0 = top).
    static func rgba(width: Int, height: Int, _ px: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> RGBAImage {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = px(x, y)
                let i = (y * width + x) * 4
                data[i] = r; data[i + 1] = g; data[i + 2] = b; data[i + 3] = a
            }
        }
        return RGBAImage(width: width, height: height, data: data)
    }

    /// Photo-like synthetic image: smooth gradients + soft blobs + noise (deterministic).
    static func photoLike(width: Int, height: Int, seed: UInt64 = 42) -> RGBAImage {
        var rng = SplitMix64(seed: seed)
        return rgba(width: width, height: height) { x, y in
            let fx = Double(x) / Double(width), fy = Double(y) / Double(height)
            let blob = exp(-((fx - 0.3) * (fx - 0.3) + (fy - 0.6) * (fy - 0.6)) * 12)
            let blob2 = exp(-((fx - 0.75) * (fx - 0.75) + (fy - 0.25) * (fy - 0.25)) * 20)
            let noise = Double(rng.next() % 17) - 8
            func c(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v + noise))) }
            return (c(40 + 180 * fx + 30 * blob2), c(60 + 150 * blob + 40 * sin(fy * 9)),
                    c(200 - 150 * fy + 50 * blob2), 255)
        }
    }

    static func pixel(_ img: RGBAImage, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let i = (y * img.width + x) * 4
        return (img.data[i], img.data[i + 1], img.data[i + 2], img.data[i + 3])
    }
}
