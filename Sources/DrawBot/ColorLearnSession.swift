import AppKit
import DrawBotCore
import DrawBotSystem

/// Calls `then` once the user has let go of ⌃⌥⌘⇧ and no click or key press has happened for
/// `quiet` seconds (or after `deadline`).
///
/// * Synthetic events inherit held modifiers, which would turn clicks into ⌘-clicks and typing
///   into shortcuts.
/// * Many apps ignore input while a dialog or popup is still animating closed (PaintZ ignores
///   its color button for about a second after its dialog closes). If the click that opens the
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

/// Quiet time before replaying a learned color picker (see `ModifierWait`).
let pickerQuietPeriod: TimeInterval = 1.5

/// One Color Learn lesson:
///
///     demo(color A) ─Done─▶ demo(color B) ─Done─▶ analyze ─▶ trying(test color) ─▶ verify
///     verify ─Yes─▶ result(success)            verify ─No─▶ demo(that test color) ─▶ analyze …
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
        /// Screen area to watch when learning a fixed palette (the drawing app's window).
        let captureRect: CGRect
    }

    private enum Stage { case demo, trying, verify, result, palette, paletteChecking }

    private let target: Target
    private let prompt: ColorPromptController
    private let hud: DrawingHUDController
    private let replayer: InputReplayer
    private let recorder = InputRecorder()
    /// The user confirmed a profile (it should be saved). `pickerColor` is what the picker shows now.
    private let onLearned: (ColorPickerProfile, RGB?) -> Void
    /// The lesson is over (closed, canceled or given up).
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
        case (.demo, .palette):
            startPalette()
        case (.palette, .proceed):
            finishPalette()
        case (.palette, .redo):
            startPalette()
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
        case .palette: finishPalette()
        case .trying, .paletteChecking: break
        }
    }

    func escape() {
        if stage == .trying { replayer.requestStop(reason: DrawingEngine.Reason.escape) }
    }

    func cancel() {
        if stage == .trying { replayer.requestStop(reason: "Canceled") }
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
        c.title = demos.count < 2 ? "Teach DrawBot · color \(demos.count + 1) of 2" : "Teach DrawBot · one more example"
        c.appName = target.appName
        c.note = note
        return c
    }

    private func showDemo() {
        prompt.show(demoContent(), canvasCG: avoidRect)
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
            note = "DrawBot didn't see you click or type in \(target.appName) yet. Select the color there, then press Done."
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
            // A canceled try is still letting go of the mouse.
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
        prompt.show(c, canvasCG: avoidRect)
    }

    private func accept() {
        note("user: yes, it worked")
        guard var p = candidate else { return }
        p.learnedAt = Date()
        learned = p
        pickerColor = testColor
        onLearned(p, testColor)
        let how = p.isExact
            ? "It types the color, so colors come out exact."
            : "It clicks positions, so a color can be off by a little."
        showResult(success: true, message: "\(p.summary)\n\(how)\n\nWith Color selection set to automatic, DrawBot now selects every color in \(target.appName) by itself. Keep the color picker where it is; if it moves, learn it again.")
    }

    private func rejectCandidate() {
        note("user: no")
        guard let candidate else { return }
        rejected.insert(candidate.hypothesisKey)
        let failed = testColor
        testIndex += 1
        // A typed profile repeats exactly what the user typed. If that gave the wrong color,
        // the app itself changes typed values (PaintZ turns a typed hex code 15° round the hue
        // circle): demonstrating the same way again can't help. Suggest another way instead.
        if candidate.isExact {
            let typedHex = candidate.typedSlots.contains { if case .hex = $0 { return true } else { return false } }
            let other = typedHex
                ? "type the R, G and B values into their fields instead, or click the color in the picker"
                : "click the color in the picker instead"
            showResult(success: false, message: "DrawBot typed exactly what you typed, so \(target.appName) itself changed the color. Some apps convert typed values wrongly; PaintZ, for example, shifts a typed hex code's hue. Start over and \(other).")
            return
        }
        guard demos.count < Self.maxDemos else {
            showResult(success: false, message: "None of DrawBot's \(rejected.count) interpretations of your clicks worked. Start over and type the color's values instead (its hex code, or R, G and B), if your color picker has fields for them.")
            return
        }
        note = "DrawBot's try didn't work. Select this color yourself once more so DrawBot can learn from it."
        startDemo(color: failed, previous: nil)
    }

    private func showResult(success: Bool, message: String, swatches: [RGB] = []) {
        stage = .result
        recorder.stop()
        var c = PromptContent(mode: .learnResult(success: success, message: message), color: nil)
        c.title = "Color Learn"
        c.appName = target.appName
        c.swatches = swatches
        prompt.show(c, canvasCG: target.canvas)
    }

    // MARK: Fixed palettes

    /// What the screen looked like before the first swatch click, and after each one.
    private var paletteBaseline: RGBAImage?
    private var paletteClicks: [CGPoint] = []          // CG global
    private var paletteClickCounts: [Int] = []
    private var paletteFrames: [RGBAImage] = []
    private var paletteCaptures: Task<Void, Never>?    // serial chain of pending captures
    private var paletteRect = CGRect.zero
    private var paletteColorsSoFar: [RGB] = []
    private static let maxSwatches = 64

    private func startPalette() {
        token += 1
        let t = token
        recorder.stop()
        recorder.clear()
        paletteBaseline = nil
        paletteClicks = []
        paletteClickCounts = []
        paletteFrames = []
        paletteColorsSoFar = []
        paletteCaptures = nil
        guard ScreenSampler.isSupported else {
            showResult(success: false, message: "Learning a fixed palette needs macOS 14 or later (DrawBot has to look at the screen to see which color each swatch selects).")
            return
        }
        guard ScreenSampler.hasPermission else {
            ScreenSampler.requestPermission()
            note("palette: no Screen Recording permission")
            showResult(success: false, message: "To learn a fixed palette, DrawBot has to look at the screen to see which color each swatch selects, which needs the Screen Recording permission. Turn DrawBot on in System Settings → Privacy & Security → Screen & System Audio Recording, relaunch DrawBot, then start the lesson again and click Only swatches…")
            return
        }
        stage = .palette
        note = ""
        paletteRect = target.captureRect
        note("palette lesson started, watching \(paletteRect)")
        showPalettePrompt(initial: true)
        target.activate { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainActor.assumeIsolated {
                    guard let self, self.token == t, self.stage == .palette else { return }
                    self.paletteCaptures = Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.paletteBaseline = await self.capturePalette(token: t)
                    }
                    self.recorder.recordsLocalWindow = self.target.recordsLocalWindow
                    self.recorder.onChange = { [weak self] in self?.paletteInput(token: t) }
                    self.recorder.start()
                }
            }
        }
    }

    /// A screenshot of the palette area, or nil. If macOS refuses it, the lesson stops right
    /// away: every refused screenshot brings up the system's Screen Recording window and takes
    /// the focus away from the drawing app, so trying again on every click would do that each
    /// time. (After DrawBot is rebuilt, macOS can refuse even though System Settings shows it
    /// switched on: the grant belongs to the old build.)
    private func capturePalette(token t: Int) async -> RGBAImage? {
        do {
            return try await ScreenSampler.capture(paletteRect)
        } catch let error as ScreenSampler.CaptureError {
            note("palette: screenshot failed (\(error))")
            return nil
        } catch {
            guard token == t else { return nil }
            note("palette: screenshot refused (\(error.localizedDescription))")
            token += 1   // cancels the pending screenshots and checks
            recorder.stop()
            hud.hide()
            target.watchEscape(false)
            showResult(success: false, message: "macOS didn't let DrawBot take a screenshot, so it stopped instead of asking again on every click. In System Settings → Privacy & Security → Screen & System Audio Recording, select DrawBot and remove it with –, add it again with +, switch it on, then quit and reopen DrawBot and start the lesson again. (If you rebuilt DrawBot, the old entry belongs to the old build, even if it looks switched on.)")
            return nil
        }
    }

    private func showPalettePrompt(initial: Bool = false) {
        var c = PromptContent(mode: .learnPalette(recorded: "\(paletteClicks.count) swatch\(paletteClicks.count == 1 ? "" : "es") clicked"), color: nil)
        c.title = "Teach DrawBot · fixed swatches"
        c.appName = target.appName
        c.note = note
        c.swatches = paletteColorsSoFar
        if initial { prompt.show(c, canvasCG: target.canvas.union(paletteRect.insetBy(dx: 40, dy: 40))) } else { prompt.update(c) }
    }

    /// After every click: wait for the app to show the new color, then take a screenshot.
    private func paletteInput(token t: Int) {
        guard token == t, stage == .palette, let last = recorder.inputs.last, last.kind == .mouseUp,
              paletteClicks.count < Self.maxSwatches else { return }
        paletteClicks.append(last.point)
        paletteClickCounts.append(last.clickCount)
        let previous = paletteCaptures
        paletteCaptures = Task { @MainActor [weak self] in
            await previous?.value
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self, self.token == t else { return }
            let captured = await self.capturePalette(token: t)
            guard self.token == t else { return }   // the lesson stopped meanwhile
            if let frame = captured {
                self.paletteFrames.append(frame)
            } else if let lastFrame = self.paletteFrames.last ?? self.paletteBaseline {
                self.paletteFrames.append(lastFrame)   // keep frames and clicks aligned
            }
            self.showPalettePrompt()
        }
        showPalettePrompt()
    }

    private func finishPalette() {
        guard stage == .palette else { return }
        let t = token
        recorder.stop()
        stage = .paletteChecking
        let pending = paletteCaptures
        Task { @MainActor [weak self] in
            await pending?.value
            guard let self, self.token == t else { return }
            guard let baseline = self.paletteBaseline, self.paletteFrames.count >= 2,
                  self.paletteFrames.count == self.paletteClicks.count else {
                self.stage = .palette
                self.note = self.paletteClicks.count < 2
                    ? "Click at least two swatches (ideally all of them), then press Done."
                    : "DrawBot couldn't take screenshots. Check its Screen Recording permission, then start over."
                self.recorder.start()
                self.showPalettePrompt()
                return
            }
            let rect = self.paletteRect
            let local = self.paletteClicks.map { CGPoint(x: $0.x - rect.minX, y: $0.y - rect.minY) }
            let frames = self.paletteFrames
            let analysis = await Task.detached { PaletteLearner.analyze(baseline: baseline, frames: frames, clicks: local) }.value
            guard self.token == t else { return }
            guard let analysis else {
                self.showResult(success: false, message: "DrawBot couldn't make sense of the screenshots. Start over and click the swatches a bit more slowly.")
                return
            }
            self.paletteColorsSoFar = analysis.colors
            let swatches = PaletteLearner.swatches(clicks: self.paletteClicks, colors: analysis.colors, clickCounts: self.paletteClickCounts)
            self.note("palette: \(swatches.count) swatches, \(analysis.fromIndicator ? "read from the current-color display" : "sampled from the swatches"): \(swatches.map(\.color.hex).joined(separator: " "))")
            let points = swatches.map(\.point)
            let bounds = points.dropFirst().reduce(CGRect(origin: points[0], size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
            let profile = ColorPickerProfile(
                appKey: self.target.appKey, appName: self.target.appName, steps: [], keyMap: [:], space: nil,
                summary: "Clicks one of \(swatches.count) fixed swatches; the picture's colors are moved to the closest ones.",
                learnedAt: Date(), hypothesisKey: "palette:\(swatches.count)", pointerBounds: bounds.insetBy(dx: -30, dy: -30),
                isExact: true, swatches: swatches)
            self.checkPalette(profile, analysis: analysis, token: t)
        }
    }

    /// Clicks one swatch (not the last one clicked) and, when an indicator was found, checks
    /// that it shows that swatch's color.
    private func checkPalette(_ profile: ColorPickerProfile, analysis: PaletteLearner.Analysis, token t: Int) {
        let swatches = profile.swatches ?? []
        guard analysis.fromIndicator, swatches.count >= 2,
              let test = swatches.first(where: { hypot($0.point.x - (paletteClicks.last?.x ?? 0), $0.point.y - (paletteClicks.last?.y ?? 0)) > 6 }) else {
            return finishPaletteLesson(profile, checked: false)
        }
        prompt.hide()
        hud.show(HUDContent(mode: .learnTrying, color: test.color, stepNumber: 0, stepCount: 0), canvasCG: target.canvas)
        target.activate { [weak self] in
            ModifierWait.whenReleased(quiet: pickerQuietPeriod, deadline: Date().addingTimeInterval(5)) { [weak self] in
                guard let self, self.token == t else { return }
                self.target.watchEscape(true)
                self.replayer.run(profile.actions(for: test.color, previous: nil)) { [weak self] outcome in
                    MainActor.assumeIsolated {
                        guard let self, self.token == t else { return }
                        self.target.watchEscape(false)
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            guard let self, self.token == t else { return }
                            self.hud.hide()
                            let frame = await self.capturePalette(token: t)
                            guard self.token == t else { return }
                            let shown = frame.flatMap { PaletteLearner.indicatorColor(in: $0, indicator: analysis.indicator) }
                            self.note("palette check: clicked \(test.color.hex), display shows \(shown?.hex ?? "nothing") (\(outcome))")
                            if let shown, ColorMath.deltaE(shown, test.color) <= 8 {
                                self.pickerColor = test.color
                                self.finishPaletteLesson(profile, checked: true)
                            } else {
                                self.showResult(success: false, message: "DrawBot clicked the \(test.color.hex) swatch, but the color display then showed \(shown?.hex ?? "something else"). Start over and click each swatch once, slowly, without moving or scrolling the app.", swatches: swatches.map(\.color))
                            }
                        }
                    }
                }
            }
        }
    }

    private func finishPaletteLesson(_ profile: ColorPickerProfile, checked: Bool) {
        candidate = profile
        learned = profile
        onLearned(profile, pickerColor)
        note("palette learned (checked: \(checked))")
        let colors = (profile.swatches ?? []).map(\.color)
        let how = checked
            ? "DrawBot clicked one of them and the app showed exactly that color."
            : "The colors were read from the swatches themselves; check them below."
        showResult(success: true, message: "Found \(colors.count) swatches. \(how)\n\nWhen drawing, DrawBot moves the picture's colors to the closest swatches and clicks the right one for each color. Keep the palette where it is; if it moves, learn it again.", swatches: colors)
    }
}
