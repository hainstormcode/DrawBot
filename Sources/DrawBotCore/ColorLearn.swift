import CoreGraphics
import Foundation

// Color Learn: vocabulary shared by the recorder (app), the learner (ColorLearner) and the
// replayer (DrawBotSystem.InputReplayer).
//
// The user selects two (or more) requested colors in their drawing app's color picker while
// DrawBot records the mouse and keyboard. ColorLearner turns those demonstrations into a
// `ColorPickerProfile`: the sequence of clicks / drags / keystrokes, with every color-dependent
// part generalized (where to click in a saturation square, what to type into a hex field…).
// `ColorPickerProfile.actions(for:previous:)` then produces concrete input for any color.
// All points are CG global coordinates (top-left origin, y down).

// MARK: - Input primitives

public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
}

public enum PointerButton: Int, Codable, Sendable {
    case left = 0
    case right = 1
}

/// One key press (down + up), as a virtual key code plus the characters it produced.
public struct KeyStroke: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    public var characters: String
    public var modifiers: KeyModifiers

    public init(keyCode: UInt16, characters: String, modifiers: KeyModifiers = []) {
        self.keyCode = keyCode
        self.characters = characters
        self.modifiers = modifiers
    }

    /// ⌘ or ⌃ held: a shortcut, not text.
    public var isShortcut: Bool { !modifiers.isDisjoint(with: [.command, .control]) }
}

/// macOS virtual key codes (ANSI layout) used by Color Learn.
public enum VirtualKey {
    public static let a: UInt16 = 0
    public static let v: UInt16 = 9
    public static let returnKey: UInt16 = 36
    public static let tab: UInt16 = 48
    public static let space: UInt16 = 49
    public static let delete: UInt16 = 51
    public static let escape: UInt16 = 53
    public static let enter: UInt16 = 76
    public static let forwardDelete: UInt16 = 117

    /// Keys that never produce text, even when their `characters` is non-empty.
    static let nonText: Set<UInt16> = [36, 48, 51, 53, 76, 117, 123, 124, 125, 126, 115, 119, 116, 121,
                                       122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    /// US ANSI fallback for characters DrawBot never saw the user type: char → (key code, shift).
    static let usANSI: [Character: (UInt16, Bool)] = {
        var m: [Character: (UInt16, Bool)] = [:]
        let letters: [(Character, UInt16)] = [("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6),
                                              ("x", 7), ("c", 8), ("v", 9), ("b", 11), ("q", 12), ("w", 13), ("e", 14),
                                              ("r", 15), ("y", 16), ("t", 17), ("o", 31), ("u", 32), ("i", 34), ("p", 35),
                                              ("l", 37), ("j", 38), ("k", 40), ("n", 45), ("m", 46)]
        for (ch, code) in letters {
            m[ch] = (code, false)
            m[Character(ch.uppercased())] = (code, true)
        }
        let digits: [(Character, UInt16)] = [("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22), ("5", 23),
                                             ("9", 25), ("7", 26), ("8", 28), ("0", 29)]
        for (ch, code) in digits { m[ch] = (code, false) }
        m["#"] = (20, true)
        m["%"] = (23, true)
        m["."] = (47, false)
        m[","] = (43, false)
        m["-"] = (27, false)
        m[" "] = (49, false)
        m["/"] = (44, false)
        m[";"] = (41, false)
        m[":"] = (41, true)
        m["("] = (25, true)
        m[")"] = (29, true)
        return m
    }()

    /// A keystroke that types `ch` on a US layout (the replayer also sends the character itself,
    /// so most apps get the right text on any layout).
    public static func stroke(for ch: Character) -> KeyStroke {
        if let (code, shift) = usANSI[ch] {
            return KeyStroke(keyCode: code, characters: String(ch), modifiers: shift ? [.shift] : [])
        }
        return KeyStroke(keyCode: 0xFFFF, characters: String(ch), modifiers: [])
    }
}

// MARK: - Recording

/// One recorded input event.
public struct RecordedInput: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case mouseDown, mouseDragged, mouseUp, keyDown
    }

    public var kind: Kind
    /// Seconds (any monotonic clock; only differences matter).
    public var time: TimeInterval
    /// CG global coordinates. For key events: wherever the cursor was.
    public var point: CGPoint
    public var button: PointerButton
    /// 1 for a single click, 2 for the second press of a double-click, …
    public var clickCount: Int
    public var keyCode: UInt16
    /// Characters produced (for shortcuts: the characters ignoring modifiers).
    public var characters: String
    public var modifiers: KeyModifiers
    /// For a paste shortcut (⌘V): the clipboard text at that moment.
    public var pasteText: String?

    public init(kind: Kind, time: TimeInterval, point: CGPoint = .zero, button: PointerButton = .left,
                clickCount: Int = 1, keyCode: UInt16 = 0, characters: String = "", modifiers: KeyModifiers = [],
                pasteText: String? = nil) {
        self.kind = kind
        self.time = time
        self.point = point
        self.button = button
        self.clickCount = clickCount
        self.keyCode = keyCode
        self.characters = characters
        self.modifiers = modifiers
        self.pasteText = pasteText
    }

    public static func mouse(_ kind: Kind, at point: CGPoint, time: TimeInterval, button: PointerButton = .left,
                             clickCount: Int = 1, modifiers: KeyModifiers = []) -> RecordedInput {
        RecordedInput(kind: kind, time: time, point: point, button: button, clickCount: clickCount, modifiers: modifiers)
    }

    public static func key(_ keyCode: UInt16, _ characters: String, time: TimeInterval, modifiers: KeyModifiers = [],
                           pasteText: String? = nil) -> RecordedInput {
        RecordedInput(kind: .keyDown, time: time, keyCode: keyCode, characters: characters, modifiers: modifiers,
                      pasteText: pasteText)
    }
}

/// The user selecting one requested color.
public struct ColorDemo: Codable, Equatable, Sendable {
    /// The color DrawBot asked for.
    public var color: RGB
    /// The color the picker showed before this demo, when known (the previous demo's color).
    public var previousColor: RGB?
    public var inputs: [RecordedInput]

    public init(color: RGB, previousColor: RGB? = nil, inputs: [RecordedInput]) {
        self.color = color
        self.previousColor = previousColor
        self.inputs = inputs
    }
}

// MARK: - Color parameters

/// A number a color picker lets you set.
public enum ColorParam: String, Codable, CaseIterable, Sendable {
    case red, green, blue
    case hue
    case hsbSaturation, hsbBrightness
    case hslSaturation, hslLightness

    /// Natural full range: 255 for RGB, 360 for hue, 100 for the rest.
    public var range: Double {
        switch self {
        case .red, .green, .blue: return 255
        case .hue: return 360
        default: return 100
        }
    }

    public var displayName: String {
        switch self {
        case .red: return "red"
        case .green: return "green"
        case .blue: return "blue"
        case .hue: return "hue"
        case .hsbSaturation: return "saturation"
        case .hsbBrightness: return "brightness"
        case .hslSaturation: return "saturation (HSL)"
        case .hslLightness: return "lightness"
        }
    }

    public func value(of c: RGB) -> Double {
        switch self {
        case .red: return Double(c.r)
        case .green: return Double(c.g)
        case .blue: return Double(c.b)
        case .hue: return ColorMath.hsb(c).h
        case .hsbSaturation: return ColorMath.hsb(c).s
        case .hsbBrightness: return ColorMath.hsb(c).b
        case .hslSaturation: return ColorMath.hsl(c).s
        case .hslLightness: return ColorMath.hsl(c).l
        }
    }
}

public enum PickerColorSpace: String, Codable, CaseIterable, Sendable {
    case hsb, hsl, rgb

    public var params: [ColorParam] {
        switch self {
        case .hsb: return [.hue, .hsbSaturation, .hsbBrightness]
        case .hsl: return [.hue, .hslSaturation, .hslLightness]
        case .rgb: return [.red, .green, .blue]
        }
    }

    /// True when knowing `params` pins down the whole color.
    static func determines(_ params: Set<ColorParam>) -> Bool {
        allCases.contains { params.isSuperset(of: $0.params) }
    }
}

extension ColorMath {
    /// Hue 0..<360, saturation 0...100, lightness 0...100 (HSL, as in CSS and Windows pickers).
    public static func hsl(_ c: RGB) -> (h: Double, s: Double, l: Double) {
        let r = Double(c.r) / 255, g = Double(c.g) / 255, b = Double(c.b) / 255
        let mx = max(r, g, b), mn = min(r, g, b)
        let d = mx - mn
        let l = (mx + mn) / 2
        let denom = 1 - abs(2 * l - 1)
        let s = d == 0 || denom <= 0 ? 0 : min(1, d / denom)
        return (hsb(c).h, s * 100, l * 100)
    }

    /// HSB (hue in degrees, saturation and brightness 0...100) → sRGB.
    public static func rgb(hue: Double, saturation: Double, brightness: Double) -> RGB {
        var h = hue.truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        h /= 60
        let s = min(max(saturation / 100, 0), 1), v = min(max(brightness / 100, 0), 1)
        let c = v * s
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let rgb: (Double, Double, Double)
        switch Int(h) {
        case 0: rgb = (c, x, 0)
        case 1: rgb = (x, c, 0)
        case 2: rgb = (0, c, x)
        case 3: rgb = (0, x, c)
        case 4: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        func to8(_ u: Double) -> UInt8 { UInt8(min(255, max(0, ((u + m) * 255).rounded()))) }
        return RGB(r: to8(rgb.0), g: to8(rgb.1), b: to8(rgb.2))
    }
}

// MARK: - Typed values

/// A color-dependent value the user typed (or pasted).
public enum ValueSlot: Codable, Hashable, Sendable {
    /// Six hex digits, no "#".
    case hex(uppercase: Bool)
    /// `param` scaled so its full range is `fullScale` (255, 100, 1, 360…), with `decimals` digits.
    case number(param: ColorParam, fullScale: Double, decimals: Int)

    public func format(_ c: RGB) -> String {
        switch self {
        case .hex(let upper):
            return upper ? c.hexNoHash : c.hexNoHash.lowercased()
        case .number(let p, let scale, let decimals):
            var v = p.value(of: c) / p.range * scale
            if decimals == 0 {
                var i = Int(v.rounded())
                if p == .hue && Double(i) >= scale { i = 0 }
                return String(i)
            }
            if p == .hue && v >= scale { v = 0 }
            return String(format: "%.\(decimals)f", v)
        }
    }

    var params: Set<ColorParam> {
        switch self {
        case .hex: return [.red, .green, .blue]
        case .number(let p, _, _): return [p]
        }
    }

    /// Lower = preferred when several interpretations fit every demo.
    var priority: Int {
        switch self {
        case .hex: return 0
        case .number(let p, let scale, _):
            switch (p, scale) {
            case (.red, 255), (.green, 255), (.blue, 255): return 1
            case (.hue, 360): return 2
            case (.hsbSaturation, 100), (.hsbBrightness, 100): return 3
            case (.hslSaturation, 100), (.hslLightness, 100): return 4
            case (_, 1): return 5
            default: return 6
            }
        }
    }

    var displayName: String {
        switch self {
        case .hex: return "hex code"
        case .number(let p, _, _): return "\(p.displayName) value"
        }
    }
}

public enum TextPart: Codable, Equatable, Sendable {
    case literal(String)
    case slot(ValueSlot)
}

/// Text with color-dependent holes, e.g. "#" + hex, or red + ", " + green + ", " + blue.
public struct TextTemplate: Codable, Equatable, Sendable {
    public var parts: [TextPart]
    public init(parts: [TextPart]) { self.parts = parts }

    public func format(_ c: RGB) -> String {
        parts.map { part -> String in
            switch part {
            case .literal(let s): return s
            case .slot(let slot): return slot.format(c)
            }
        }.joined()
    }

    var slots: [ValueSlot] {
        parts.compactMap { if case .slot(let s) = $0 { return s } else { return nil } }
    }
}

// MARK: - Pointer mappings

public enum ScreenAxis: String, Codable, Sendable {
    case x, y
}

/// coordinate = offset + slope × param value.
public struct LinearMap: Codable, Equatable, Sendable {
    public var param: ColorParam
    public var offset: Double
    public var slope: Double

    public init(param: ColorParam, offset: Double, slope: Double) {
        self.param = param
        self.offset = offset
        self.slope = slope
    }

    /// `push` moves values at the very ends of the range outward (> 0, so a drag clamps onto the
    /// extreme) or inward (< 0, so a press lands inside the control).
    func coordinate(for c: RGB, push: Double) -> Double {
        let v = param.value(of: c)
        var pos = offset + slope * v
        let frac = v / param.range
        let dir: Double = slope >= 0 ? 1 : -1
        if frac <= 0.004 {
            pos -= dir * push
        } else if frac >= 0.996 {
            pos += dir * push
        }
        return pos
    }

    /// Margin kept from the estimated ends when pressing: the map is fitted to approximate
    /// human clicks, so its ends can be several points off the real control's edges, and a
    /// press just outside lands on a neighboring control.
    var safeInset: Double { max(5, 0.06 * extent) }

    /// The coordinate for `c`, moved inside the control by `safeInset` if it's closer to an end.
    func safeCoordinate(for c: RGB) -> Double {
        let iv = interval
        let pos = offset + slope * param.value(of: c)
        let m = min(safeInset, (iv.hi - iv.lo) / 2)
        return min(max(pos, iv.lo + m), iv.hi - m)
    }

    var interval: (lo: Double, hi: Double) {
        let a = offset, b = offset + slope * param.range
        return (min(a, b), max(a, b))
    }

    var extent: Double { abs(slope) * param.range }
}

/// Point = center + w × r × e^(i·direction·hue), with r = radius param / range (1 for a hue ring).
public struct PolarMap: Codable, Equatable, Sendable {
    public var radius: ColorParam?
    public var centerX: Double
    public var centerY: Double
    public var wRe: Double
    public var wIm: Double
    public var direction: Double

    var scale: Double { (wRe * wRe + wIm * wIm).squareRoot() }

    /// Like `point(for:push: 0)`, but with the radius kept `max(5 pt, 6%)` inside the rim.
    func safePoint(for c: RGB) -> CGPoint {
        guard let rp = radius else { return point(for: c, push: 0) }
        let limit = max(0, 1 - max(5, 0.06 * scale) / max(1, scale))
        let h = ColorParam.hue.value(of: c) * .pi / 180 * direction
        let r = min(rp.value(of: c) / rp.range, limit)
        let zr = r * cos(h), zi = r * sin(h)
        return CGPoint(x: centerX + wRe * zr - wIm * zi, y: centerY + wRe * zi + wIm * zr)
    }

    func point(for c: RGB, push: Double) -> CGPoint {
        let h = ColorParam.hue.value(of: c) * .pi / 180 * direction
        var r = 1.0
        if let rp = radius {
            r = rp.value(of: c) / rp.range
            if r >= 0.996 { r += push / max(1, scale) }
            if r <= 0.004 { r = 0 }
        }
        let zr = r * cos(h), zi = r * sin(h)
        return CGPoint(x: centerX + wRe * zr - wIm * zi, y: centerY + wRe * zi + wIm * zr)
    }
}

/// Where a pointer step clicks, as a function of the color.
public enum ControlMapping: Codable, Equatable, Sendable {
    /// Always the same spot (a button, a swatch, a text field).
    case fixed(CGPoint)
    /// A slider along one screen axis.
    case axis(ScreenAxis, LinearMap, other: Double)
    /// A 2-D area, e.g. a saturation × brightness square.
    case plane(x: LinearMap, y: LinearMap)
    /// A color wheel (hue = angle, radius = saturation) or a hue ring.
    case polar(PolarMap)

    public func point(for c: RGB, push: Double = 0) -> CGPoint {
        switch self {
        case .fixed(let p):
            return p
        case .axis(let axis, let map, let other):
            let v = map.coordinate(for: c, push: push)
            return axis == .x ? CGPoint(x: v, y: other) : CGPoint(x: other, y: v)
        case .plane(let mx, let my):
            return CGPoint(x: mx.coordinate(for: c, push: push), y: my.coordinate(for: c, push: push))
        case .polar(let pm):
            return pm.point(for: c, push: push)
        }
    }

    /// Where to press for `c`: on target, but never within the safety margin of the control's
    /// estimated edges (the drag then carries on to the exact target).
    public func safePoint(for c: RGB) -> CGPoint {
        switch self {
        case .fixed(let p):
            return p
        case .axis(let axis, let map, let other):
            let v = map.safeCoordinate(for: c)
            return axis == .x ? CGPoint(x: v, y: other) : CGPoint(x: other, y: v)
        case .plane(let mx, let my):
            return CGPoint(x: mx.safeCoordinate(for: c), y: my.safeCoordinate(for: c))
        case .polar(let pm):
            return pm.safePoint(for: c)
        }
    }

    var params: [ColorParam] {
        switch self {
        case .fixed: return []
        case .axis(_, let m, _): return [m.param]
        case .plane(let mx, let my): return [mx.param, my.param]
        case .polar(let pm): return [.hue] + (pm.radius.map { [$0] } ?? [])
        }
    }

    var describe: String {
        switch self {
        case .fixed: return "a fixed spot"
        case .axis(_, let m, _): return "a \(m.param.displayName) slider"
        case .plane(let mx, let my): return "a \(mx.param.displayName) × \(my.param.displayName) area"
        case .polar(let pm):
            if let r = pm.radius { return "a color wheel (hue × \(r.displayName))" }
            return "a hue ring"
        }
    }
}

// MARK: - Profile

public struct PointerStep: Codable, Equatable, Sendable {
    public var mapping: ControlMapping
    public var button: PointerButton
    public var clickCount: Int
    public var modifiers: KeyModifiers
    /// The user dragged (rather than clicked).
    public var isDrag: Bool
    /// Fixed drags: where the drag started.
    public var dragStart: CGPoint?
    /// The user grabbed the control's knob where the previous color had left it and dragged it.
    public var grabsKnob: Bool
    /// Pause before this step, seconds.
    public var delayBefore: Double

    func replay(for c: RGB, previous: RGB?) -> ReplayAction {
        switch mapping {
        case .fixed(let p):
            if isDrag, let s = dragStart {
                return .drag(from: s, to: p, button: button, modifiers: modifiers)
            }
            return .click(at: p, button: button, count: max(1, clickCount), modifiers: modifiers)
        default:
            // Press safely inside the control (the fitted edges are only approximate), then drag
            // onto the target. Pickers that act on mouse-down get the exact spot for anything not
            // near an edge; pickers that track the drag (most) end exactly on target, and clamp
            // onto the extreme when the target is at an edge (we overshoot it slightly).
            let target = mapping.point(for: c, push: 4)
            let knob = grabsKnob ? previous.map { mapping.point(for: $0) } : nil
            let start = knob ?? mapping.safePoint(for: c)
            return .drag(from: start, to: target, button: button, modifiers: modifiers)
        }
    }
}

public enum TypingPiece: Codable, Equatable, Sendable {
    /// A literal keystroke (Tab, Return, ⌘A, a fixed character…).
    case key(KeyStroke)
    /// Characters to type.
    case text(TextTemplate)
    /// Put the text on the clipboard, then press the paste shortcut.
    case paste(TextTemplate, shortcut: KeyStroke)
}

public struct TypingStep: Codable, Equatable, Sendable {
    public var pieces: [TypingPiece]
    public var delayBefore: Double
}

public enum PickerStep: Codable, Equatable, Sendable {
    case pointer(PointerStep)
    case typing(TypingStep)
}

/// Concrete input for the replayer.
public enum ReplayAction: Equatable, Sendable {
    case click(at: CGPoint, button: PointerButton, count: Int, modifiers: KeyModifiers)
    /// Press at `from`, drag to `to`, release. from == to: press, wiggle by half a point, release.
    case drag(from: CGPoint, to: CGPoint, button: PointerButton, modifiers: KeyModifiers)
    case key(KeyStroke)
    case setClipboard(String)
    case wait(TimeInterval)
    /// Move the pointer without pressing (test tooling; profiles never produce it).
    case move(CGPoint)
}

/// How to select any color in one app's color picker.
public struct ColorPickerProfile: Codable, Equatable, Sendable {
    /// Bundle identifier (or another stable key) of the app.
    public var appKey: String
    public var appName: String
    public var steps: [PickerStep]
    /// How the user typed each character (key code + modifiers), for the replayer.
    public var keyMap: [String: KeyStroke]
    /// Pointer-based profiles: the color model the picker uses.
    public var space: PickerColorSpace?
    /// "Types the hex code" / "Clicks a saturation × brightness area and a hue slider".
    public var summary: String
    public var learnedAt: Date
    /// Identifies the interpretation (so a rejected one is not offered again).
    public var hypothesisKey: String
    /// Bounding box of every point the profile clicks (CG global), so DrawBot can keep its own
    /// windows out of the way.
    public var pointerBounds: CGRect?
    /// True when the color is typed (exact); false when it is clicked (approximate).
    public var isExact: Bool

    public init(appKey: String, appName: String, steps: [PickerStep], keyMap: [String: KeyStroke],
                space: PickerColorSpace?, summary: String, learnedAt: Date, hypothesisKey: String,
                pointerBounds: CGRect?, isExact: Bool) {
        self.appKey = appKey
        self.appName = appName
        self.steps = steps
        self.keyMap = keyMap
        self.space = space
        self.summary = summary
        self.learnedAt = learnedAt
        self.hypothesisKey = hypothesisKey
        self.pointerBounds = pointerBounds
        self.isExact = isExact
    }

    /// The color values this profile types or pastes (empty for a click-only profile).
    public var typedSlots: [ValueSlot] {
        steps.flatMap { step -> [ValueSlot] in
            guard case .typing(let t) = step else { return [] }
            return t.pieces.flatMap { piece -> [ValueSlot] in
                switch piece {
                case .key: return []
                case .text(let tpl), .paste(let tpl, _): return tpl.slots
                }
            }
        }
    }

    /// The input that selects `color`. `previous` is the color the picker currently shows, if
    /// known (needed for pickers whose knob must be grabbed and dragged).
    public func actions(for color: RGB, previous: RGB?) -> [ReplayAction] {
        var out: [ReplayAction] = []
        for step in steps {
            switch step {
            case .pointer(let p):
                if p.delayBefore > 0 { out.append(.wait(p.delayBefore)) }
                out.append(p.replay(for: color, previous: previous))
            case .typing(let t):
                if t.delayBefore > 0 { out.append(.wait(t.delayBefore)) }
                for piece in t.pieces {
                    switch piece {
                    case .key(let k):
                        out.append(.key(k))
                    case .text(let template):
                        for ch in template.format(color) { out.append(.key(stroke(for: ch))) }
                    case .paste(let template, let shortcut):
                        out.append(.setClipboard(template.format(color)))
                        out.append(.wait(0.05))
                        out.append(.key(shortcut))
                    }
                }
            }
        }
        out.append(.wait(0.3))   // let the app apply the color
        return out
    }

    func stroke(for ch: Character) -> KeyStroke {
        if let k = keyMap[String(ch)] { return k }
        return VirtualKey.stroke(for: ch)
    }
}
