import AppKit
import DrawBotCore
import DrawBotSystem

// DrawBotTestRig: plays scripted REAL input (the same InputReplayer DrawBot uses) while
// DrawBot's InputRecorder watches, and writes what was recorded. It lets a developer (or an
// agent) pilot a color picker end to end with OS-level events, without rebuilding DrawBot.
//
//   open -n build/DrawBotTestRig.app --args /path/to/script.json
//
// script.json: { "out": "/path/result.json", "commands": [Command] }
// Command:
//   { "cmd": "record" }                         start recording (clears)
//   { "cmd": "stop", "name": "demo1" }          stop recording, keep it under that name
//   { "cmd": "play", "actions": [Action] }      replay actions (format of colorlearn-harness output)
//   { "cmd": "move", "x": .., "y": .. }         move the pointer (CG global points)
//   { "cmd": "sleep", "seconds": .. }
//   { "cmd": "draw", "strokes": [[x1,y1, …, xn,yn]…], "clamp": [x,y,w,h], "speed": SpeedSettings }
//                                               draw with DrawBot's real DrawingEngine (each
//                                               stroke a path through its points)
//   { "cmd": "paint", "grid": ["0.01", …], "x": .., "y": .., "pen": 4, "label": 0, "speed": … }
//                                               plan a grid (digits = colors, "." = empty) with
//                                               DrawBot's StrokePlanner and draw one color of it
// Action: { "type": "click"|"drag"|"key"|"clipboard"|"wait"|"move", … } — see decodeAction.
//
// It needs its own Accessibility permission (System Settings → Privacy & Security →
// Accessibility). It is a development tool: anything that can write a script can make it type
// and click, so remove its permission when you're done testing.

struct Script: Decodable {
    var out: String
    var commands: [Command]
}

struct Command: Decodable {
    var cmd: String
    var name: String?
    var seconds: Double?
    var x: Double?
    var y: Double?
    var actions: [[String: JSONValue]]?
    /// draw: strokes as [x1, y1, x2, y2], the clamp rectangle [x, y, w, h], and the timing.
    var strokes: [[Double]]?
    var clamp: [Double]?
    var speed: SpeedSettings?
    /// paint: the grid, cell size, and which color to draw.
    var grid: [String]?
    var pen: Double?
    var label: Int?
}

enum JSONValue: Decodable {
    case number(Double), string(String), bool(Bool)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else { self = .string(try c.decode(String.self)) }
    }
    var double: Double { if case .number(let d) = self { return d }; return 0 }
    var string: String { if case .string(let s) = self { return s }; return "" }
}

func decodeAction(_ a: [String: JSONValue]) -> ReplayAction? {
    func n(_ k: String) -> Double { a[k]?.double ?? 0 }
    let button: PointerButton = n("button") == 2 ? .right : .left
    let mods = KeyModifiers(rawValue: Int(n("mods")))
    switch a["type"]?.string ?? "" {
    case "click": return .click(at: CGPoint(x: n("x"), y: n("y")), button: button, count: max(1, Int(n("count"))), modifiers: mods)
    case "drag": return .drag(from: CGPoint(x: n("fromX"), y: n("fromY")), to: CGPoint(x: n("toX"), y: n("toY")), button: button, modifiers: mods)
    case "key": return .key(KeyStroke(keyCode: UInt16(n("keyCode")), characters: a["chars"]?.string ?? "", modifiers: mods))
    case "clipboard": return .setClipboard(a["text"]?.string ?? "")
    case "wait": return .wait(n("seconds"))
    case "move": return .move(CGPoint(x: n("x"), y: n("y")))
    default: return nil
    }
}

@MainActor
final class Rig {
    let script: Script
    let recorder = InputRecorder()
    let replayer = InputReplayer()
    let engine = DrawingEngine(speed: .normal)
    var recordings: [String: [RecordedInput]] = [:]
    var log: [String] = []

    init(script: Script) {
        self.script = script
        replayer.stopOnUserMouseMove = false
    }

    func run(_ i: Int = 0) {
        guard i < script.commands.count else { return finish() }
        let c = script.commands[i]
        let next: () -> Void = { [weak self] in self?.run(i + 1) }
        switch c.cmd {
        case "record":
            recorder.start()
            next()
        case "stop":
            recorder.stop()
            recordings[c.name ?? "rec\(i)"] = recorder.inputs
            log.append("stop \(c.name ?? ""): \(recorder.inputs.count) inputs")
            next()
        case "sleep":
            DispatchQueue.main.asyncAfter(deadline: .now() + (c.seconds ?? 0)) { next() }
        case "move":
            play([.move(CGPoint(x: c.x ?? 0, y: c.y ?? 0))], then: next)
        case "play":
            play((c.actions ?? []).compactMap(decodeAction), then: next)
        case "draw", "paint":
            var strokes = (c.strokes ?? []).filter { $0.count >= 4 && $0.count % 2 == 0 }.map { v -> ScreenStroke in
                let pts = stride(from: 0, to: v.count, by: 2).map { CGPoint(x: v[$0], y: v[$0 + 1]) }
                return ScreenStroke(start: pts[0], end: pts[pts.count - 1], via: Array(pts.dropFirst().dropLast()))
            }
            var r = c.clamp ?? [0, 0, 10000, 10000]
            if c.cmd == "paint", let grid = c.grid, let width = grid.map(\.count).max(), width > 0 {
                let pen = c.pen ?? 4
                let labels = grid.flatMap { row -> [Int32] in
                    let cells = row.map { ch in ch.wholeNumberValue.map(Int32.init) ?? -1 }
                    return cells + Array(repeating: -1, count: width - cells.count)
                }
                let k = Int(labels.max() ?? 0) + 1
                let q = QuantizedImage(width: width, height: grid.count, labels: labels,
                                       palette: Array(repeating: RGB(r: 0, g: 0, b: 0), count: max(1, k)),
                                       counts: (0..<max(1, k)).map { i in labels.filter { $0 == Int32(i) }.count })
                let canvas = CGRect(x: c.x ?? 0, y: c.y ?? 0, width: Double(width) * pen, height: Double(grid.count) * pen)
                strokes = StrokePlanner.strokes(for: c.label ?? 0, in: q, layout: GridLayout(canvas: canvas, penSize: pen))
                r = [canvas.minX, canvas.minY, canvas.width, canvas.height]
            }
            engine.speed = c.speed ?? .normal
            engine.pauseOnUserMouseMove = false
            let started = Date()
            engine.draw(strokes: strokes, clampRect: CGRect(x: r[0], y: r[1], width: r[2], height: r[3]), progress: { _ in },
                        completion: { [weak self] outcome in
                MainActor.assumeIsolated {
                    self?.log.append("draw \(strokes.count) strokes in \(String(format: "%.2f", Date().timeIntervalSince(started)))s: \(outcome)")
                    next()
                }
            })
        default:
            log.append("unknown command \(c.cmd)")
            next()
        }
    }

    func play(_ actions: [ReplayAction], then: @escaping () -> Void) {
        replayer.run(actions) { [weak self] outcome in
            MainActor.assumeIsolated {
                self?.log.append("play \(actions.count) actions: \(outcome)")
                then()
            }
        }
    }

    func finish() {
        recorder.stop()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Out: Encodable { var trusted: Bool; var axTrusted: Bool; var log: [String]; var recordings: [String: [RecordedInput]] }
        let out = Out(trusted: Permissions.isAccessibilityTrusted, axTrusted: Permissions.isAXTrusted, log: log, recordings: recordings)
        if let data = try? enc.encode(out) { try? data.write(to: URL(fileURLWithPath: script.out)) }
        NSApp.terminate(nil)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn") }
    guard let path = args.first, let data = FileManager.default.contents(atPath: path),
          let script = try? JSONDecoder().decode(Script.self, from: data) else {
        FileHandle.standardError.write("usage: DrawBotTestRig script.json\n".data(using: .utf8)!)
        exit(2)
    }
    let rig = Rig(script: script)
    DispatchQueue.main.async { rig.run() }
    withExtendedLifetime(rig) { app.run() }
}
