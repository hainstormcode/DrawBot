import AppKit
import DrawBotCore
import DrawBotSystem

/// Calls `then` once the user has let go of ⌃⌥⌘⇧ and no click or key press has happened for
/// `quiet` seconds (or after `deadline`).
///
/// * Synthetic events inherit held modifiers, which would turn clicks into ⌘-clicks and typing
///   into shortcuts.
/// * Many apps ignore input while a dialog or popup is still animating closed (PaintZ ignores
///   its colour button for about a second after its dialog closes). If the click that opens the
///   picker is lost, every following click lands on whatever is underneath — often the canvas.
@MainActor
enum ModifierWait {
    static func whenReleased(quiet: TimeInterval = 0, deadline: Date, _ then: @escaping () -> Void) {
        let held = NSEvent.modifierFlags.intersection([.control, .option, .command, .shift])
        if (held.isEmpty && secondsSinceLastClickOrKey() >= quiet) || Date() > deadline {
            then()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            MainActor.assumeIsolated { whenReleased(quiet: quiet, deadline: deadline, then) }
        }
    }

    /// Seconds since the last mouse button or key event anywhere (including DrawBot's own).
    static func secondsSinceLastClickOrKey() -> TimeInterval {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .keyDown, .keyUp]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
    }
}

/// Quiet time before replaying a learned colour picker (see `ModifierWait`).
let pickerQuietPeriod: TimeInterval = 1.5

/// One Colour Learn lesson:
///
///     demo(colour A) ─Done─▶ demo(colour B) ─Done─▶ analyse ─▶ trying(test colour) ─▶ verify
///     verify ─Yes─▶ result(success)            verify ─No─▶ demo(that test colour) ─▶ analyse …
///     verify ─Try again─▶ trying               any ─Cancel─▶ end
///
/// While a demo prompt is up, the recorder captures the user's clicks and typing in the drawing
/// app (never DrawBot's own panels). The prompt is non-activating, so pressing Done leaves the
/// drawing app frontmost.
@MainActor
final class ColorLearnSession {
    struct Target {
        let appKey: String
        let appName: String
        let canvas: CGRect
        /// Brings the drawing app (or the Test Canvas) to the front, then calls back.
        let activate: (@escaping () -> Void) -> Void
        /// DrawBot windows whose events count as demonstration (the Test Canvas).
        let recordsLocalWindow: (NSWindow?) -> Bool
        let careful: Bool
        /// Claim (true) / release (false) the Esc key while DrawBot is trying the picker.
        let watchEscape: (Bool) -> Void
    }

    private enum Stage { case demo, trying, verify, result }

    private let target: Target
    private let prompt: ColorPromptController
    private let hud: DrawingHUDController
    private let replayer: InputReplayer
    private let recorder = InputRecorder()
    /// The user confirmed a profile (it should be saved). `pickerColor` is what the picker shows now.
    private let onLearned: (ColorPickerProfile, RGB?) -> Void
    /// The lesson is over (closed, cancelled or given up).
    private let onEnd: () -> Void

    private var stage: Stage = .demo
    private var demos: [ColorDemo] = []
    private var demoColor = ColorLearner.demoColors[0]
    private var demoPrevious: RGB?
    /// What the picker currently shows, when known.
    private var pickerColor: RGB?
    private var candidate: ColorPickerProfile?
    private var learned: ColorPickerProfile?
    private var rejected: Set<String> = []
    private var testIndex = 0
    private var testColor = ColorLearner.testColors[0]
    private var note = ""
    private var token = 0
    private var ended = false

    static let maxDemos = 6

    init(target: Target, prompt: ColorPromptController, hud: DrawingHUDController, replayer: InputReplayer,
         onLearned: @escaping (ColorPickerProfile, RGB?) -> Void, onEnd: @escaping () -> Void) {
        self.target = target
        self.prompt = prompt
        self.hud = hud
        self.replayer = replayer
        self.onLearned = onLearned
        self.onEnd = onEnd
        log = LessonLog(appKey: target.appKey, appName: target.appName, canvas: target.canvas,
                        screens: NSScreen.screens.map { ScreenUtil.cgFrame(of: $0) }, startedAt: Date())
    }

    // MARK: Lesson log

    /// Everything that happened in this lesson, saved after every step to
    /// ~/Library/Application Support/DrawBot/Lessons/ so a failed lesson can be diagnosed (and
    /// replayed through colorlearn-harness).
    struct LessonLog: Codable {
        var appKey: String
        var appName: String
        var canvas: CGRect
        var screens: [CGRect]
        var startedAt: Date
        var demos: [ColorDemo] = []
        var events: [String] = []
    }

    private var log: LessonLog
    private lazy var logURL: URL? = {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("DrawBot/Lessons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return dir.appendingPathComponent("lesson_\(f.string(from: log.startedAt)).json")
    }()

    private func note(_ event: String) {
        log.events.append("\(String(format: "%.1f", Date().timeIntervalSince(log.startedAt)))s \(event)")
        log.demos = demos
        guard let url = logURL else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(log) { try? data.write(to: url) }
    }

    func begin() {
        startDemo(color: ColorLearner.demoColors[0], previous: nil)
    }

    // MARK: Input from the prompt / hotkeys

    func handle(_ action: PromptAction) {
        switch (stage, action) {
        case (_, .stop):
            cancel()
        case (.demo, .proceed):
            finishDemo()
        case (.demo, .redo):
            note = ""
            recorder.clear()
            showDemo()
        case (.verify, .proceed):
            accept()
        case (.verify, .retry):
            tryCandidate()
        case (.verify, .no):
            rejectCandidate()
        case (.result, .close):
            end()
        case (.result, .redo):
            restart()
        default:
            break
        }
    }

    /// ⌃⌥⌘↩
    func hotkeyProceed() {
        switch stage {
        case .demo: finishDemo()
        case .verify: accept()
        case .result: if learned != nil { end() } else { restart() }
        case .trying: break
        }
    }

    func escape() {
        if stage == .trying { replayer.requestStop(reason: DrawingEngine.Reason.escape) }
    }

    func cancel() {
        if stage == .trying { replayer.requestStop(reason: "Cancelled") }
        end()
    }

    private func end() {
        if !ended { note(learned == nil ? "lesson ended without a result" : "lesson finished") }
        guard !ended else { return }
        ended = true
        token += 1
        target.watchEscape(false)
        recorder.stop()
        prompt.hide()
        hud.hide()
        onEnd()
    }

    private func restart() {
        demos = []
        rejected = []
        candidate = nil
        learned = nil
        testIndex = 0
        note = ""
        pickerColor = nil
        startDemo(color: ColorLearner.demoColors[0], previous: nil)
    }

    // MARK: Demonstrations

    /// Keep the prompt off the canvas and off the parts of the picker seen so far.
    private var avoidRect: CGRect {
        var r = target.canvas
        for d in demos {
            for e in d.inputs where e.kind == .mouseDown && !target.canvas.contains(e.point) {
                r = r.union(CGRect(origin: e.point, size: .zero).insetBy(dx: -20, dy: -20))
            }
        }
        return r
    }

    private func startDemo(color: RGB, previous: RGB?) {
        stage = .demo
        demoColor = color
        demoPrevious = previous
        token += 1
        let t = token
        recorder.stop()
        recorder.clear()
        recorder.recordsLocalWindow = target.recordsLocalWindow
        recorder.onChange = { [weak self] in self?.refreshDemo() }
        showDemo()
        target.activate { [weak self] in
            guard let self, self.token == t, self.stage == .demo, !self.ended else { return }
            self.recorder.start()
        }
    }

    private func demoContent() -> PromptContent {
        var c = PromptContent(mode: .learnDemo(recorded: recorder.summary), color: demoColor)
        c.title = demos.count < 2 ? "Teach DrawBot · colour \(demos.count + 1) of 2" : "Teach DrawBot · one more example"
        c.appName = target.appName
        c.note = note
        return c
    }

    private func showDemo() {
        prompt.show(demoContent(), canvasCG: avoidRect, autoCopyHex: true)
    }

    private func refreshDemo() {
        guard stage == .demo, !ended else { return }
        prompt.update(demoContent())
    }

    private func finishDemo() {
        let inputs = recorder.inputs
        let meaningful = inputs.contains { e in
            switch e.kind {
            case .mouseDown: return true
            case .keyDown: return !e.modifiers.isSuperset(of: [.control, .option, .command])
            default: return false
            }
        }
        guard meaningful else {
            note = "DrawBot didn't see you click or type in \(target.appName) yet. Select the colour there, then press Done."
            refreshDemo()
            return
        }
        recorder.stop()
        note = ""
        demos.append(ColorDemo(color: demoColor, previousColor: demoPrevious, inputs: inputs))
        note("demo \(demos.count) for \(demoColor.hex): \(inputs.count) inputs (\(recorder.summary))")
        pickerColor = demoColor
        if demos.count < 2 {
            startDemo(color: ColorLearner.demoColors[1], previous: demoColor)
        } else {
            analyze()
        }
    }

    // MARK: Learning and checking

    private func analyze() {
        let screens = NSScreen.screens.map { ScreenUtil.cgFrame(of: $0) }
        switch ColorLearner.learn(demos: demos, canvas: target.canvas, screens: screens, appKey: target.appKey,
                                  appName: target.appName, rejected: rejected) {
        case .success(let p):
            note("learned: \(p.summary) [\(p.hypothesisKey)]")
            candidate = p
            tryCandidate()
        case .failure(let f):
            note("learning failed: \(f.message)")
            showResult(success: false, message: f.message)
        }
    }

    private func tryCandidate(attempt: Int = 0) {
        guard let candidate, !ended else { return }
        if replayer.isRunning {
            // A cancelled try is still letting go of the mouse.
            guard attempt < 40 else { return showResult(success: false, message: "DrawBot's previous try didn't finish.") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                MainActor.assumeIsolated { self?.tryCandidate(attempt: attempt + 1) }
            }
            return
        }
        stage = .trying
        token += 1
        let t = token
        testColor = ColorLearner.testColors[testIndex % ColorLearner.testColors.count]
        prompt.hide()
        hud.show(HUDContent(mode: .learnTrying, color: testColor, stepNumber: 0, stepCount: 0), canvasCG: target.canvas)
        target.activate { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated {
                    guard let self, self.token == t else { return }
                    ModifierWait.whenReleased(quiet: pickerQuietPeriod, deadline: Date().addingTimeInterval(5)) { [weak self] in
                        guard let self, self.token == t else { return }
                        self.replayer.careful = self.target.careful
                        self.replayer.stopOnUserMouseMove = true
                        self.target.watchEscape(true)
                        let actions = candidate.actions(for: self.testColor, previous: self.pickerColor)
                        self.replayer.run(actions) { [weak self] outcome in
                            MainActor.assumeIsolated { self?.tryFinished(outcome, token: t) }
                        }
                    }
                }
            }
        }
    }

    private func tryFinished(_ outcome: InputReplayer.Outcome, token t: Int) {
        if token == t { note("try for \(testColor.hex): \(outcome)") }
        guard token == t, !ended else { return }
        target.watchEscape(false)
        hud.hide()
        pickerColor = nil
        if case .stopped(let reason) = outcome {
            note = "The try was interrupted (\(reason)). Press Try again, or No to show DrawBot yourself."
        } else {
            note = ""
        }
        stage = .verify
        var c = PromptContent(mode: .learnVerify, color: testColor)
        c.title = "Teach DrawBot · check"
        c.appName = target.appName
        c.note = note
        prompt.show(c, canvasCG: avoidRect, autoCopyHex: false)
    }

    private func accept() {
        note("user: yes, it worked")
        guard var p = candidate else { return }
        p.learnedAt = Date()
        learned = p
        pickerColor = testColor
        onLearned(p, testColor)
        let how = p.isExact
            ? "It types the colour, so colours come out exact."
            : "It clicks positions, so a colour can be off by a little."
        showResult(success: true, message: "\(p.summary)\n\(how)\n\nWith Colour selection set to automatic, DrawBot now selects every colour in \(target.appName) by itself. Keep the colour picker where it is; if it moves, learn it again.")
    }

    private func rejectCandidate() {
        note("user: no")
        guard let candidate else { return }
        rejected.insert(candidate.hypothesisKey)
        let failed = testColor
        testIndex += 1
        guard demos.count < Self.maxDemos else {
            showResult(success: false, message: "None of DrawBot's \(rejected.count) interpretations worked. If your colour picker has a hex field, select the colours by typing the hex code into it, then start over.")
            return
        }
        note = "DrawBot's try didn't work. Select this colour yourself once more so DrawBot can learn from it."
        startDemo(color: failed, previous: nil)
    }

    private func showResult(success: Bool, message: String) {
        stage = .result
        recorder.stop()
        var c = PromptContent(mode: .learnResult(success: success, message: message), color: nil)
        c.title = "Colour Learn"
        c.appName = target.appName
        prompt.show(c, canvasCG: target.canvas, autoCopyHex: false)
    }
}
