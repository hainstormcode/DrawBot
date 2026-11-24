import CoreGraphics
import DrawBotCore
import Foundation

// colorlearn-harness: runs DrawBot's Colour Learn analysis on demonstrations recorded outside
// the app (for example by Tools/page-recorder.js in a browser), and prints the learned profile
// plus the concrete input it would replay for some test colours.
//
//   swift run colorlearn-harness < session.json
//
// Input:
// {
//   "canvas": [x, y, w, h],              // the canvas DrawBot would draw into (same coordinates as the events)
//   "screen": [x, y, w, h],              // the visible area (plausibility checks)
//   "demos": [ { "color": "E68A2E", "previous": null | "RRGGBB", "events": [Event] } ],
//   "rejected": ["hypothesis key", …],   // optional
//   "tests": ["50B369", …],              // colours to produce replay actions for
//   "previous": "RRGGBB" | null          // what the picker shows before the first test
// }
// Event: { "kind": "down"|"drag"|"up"|"key", "t": seconds, "x": .., "y": .., "button": 0|2,
//          "count": clickCount, "key": KeyboardEvent.key, "code": KeyboardEvent.code,
//          "shift"/"ctrl"/"alt"/"meta": Bool, "paste": String? }

struct Event: Decodable {
    var kind: String
    var t: Double
    var x: Double?
    var y: Double?
    var button: Int?
    var count: Int?
    var key: String?
    var code: String?
    var shift: Bool?
    var ctrl: Bool?
    var alt: Bool?
    var meta: Bool?
    var paste: String?
}

struct Demo: Decodable {
    var color: String
    var previous: String?
    /// Page-recorder events…
    var events: [Event]?
    /// …or DrawBot's own recorded inputs (from the test rig).
    var inputs: [RecordedInput]?
}

struct Session: Decodable {
    var canvas: [Double]?
    var screen: [Double]?
    var demos: [Demo]
    var rejected: [String]?
    var tests: [String]?
    var previous: String?
}

func rgb(_ hex: String) -> RGB? {
    let s = hex.replacingOccurrences(of: "#", with: "")
    guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
    return RGB(r: UInt8((v >> 16) & 255), g: UInt8((v >> 8) & 255), b: UInt8(v & 255))
}

func rect(_ a: [Double]?) -> CGRect? {
    guard let a, a.count == 4 else { return nil }
    return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
}

/// KeyboardEvent.code → macOS virtual key code (ANSI).
let codes: [String: UInt16] = {
    var m: [String: UInt16] = [
        "Enter": 36, "NumpadEnter": 76, "Tab": 48, "Space": 49, "Backspace": 51, "Escape": 53, "Delete": 117,
        "ArrowLeft": 123, "ArrowRight": 124, "ArrowDown": 125, "ArrowUp": 126, "Home": 115, "End": 119,
        "Period": 47, "Comma": 43, "Minus": 27, "Equal": 24, "Slash": 44, "Semicolon": 41, "Quote": 39,
        "BracketLeft": 33, "BracketRight": 30, "Backslash": 42, "Backquote": 50,
    ]
    let letters: [(String, UInt16)] = [("A", 0), ("S", 1), ("D", 2), ("F", 3), ("H", 4), ("G", 5), ("Z", 6), ("X", 7), ("C", 8),
                                       ("V", 9), ("B", 11), ("Q", 12), ("W", 13), ("E", 14), ("R", 15), ("Y", 16), ("T", 17),
                                       ("O", 31), ("U", 32), ("I", 34), ("P", 35), ("L", 37), ("J", 38), ("K", 40), ("N", 45), ("M", 46)]
    for (l, c) in letters { m["Key" + l] = c }
    let digits: [(String, UInt16)] = [("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("9", 25), ("7", 26), ("8", 28), ("0", 29)]
    for (d, c) in digits { m["Digit" + d] = c }
    return m
}()

func convert(_ e: Event) -> RecordedInput? {
    var mods: KeyModifiers = []
    if e.shift == true { mods.insert(.shift) }
    if e.ctrl == true { mods.insert(.control) }
    if e.alt == true { mods.insert(.option) }
    if e.meta == true { mods.insert(.command) }
    let p = CGPoint(x: e.x ?? 0, y: e.y ?? 0)
    let button: PointerButton = e.button == 2 ? .right : .left
    switch e.kind {
    case "down": return .mouse(.mouseDown, at: p, time: e.t, button: button, clickCount: max(1, e.count ?? 1), modifiers: mods)
    case "drag": return .mouse(.mouseDragged, at: p, time: e.t, button: button, modifiers: mods)
    case "up": return .mouse(.mouseUp, at: p, time: e.t, button: button, clickCount: max(1, e.count ?? 1), modifiers: mods)
    case "key":
        let key = e.key ?? ""
        if ["Shift", "Control", "Alt", "Meta", "CapsLock"].contains(key) { return nil }   // NSEvent sends flagsChanged, not keyDown
        let code = codes[e.code ?? ""] ?? 0xFFFF
        var chars: String
        switch key {
        case "Enter": chars = "\r"
        case "Tab": chars = "\t"
        case "Backspace": chars = "\u{7F}"
        case "Escape": chars = "\u{1B}"
        default: chars = key.count == 1 ? key : ""
        }
        if mods.contains(.command) || mods.contains(.control) { chars = chars.lowercased() }
        return .key(code, chars, time: e.t, modifiers: mods, pasteText: e.paste)
    default:
        return nil
    }
}

func describe(_ a: ReplayAction) -> [String: Any] {
    switch a {
    case .click(let p, let b, let n, let m):
        return ["type": "click", "x": Double(p.x), "y": Double(p.y), "button": b == .right ? 2 : 0, "count": n, "mods": m.rawValue]
    case .drag(let f, let t, let b, let m):
        return ["type": "drag", "fromX": Double(f.x), "fromY": Double(f.y), "toX": Double(t.x), "toY": Double(t.y),
                "button": b == .right ? 2 : 0, "mods": m.rawValue]
    case .key(let k):
        return ["type": "key", "keyCode": Int(k.keyCode), "chars": k.characters, "mods": k.modifiers.rawValue]
    case .setClipboard(let s):
        return ["type": "clipboard", "text": s]
    case .wait(let t):
        return ["type": "wait", "seconds": t]
    case .move(let p):
        return ["type": "move", "x": Double(p.x), "y": Double(p.y)]
    }
}

let data = FileHandle.standardInput.readDataToEndOfFile()
let session: Session
do {
    session = try JSONDecoder().decode(Session.self, from: data)
} catch {
    FileHandle.standardError.write("bad input: \(error)\n".data(using: .utf8)!)
    exit(2)
}
let demos = session.demos.map { d in
    ColorDemo(color: rgb(d.color)!, previousColor: d.previous.flatMap(rgb), inputs: d.inputs ?? (d.events ?? []).compactMap(convert))
}
let screens = rect(session.screen).map { [$0] } ?? []
var out: [String: Any] = [:]
switch ColorLearner.learn(demos: demos, canvas: rect(session.canvas), screens: screens, appKey: "harness",
                          appName: "Harness", rejected: Set(session.rejected ?? [])) {
case .failure(let f):
    out = ["ok": false, "message": f.message]
case .success(let p):
    var tests: [String: Any] = [:]
    var prev = session.previous.flatMap(rgb)
    for hex in session.tests ?? [] {
        guard let c = rgb(hex) else { continue }
        tests[hex] = p.actions(for: c, previous: prev).map(describe)
        prev = c
    }
    out = ["ok": true, "summary": p.summary, "key": p.hypothesisKey, "space": p.space?.rawValue ?? "-",
           "exact": p.isExact, "steps": p.steps.count, "actions": tests]
}
let json = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
print(String(data: json, encoding: .utf8)!)
