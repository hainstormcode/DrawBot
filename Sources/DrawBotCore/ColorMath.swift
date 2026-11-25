import Foundation

public struct LabColor: Sendable, Equatable {
    public var L: Double
    public var a: Double
    public var b: Double
    public init(L: Double, a: Double, b: Double) { self.L = L; self.a = a; self.b = b }
}

public enum ColorMath {
    // D65 reference white (CIE 1931 2°), Y normalized to 1.
    static let whiteX = 0.95047
    static let whiteY = 1.0
    static let whiteZ = 1.08883

    /// sRGB 8-bit component → linear-light 0...1.
    static let srgbToLinearTable: [Double] = (0..<256).map { i in
        let c = Double(i) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    @inline(__always)
    static func labF(_ t: Double) -> Double {
        // δ = 6/29; δ³ = 216/24389
        t > 216.0 / 24389.0 ? cbrt(t) : (t * (24389.0 / 27.0) + 16) / 116
    }

    @inline(__always)
    static func labFInverse(_ t: Double) -> Double {
        t > 6.0 / 29.0 ? t * t * t : (116 * t - 16) * (27.0 / 24389.0)
    }

    @inline(__always)
    static func linearToSRGB(_ c: Double) -> Double {
        c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    /// sRGB 8-bit components → Lab (fast path used by the quantizer).
    @inline(__always)
    static func lab(r: UInt8, g: UInt8, b: UInt8) -> (L: Double, a: Double, b: Double) {
        let rl = srgbToLinearTable[Int(r)]
        let gl = srgbToLinearTable[Int(g)]
        let bl = srgbToLinearTable[Int(b)]
        let x = (0.4124564 * rl + 0.3575761 * gl + 0.1804375 * bl) / whiteX
        let y = (0.2126729 * rl + 0.7151522 * gl + 0.0721750 * bl) / whiteY
        let z = (0.0193339 * rl + 0.1191920 * gl + 0.9503041 * bl) / whiteZ
        let fx = labF(x), fy = labF(y), fz = labF(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// sRGB (D65) → CIELAB.
    public static func lab(_ c: RGB) -> LabColor {
        let v = lab(r: c.r, g: c.g, b: c.b)
        return LabColor(L: v.L, a: v.a, b: v.b)
    }

    /// CIELAB → sRGB, clamped.
    public static func rgb(_ lab: LabColor) -> RGB {
        let fy = (lab.L + 16) / 116
        let fx = fy + lab.a / 500
        let fz = fy - lab.b / 200
        let x = labFInverse(fx) * whiteX
        let y = labFInverse(fy) * whiteY
        let z = labFInverse(fz) * whiteZ
        let rl = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
        let gl = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
        let bl = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z
        func to8(_ v: Double) -> UInt8 {
            let s = linearToSRGB(min(1, max(0, v)))
            return UInt8(min(255, max(0, (s * 255).rounded())))
        }
        return RGB(r: to8(rl), g: to8(gl), b: to8(bl))
    }

    /// CIE76 ΔE between two Lab colors.
    public static func deltaE(_ x: LabColor, _ y: LabColor) -> Double {
        let dL = x.L - y.L, da = x.a - y.a, db = x.b - y.b
        return (dL * dL + da * da + db * db).squareRoot()
    }

    /// CIE76 ΔE.
    public static func deltaE(_ x: RGB, _ y: RGB) -> Double {
        deltaE(lab(x), lab(y))
    }

    /// Lab chroma, sqrt(a² + b²).
    public static func chroma(_ c: RGB) -> Double {
        let l = lab(c)
        return (l.a * l.a + l.b * l.b).squareRoot()
    }

    /// L* ≥ 92 and chroma < 8 — a color that is effectively the white paper.
    public static func isNearWhite(_ c: RGB) -> Bool {
        let l = lab(c)
        return l.L >= 92 && (l.a * l.a + l.b * l.b).squareRoot() < 8
    }

    /// Hue 0..<360, saturation 0...100, brightness 0...100 (as shown in macOS / most color pickers).
    public static func hsb(_ c: RGB) -> (h: Double, s: Double, b: Double) {
        let r = Double(c.r) / 255, g = Double(c.g) / 255, b = Double(c.b) / 255
        let mx = max(r, g, b), mn = min(r, g, b)
        let d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r {
                h = 60 * ((g - b) / d)
            } else if mx == g {
                h = 60 * ((b - r) / d + 2)
            } else {
                h = 60 * ((r - g) / d + 4)
            }
            if h < 0 { h += 360 }
            if h >= 360 { h -= 360 }
        }
        let s = mx > 0 ? d / mx * 100 : 0
        return (h, s, mx * 100)
    }

    /// A short human name, e.g. "dark red", "light gray", "black".
    public static func approximateName(_ c: RGB) -> String {
        let (h, s, v) = hsb(c)
        let L = lab(c).L

        if v < 10 { return "black" }
        // Achromatic.
        if s < 12 || (v < 25 && s < 30) {
            if L >= 95 { return "white" }
            if L < 12 { return "black" }
            if L >= 80 { return "light gray" }
            if L < 35 { return "dark gray" }
            return "gray"
        }

        // Brown = dark/low-brightness orange (and nearby red-orange / dark yellow-orange).
        if h >= 15 && h < 50 && v < 70 {
            if v < 40 { return "dark brown" }
            if s < 45 { return "light brown" }
            return "brown"
        }

        let family: String
        switch h {
        case ..<12: family = "red"
        case ..<40: family = "orange"
        case ..<65: family = "yellow"
        case ..<85: family = "lime"
        case ..<150: family = "green"
        case ..<172: family = "teal"
        case ..<190: family = "cyan"
        case ..<255: family = "blue"
        case ..<285: family = "purple"
        case ..<320: family = "magenta"
        case ..<345: family = "pink"
        default: family = "red"
        }

        // Light, desaturated reds are pinks.
        if family == "red" && s < 60 && v > 80 {
            return s < 35 ? "pale pink" : "pink"
        }

        if v < 55 { return "dark " + family }
        if s < 35 && v > 80 { return "pale " + family }
        if s < 65 && v > 80 { return "light " + family }
        return family
    }

    /// Palette indices with count > 0, in the requested drawing order. Ties broken by index.
    public static func order(_ q: QuantizedImage, by order: ColorOrder) -> [Int] {
        let n = min(q.palette.count, q.counts.count)
        let live = (0..<n).filter { q.counts[$0] > 0 }
        switch order {
        case .lightToDark, .darkToLight:
            let L = live.map { lab(q.palette[$0]).L }
            var idx = Array(live.indices)
            idx.sort { i, j in
                if L[i] != L[j] { return order == .lightToDark ? L[i] > L[j] : L[i] < L[j] }
                return live[i] < live[j]
            }
            return idx.map { live[$0] }
        case .mostPixelsFirst:
            return live.sorted { q.counts[$0] != q.counts[$1] ? q.counts[$0] > q.counts[$1] : $0 < $1 }
        case .fewestPixelsFirst:
            return live.sorted { q.counts[$0] != q.counts[$1] ? q.counts[$0] < q.counts[$1] : $0 < $1 }
        }
    }
}
