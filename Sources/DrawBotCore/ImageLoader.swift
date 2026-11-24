import CoreGraphics
import Foundation
import ImageIO

public enum ImageLoaderError: Error, LocalizedError {
    case cannotOpen(URL)
    case cannotDecode(URL)
    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let u): return "Could not open \(u.lastPathComponent)."
        case .cannotDecode(let u): return "\(u.lastPathComponent) is not a readable image."
        }
    }
}

public enum ImageLoader {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    static let premultipliedRGBA = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

    /// Loads the first frame of any ImageIO-readable file (PNG, JPEG, HEIC, WebP, GIF, TIFF, BMP, …),
    /// with EXIF orientation applied so the returned image is upright.
    public static func loadCGImage(from url: URL) throws -> CGImage {
        guard FileManager.default.isReadableFile(atPath: url.path),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageLoaderError.cannotOpen(url)
        }
        guard let img = image(from: src) else { throw ImageLoaderError.cannotDecode(url) }
        return img
    }

    /// Decodes in-memory image data (e.g. a pasted PNG/TIFF) with orientation applied.
    public static func loadCGImage(data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return image(from: src)
    }

    private static func image(from src: CGImageSource) -> CGImage? {
        guard CGImageSourceGetCount(src) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let pw = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let ph = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        if pw > 0 && ph > 0 {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: max(pw, ph),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let t = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { return t }
        }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Wraps an RGBAImage (straight alpha) as a CGImage — handy for previews.
    public static func makeCGImage(_ image: RGBAImage) -> CGImage? {
        guard image.width > 0, image.height > 0 else { return nil }
        let info = CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let provider = CGDataProvider(data: Data(image.data) as CFData) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: image.width * 4, space: sRGB, bitmapInfo: CGBitmapInfo(rawValue: info),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Scales `image` to fit inside width×height (aspect preserved, centred, high-quality
    /// downsampling). Area not covered by the image has alpha 0. Output alpha is straight
    /// (un-premultiplied). Row 0 of the result is the top of the picture.
    ///
    /// The fitted image is snapped to whole pixels. Downscales by more than 2× use an exact
    /// area-average (box) filter so thin details are not lost to aliasing; upscales of images
    /// with few colours (pixel art, logos) use nearest-neighbour to keep edges crisp.
    public static func rasterize(_ image: CGImage, width: Int, height: Int) -> RGBAImage {
        let w = max(1, width), h = max(1, height)
        let iw = image.width, ih = image.height
        guard iw > 0, ih > 0 else {
            return RGBAImage(width: w, height: h, data: [UInt8](repeating: 0, count: w * h * 4))
        }
        let scale = min(Double(w) / Double(iw), Double(h) / Double(ih))
        let dw = min(w, max(1, Int((Double(iw) * scale).rounded())))
        let dh = min(h, max(1, Int((Double(ih) * scale).rounded())))
        let ox = (w - dw) / 2, oy = (h - dh) / 2  // offsets from top-left

        // Premultiplied RGBA of the fitted image, dw×dh, as Float (0...255 scale).
        var fitted: [Float]
        let sx = Double(iw) / Double(dw), sy = Double(ih) / Double(dh)
        if sx > 2 || sy > 2 {
            // Decode at (at most) native size, then box-filter down.
            var srcW = iw, srcH = ih
            if iw * ih > 40_000_000 {
                srcW = min(iw, dw * 4); srcH = min(ih, dh * 4)
            }
            guard let src = draw(image, width: srcW, height: srcH, interpolation: .high) else {
                return RGBAImage(width: w, height: h, data: [UInt8](repeating: 0, count: w * h * 4))
            }
            fitted = boxDownsample(src, srcW: srcW, srcH: srcH, dstW: dw, dstH: dh)
        } else {
            var interp = CGInterpolationQuality.high
            if scale > 1, let native = draw(image, width: iw, height: ih, interpolation: .none),
               hasFewColors(native, limit: 64) {
                interp = .none
            }
            guard let bytes = draw(image, width: dw, height: dh, interpolation: interp) else {
                return RGBAImage(width: w, height: h, data: [UInt8](repeating: 0, count: w * h * 4))
            }
            fitted = bytes.map { Float($0) }
        }

        // Place into the w×h output and un-premultiply.
        var out = [UInt8](repeating: 0, count: w * h * 4)
        fitted.withUnsafeBufferPointer { f in
            out.withUnsafeMutableBufferPointer { o in
                for y in 0..<dh {
                    for x in 0..<dw {
                        let si = (y * dw + x) * 4
                        let di = ((y + oy) * w + (x + ox)) * 4
                        let a = f[si + 3]
                        guard a > 0.5 else { continue }
                        let k = 255 / a
                        o[di] = UInt8(min(255, max(0, (f[si] * k).rounded())))
                        o[di + 1] = UInt8(min(255, max(0, (f[si + 1] * k).rounded())))
                        o[di + 2] = UInt8(min(255, max(0, (f[si + 2] * k).rounded())))
                        o[di + 3] = UInt8(min(255, max(0, a.rounded())))
                    }
                }
            }
        }
        return RGBAImage(width: w, height: h, data: out)
    }

    /// Draws `image` stretched to exactly width×height into an sRGB premultipliedLast 8-bit
    /// buffer cleared to transparent. Row 0 of the buffer is the top of the picture.
    static func draw(_ image: CGImage, width: Int, height: Int, interpolation: CGInterpolationQuality) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: sRGB, bitmapInfo: premultipliedRGBA) else {
                return false
            }
            ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.interpolationQuality = interpolation
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? buf : nil
    }

    static func hasFewColors(_ rgba: [UInt8], limit: Int) -> Bool {
        var seen = Set<UInt32>()
        var last: UInt32 = .max
        var i = 0
        while i < rgba.count {
            let key = UInt32(rgba[i]) << 24 | UInt32(rgba[i + 1]) << 16 | UInt32(rgba[i + 2]) << 8 | UInt32(rgba[i + 3])
            if key != last {
                seen.insert(key)
                if seen.count > limit { return false }
                last = key
            }
            i += 4
        }
        return true
    }

    /// Exact area-average resample of a premultiplied RGBA buffer (separable, fractional weights).
    static func boxDownsample(_ src: [UInt8], srcW: Int, srcH: Int, dstW: Int, dstH: Int) -> [Float] {
        func weights(src: Int, dst: Int) -> [(first: Int, w: [Float])] {
            let ratio = Double(src) / Double(dst)
            return (0..<dst).map { d in
                let a = Double(d) * ratio, b = Double(d + 1) * ratio
                let first = Int(a.rounded(.down))
                let last = min(src - 1, Int(b.rounded(.up)) - 1)
                var ws: [Float] = []
                if last >= first {
                    for s in first...last {
                        let cover = min(b, Double(s + 1)) - max(a, Double(s))
                        ws.append(Float(max(0, cover) / ratio))
                    }
                }
                return (first, ws)
            }
        }
        let wx = weights(src: srcW, dst: dstW)
        let wy = weights(src: srcH, dst: dstH)
        // Horizontal pass: srcH × dstW.
        var tmp = [Float](repeating: 0, count: srcH * dstW * 4)
        src.withUnsafeBufferPointer { s in
            tmp.withUnsafeMutableBufferPointer { t in
                for y in 0..<srcH {
                    let sRow = y * srcW * 4, tRow = y * dstW * 4
                    for x in 0..<dstW {
                        let (first, ws) = wx[x]
                        var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 0
                        for (k, wt) in ws.enumerated() {
                            let si = sRow + (first + k) * 4
                            r += Float(s[si]) * wt; g += Float(s[si + 1]) * wt
                            b += Float(s[si + 2]) * wt; a += Float(s[si + 3]) * wt
                        }
                        let ti = tRow + x * 4
                        t[ti] = r; t[ti + 1] = g; t[ti + 2] = b; t[ti + 3] = a
                    }
                }
            }
        }
        // Vertical pass: dstH × dstW.
        var out = [Float](repeating: 0, count: dstH * dstW * 4)
        tmp.withUnsafeBufferPointer { t in
            out.withUnsafeMutableBufferPointer { o in
                for y in 0..<dstH {
                    let (first, ws) = wy[y]
                    let oRow = y * dstW * 4
                    for (k, wt) in ws.enumerated() {
                        let tRow = (first + k) * dstW * 4
                        for i in 0..<(dstW * 4) { o[oRow + i] += t[tRow + i] * wt }
                    }
                }
            }
        }
        return out
    }
}
