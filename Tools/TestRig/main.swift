import AppKit
import DrawBotCore
import DrawBotSystem

// DrawBotTestRig: plays scripted REAL input (the same InputReplayer DrawBot uses) while
// DrawBot's InputRecorder watches, and writes what was recorded. It lets a developer (or an
// agent) pilot a colour picker end to end with OS-level events, without rebuilding DrawBot.
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
