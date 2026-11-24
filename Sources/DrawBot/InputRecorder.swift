import AppKit
import DrawBotCore

/// Records the user's mouse buttons, drags and key presses while they demonstrate a colour
/// (Colour Learn). Global monitors see events sent to other apps (mouse events need no
/// permission; key events need Accessibility). DrawBot's own windows are not recorded, except
/// those `recordsLocalWindow` accepts (the Test Canvas and its colour picker).
@MainActor
final class InputRecorder {
    private var monitors: [Any] = []
    private(set) var inputs: [RecordedInput] = []
    var recordsLocalWindow: (NSWindow?) -> Bool = { _ in false }
    var onChange: () -> Void = {}

    var isRecording: Bool { !monitors.isEmpty }

    private static let mask: NSEvent.EventTypeMask = [
        .leftMouseDown, .leftMouseUp, .leftMouseDragged,
        .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        .keyDown,
    ]

    func start() {
        stop()
        inputs = []
        if let g = NSEvent.addGlobalMonitorForEvents(matching: Self.mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.record(e) }
        }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: Self.mask, handler: { [weak self] e in
            MainActor.assumeIsolated {
                if let self, self.recordsLocalWindow(e.window) { self.record(e) }
            }
            return e
        }) {
            monitors.append(l)
        }
        onChange()
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
    }

    func clear() {
        inputs = []
        onChange()
    }

    /// "3 clicks · 7 keys"
    var summary: String {
        let clicks = inputs.filter { $0.kind == .mouseDown }.count
        let keys = inputs.filter { $0.kind == .keyDown && !$0.modifiers.isSuperset(of: [.control, .option, .command]) }.count
        if clicks == 0 && keys == 0 { return "Nothing recorded yet" }
        var parts: [String] = []
        if clicks > 0 { parts.append("\(clicks) click\(clicks == 1 ? "" : "s")") }
        if keys > 0 { parts.append("\(keys) key\(keys == 1 ? "" : "s")") }
        return "Recorded " + parts.joined(separator: " · ")
    }

    static func modifiers(_ f: NSEvent.ModifierFlags) -> KeyModifiers {
        var m: KeyModifiers = []
        if f.contains(.shift) { m.insert(.shift) }
        if f.contains(.control) { m.insert(.control) }
        if f.contains(.option) { m.insert(.option) }
        if f.contains(.command) { m.insert(.command) }
        return m
    }

    private func record(_ e: NSEvent) {
        let point = e.cgEvent?.location ?? ScreenUtil.toCG(CGRect(origin: NSEvent.mouseLocation, size: .zero)).origin
        let mods = Self.modifiers(e.modifierFlags)
        let input: RecordedInput
        switch e.type {
        case .leftMouseDown, .rightMouseDown:
            input = .mouse(.mouseDown, at: point, time: e.timestamp, button: e.type == .rightMouseDown ? .right : .left,
                           clickCount: max(1, e.clickCount), modifiers: mods)
        case .leftMouseUp, .rightMouseUp:
            input = .mouse(.mouseUp, at: point, time: e.timestamp, button: e.type == .rightMouseUp ? .right : .left,
                           clickCount: max(1, e.clickCount), modifiers: mods)
        case .leftMouseDragged, .rightMouseDragged:
            input = .mouse(.mouseDragged, at: point, time: e.timestamp, button: e.type == .rightMouseDragged ? .right : .left,
                           modifiers: mods)
        case .keyDown:
            let shortcut = mods.contains(.command) || mods.contains(.control)
            let chars = (shortcut ? e.charactersIgnoringModifiers : e.characters) ?? ""
            var paste: String?
            if mods.contains(.command), chars.lowercased() == "v" || e.keyCode == VirtualKey.v {
                paste = NSPasteboard.general.string(forType: .string)
            }
            input = .key(e.keyCode, chars, time: e.timestamp, modifiers: mods, pasteText: paste)
        default:
            return
        }
        inputs.append(input)
        if input.kind != .mouseDragged { onChange() }
    }
}
