import CoreGraphics
import Foundation

// Shared value types. These signatures are the contract between modules — do not rename or
// change existing members. Adding members is fine.

/// An opaque 8-bit sRGB color.
public struct RGB: Hashable, Sendable, Codable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// "#RRGGBB", uppercase.
    public var hex: String { String(format: "#%02X%02X%02X", r, g, b) }

    /// Hex without the leading "#" (what most color pickers' hex fields want).
    public var hexNoHash: String { String(format: "%02X%02X%02X", r, g, b) }

    public var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

/// A raster at grid resolution. Row 0 is the TOP row. Pixels are RGBA, 8 bits each,
/// straight (NOT premultiplied) alpha. `data.count == width * height * 4`.
public struct RGBAImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var data: [UInt8]

    public init(width: Int, height: Int, data: [UInt8]) {
        precondition(data.count == width * height * 4, "RGBAImage data size mismatch")
        self.width = width
        self.height = height
        self.data = data
    }
}

/// Result of color quantization. `labels[row * width + col]` is a palette index, or -1 for
/// transparent / empty (never drawn). Row 0 is the TOP row.
public struct QuantizedImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let labels: [Int32]
    /// Palette index == label value. Every palette entry has count > 0.
    public let palette: [RGB]
    /// Number of pixels carrying each palette index; `counts.count == palette.count`.
    public let counts: [Int]

    public init(width: Int, height: Int, labels: [Int32], palette: [RGB], counts: [Int]) {
        self.width = width
        self.height = height
        self.labels = labels
        self.palette = palette
        self.counts = counts
    }
}

public struct QuantizeOptions: Sendable, Codable, Equatable {
    /// Upper bound on palette size, clamped to 1...64.
    public var maxColors: Int = 8
    /// Pixels with alpha below this are transparent (label -1).
    public var alphaThreshold: UInt8 = 128
    /// Clusters whose centers are closer than this CIE76 ΔE are merged ("rounding similar colors together").
    public var mergeDistance: Double = 6.0
    /// Deterministic seed — identical input + options must give identical output.
    public var seed: UInt64 = 0x5EED

    public init(maxColors: Int = 8, alphaThreshold: UInt8 = 128, mergeDistance: Double = 6.0, seed: UInt64 = 0x5EED) {
        self.maxColors = maxColors
        self.alphaThreshold = alphaThreshold
        self.mergeDistance = mergeDistance
        self.seed = seed
    }
}

/// Maps grid cells onto the screen. All coordinates are CoreGraphics GLOBAL display
/// coordinates in points: origin at the top-left of the primary display, y grows DOWN.
/// (This is the space CGEvent locations use.)
public struct GridLayout: Sendable, Equatable {
    /// The canvas rectangle the user dragged, CG global coords.
    public let canvas: CGRect
    /// Distance in points between neighboring cell centers (≈ brush diameter).
    public let penSize: Double
    public let columns: Int
    public let rows: Int
    /// Top-left corner of cell (0,0). The grid (columns*penSize × rows*penSize) is centerd in `canvas`.
    public let origin: CGPoint

    public init(canvas: CGRect, penSize: Double) {
        let pen = max(0.5, penSize)
        let canvas = canvas.standardized
        self.canvas = canvas
        self.penSize = pen
        let cols = max(1, Int((Double(canvas.width) / pen).rounded(.down)))
        let rws = max(1, Int((Double(canvas.height) / pen).rounded(.down)))
        self.columns = cols
        self.rows = rws
        let gridW = Double(cols) * pen
        let gridH = Double(rws) * pen
        self.origin = CGPoint(x: Double(canvas.minX) + (Double(canvas.width) - gridW) / 2,
                              y: Double(canvas.minY) + (Double(canvas.height) - gridH) / 2)
    }

    /// Center of a cell in CG global coordinates.
    public func cellCenter(col: Int, row: Int) -> CGPoint {
        CGPoint(x: Double(origin.x) + (Double(col) + 0.5) * penSize,
                y: Double(origin.y) + (Double(row) + 0.5) * penSize)
    }
}

/// A horizontal run of same-colored cells in one grid row. Both ends inclusive.
/// `startCol > endCol` means the run is drawn right-to-left (serpentine ordering).
public struct GridRun: Sendable, Equatable {
    public let row: Int
    public let startCol: Int
    public let endCol: Int

    public init(row: Int, startCol: Int, endCol: Int) {
        self.row = row
        self.startCol = startCol
        self.endCol = endCol
    }

    public var length: Int { abs(endCol - startCol) + 1 }
}

/// One press-drag-release gesture in CG global coordinates. `start == end` is a single dot.
public struct ScreenStroke: Sendable, Equatable {
    public let start: CGPoint
    public let end: CGPoint

    public init(start: CGPoint, end: CGPoint) {
        self.start = start
        self.end = end
    }

    public var isDot: Bool { start == end }
    public var length: Double { Double(hypot(end.x - start.x, end.y - start.y)) }
}

public enum ColorOrder: String, Codable, CaseIterable, Sendable {
    case lightToDark
    case darkToLight
    case mostPixelsFirst
    case fewestPixelsFirst

    public var displayName: String {
        switch self {
        case .lightToDark: return "Light → dark"
        case .darkToLight: return "Dark → light"
        case .mostPixelsFirst: return "Most area first"
        case .fewestPixelsFirst: return "Least area first"
        }
    }
}

/// Timing of synthetic mouse events.
public struct SpeedSettings: Codable, Equatable, Sendable {
    /// Max distance in points between consecutive drag events along a stroke.
    public var stepSize: Double
    /// Pause after each drag event, seconds.
    public var eventDelay: Double
    /// Pause after mouse-down before the first drag, seconds.
    public var downDelay: Double
    /// Pause after mouse-up, seconds.
    public var upDelay: Double
    /// Pause after the hover move to a stroke's start (before mouse-down), seconds.
    public var moveDelay: Double

    public init(stepSize: Double, eventDelay: Double, downDelay: Double, upDelay: Double, moveDelay: Double) {
        self.stepSize = stepSize
        self.eventDelay = eventDelay
        self.downDelay = downDelay
        self.upDelay = upDelay
        self.moveDelay = moveDelay
    }

    /// For laggy apps / browser canvases that drop events.
    public static let careful = SpeedSettings(stepSize: 2, eventDelay: 0.006, downDelay: 0.030, upDelay: 0.030, moveDelay: 0.020)
    public static let normal = SpeedSettings(stepSize: 4, eventDelay: 0.003, downDelay: 0.015, upDelay: 0.015, moveDelay: 0.010)
    public static let fast = SpeedSettings(stepSize: 8, eventDelay: 0.0015, downDelay: 0.008, upDelay: 0.008, moveDelay: 0.005)
    public static let ludicrous = SpeedSettings(stepSize: 16, eventDelay: 0.0008, downDelay: 0.004, upDelay: 0.004, moveDelay: 0.003)
}

public enum SpeedPreset: String, Codable, CaseIterable, Sendable {
    case careful, normal, fast, ludicrous

    public var settings: SpeedSettings {
        switch self {
        case .careful: return .careful
        case .normal: return .normal
        case .fast: return .fast
        case .ludicrous: return .ludicrous
        }
    }

    public var displayName: String {
        switch self {
        case .careful: return "Careful (laggy apps / browsers)"
        case .normal: return "Normal"
        case .fast: return "Fast"
        case .ludicrous: return "Ludicrous"
        }
    }
}
