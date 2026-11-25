import AppKit
import Carbon.HIToolbox
import Combine
import DrawBotCore
import DrawBotSystem
import ImageIO
import UniformTypeIdentifiers

/// The app that will receive the drawing.
enum DrawTarget: Equatable {
    case none
    case app(NSRunningApplication)
    /// DrawBot's own Test Canvas window.
    case testCanvas

    var displayName: String {
        switch self {
        case .none: return "Unknown (nothing found under the canvas)"
        case .app(let a): return a.localizedName ?? a.bundleIdentifier ?? "pid \(a.processIdentifier)"
        case .testCanvas: return "DrawBot Test Canvas"
        }
    }
}

/// One color of a run, frozen at Start.
struct RunStep {
    let paletteIndex: Int
    let color: RGB
    let strokes: [ScreenStroke]
    let estimate: TimeInterval
}

/// Everything a run needs, snapshotted at Start so later setting changes cannot corrupt it.
struct RunPlan {
    let canvas: CGRect
    let steps: [RunStep]
    let speed: SpeedSettings
    let pauseOnMouseMove: Bool
    let countdownSeconds: Int
    let autoCopyHex: Bool
    let penSize: Double
    let startedAt: Date
    /// The learned color picker of the target app (Color Learn), if any.
    let profile: ColorPickerProfile?
    /// Color Learn selects every color by itself instead of prompting.
    let automatic: Bool
}

/// Main-thread state machine and model for the whole app.
///
///     ready ──Select Canvas──▶ selectingCanvas ──▶ ready
///     ready ──Start──▶ awaitingColor(i) ──Continue──▶ preparing(i,r) ──▶ countdown(i,r) ──▶ drawing(i)
///                         ▲   │ Skip                  │ obstructed(i,r) ◀┘ (Check again / Draw anyway)
///                         │   ▼                       │ Esc → back to the prompt
///     drawing(i) ──completed──▶ awaitingColor(i+1) … ──▶ finished ──Close──▶ ready
///     drawing(i) ──paused──▶ paused(i,r) ──Resume──▶ preparing(i,r)   (Skip rest → next color)
///     any ──Stop──▶ ready (prompt/HUD hidden, Esc hotkey unregistered)
///
/// Color Learn (automatic color selection) replaces the prompt with
///     selectingColor(i) ──replayed──▶ preparing(i,0) …   (interrupted → awaitingColor(i) prompt)
/// and teaching DrawBot a color picker is the `learning` phase (see ColorLearnSession).
@MainActor
final class AppController: ObservableObject {
    enum Phase: Equatable {
        case ready
        case selectingCanvas
        case awaitingColor(step: Int)
        case preparing(step: Int, resumeIndex: Int)
        case obstructed(step: Int, resumeIndex: Int, message: String)
        case countdown(step: Int, resumeIndex: Int, remaining: Int)
        case drawing(step: Int)
        case paused(step: Int, resumeIndex: Int, reason: String)
        case finished
        /// Color Learn is selecting this step's color in the drawing app.
        case selectingColor(step: Int)
        /// A Color Learn lesson is running.
        case learning
    }

    // MARK: Published model

    @Published var settings: DrawSettings {
        didSet { settingsDidChange(from: oldValue) }
    }
    @Published private(set) var image: CGImage?
    @Published private(set) var imageName: String?
    @Published private(set) var canvas: CGRect?
    @Published private(set) var target: DrawTarget = .none
    @Published private(set) var result: ProcessedResult?
    @Published private(set) var isProcessing = false
    @Published private(set) var isLoadingImage = false
    @Published private(set) var skipSet: Set<Int> = []
    @Published private(set) var previewImage: CGImage?
    @Published private(set) var phase: Phase = .ready
    @Published var statusMessage: String?
    @Published private(set) var accessibilityTrusted = false
    @Published private(set) var permissionRequested = false
    @Published private(set) var drawProgress: Double = 0
    /// macOS silently dropped our events (stale TCC entry after a re-sign): the user must remove
    /// and re-add DrawBot in the Accessibility list, then relaunch.
    @Published var needsRegrant = false
    /// Learned color pickers, keyed by app (Color Learn).
    @Published private(set) var colorProfiles: [String: ColorPickerProfile] = SettingsStore.loadProfiles()

    // MARK: Private state

    private var imageToken = 0
    private let processor = ImageProcessor()
    private var plan: RunPlan?
    /// One engine for the whole session; its settings are captured at each draw() call.
    private let engine = DrawingEngine(speed: SpeedPreset.normal.settings)
    /// Invalidates pending async steps (activation, 250 ms wait, countdown ticks) of a pass.
    private var passToken = 0
    private var escRegistered = false
    private var hiddenWindows: [NSWindow] = []
    private var permissionTimer: Timer?
    private var controlPanelWasVisible = false
    private var screenObserver: NSObjectProtocol?
    /// ⌃⌥⌘P / "Show DrawBot" pressed while drawing: the panel is shown once the engine has paused
    /// (showing it right away could put it under the cursor and steal focus mid-stroke).
    private var showPanelAfterPass = false
    /// Color Learn: replays learned color-picker input.
    private let replayer = InputReplayer()
    private var learnSession: ColorLearnSession?
    /// Color each app's picker currently shows, when DrawBot set it (for knob-dragging pickers).
    private var pickerColor: [String: RGB] = [:]
    /// Shown in the color prompt after automatic selection was interrupted.
    private var autoNote = ""

    private static let escHotKeyID: UInt32 = 100

    // MARK: UI pieces (created lazily)

    private lazy var prompt: ColorPromptController = {
        let p = ColorPromptController()
        p.onAction = { [weak self] a in self?.handlePrompt(a) }
        return p
    }()
    private lazy var hud = DrawingHUDController()
    private let overlay = SelectionOverlay()
    private var testCanvas: TestCanvasWindowController?
    lazy var controlPanel: ControlPanelController = ControlPanelController(controller: self)

    init() {
        settings = SettingsStore.loadSettings()
        accessibilityTrusted = Permissions.isAccessibilityTrusted
        if let saved = SettingsStore.lastCanvas, ScreenUtil.isOnConnectedScreen(saved) {
            canvas = saved
        }
        if let path = SettingsStore.lastImagePath, FileManager.default.fileExists(atPath: path) {
            loadImage(url: URL(fileURLWithPath: path), reportErrors: false)
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        if canvas != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated { self?.captureTarget() }
            }
        }
    }

    // MARK: Derived state

    var isRunning: Bool {
        switch phase {
        case .ready, .selectingCanvas, .finished: return false
        default: return true
        }
    }

    /// A prompt is waiting for Continue / Resume / Check again / Close.
    var promptWaiting: Bool {
        switch phase {
        case .awaitingColor, .paused, .obstructed, .finished: return true
        default: return false
        }
    }

    var resultIsCurrent: Bool {
        guard let result, let key = currentKey() else { return false }
        return result.key == key
    }

    var canStart: Bool {
        !isRunning && phase != .selectingCanvas && image != nil && canvas != nil
            && accessibilityTrusted && !isProcessing && !isLoadingImage && resultIsCurrent
    }

    /// A color pass is under way (DrawBot is activating the target, counting down or drawing).
    private var passActive: Bool {
        switch phase {
        case .preparing, .countdown, .drawing, .selectingColor: return true
        default: return false
        }
    }

    /// Palette indices with pixels, in drawing order (for the swatch strip).
    var orderedPalette: [Int] {
        guard let q = result?.quantized, !q.palette.isEmpty else { return [] }
        return ColorMath.order(q, by: settings.order)
    }

    var totalOpaquePixels: Int { result?.quantized.counts.reduce(0, +) ?? 0 }

    var footerText: String {
        guard let result else {
            if isLoadingImage { return "Loading image…" }
            return image == nil ? "Choose an image to see a preview." : "Processing…"
        }
        let drawable = result.quantized.palette.indices.filter { !skipSet.contains($0) && result.quantized.counts[$0] > 0 }
        var parts = ["\(drawable.count) color\(drawable.count == 1 ? "" : "s")"]
        if result.key.isPreviewLayout {
            parts.append("select a canvas to plan strokes")
        } else {
            let strokes = drawable.reduce(0) { $0 + (result.strokes.indices.contains($1) ? result.strokes[$1].count : 0) }
            let est = result.estimates[settings.speed] ?? []
            let t = drawable.reduce(0.0) { $0 + (est.indices.contains($1) ? est[$1] : 0) }
            parts.append("\(strokes) strokes")
            parts.append("≈ \(TimeEstimator.format(t))")
        }
        if isProcessing { parts.append("updating…") }
        return parts.joined(separator: " · ")
    }

    var canvasDescription: String? {
        guard let c = canvas else { return nil }
        let screenName = ScreenUtil.screen(forCanvas: c)?.localizedName ?? "unknown screen"
        return "\(Int(c.width)) × \(Int(c.height)) pt at (\(Int(c.minX)), \(Int(c.minY))) on \(screenName)"
    }

    var gridDescription: String? {
        guard let c = canvas else { return nil }
        let l = GridLayout(canvas: c, penSize: settings.penSize)
        return "\(l.columns) × \(l.rows) cells"
    }

    var penHelperText: String {
        "Set your brush to " + Self.brushSize(pen: settings.penSize, canvas: canvas)
    }

    /// "≈ 4 px (≈ 8 px on this Retina display at 100% zoom)" for the canvas's screen.
    static func brushSize(pen: Double, canvas: CGRect?) -> String {
        let scale = (canvas.flatMap { ScreenUtil.screen(forCanvas: $0) } ?? NSScreen.screens.first)?.backingScaleFactor ?? 1
        let n = formatPen(pen)
        if scale > 1 {
            return "≈ \(n) px (≈ \(formatPen(pen * Double(scale))) px on this Retina display at 100% zoom)"
        }
        return "≈ \(n) px"
    }

    static func formatPen(_ v: Double) -> String {
        v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v)
    }

    var imageInfo: String? {
        guard let image else { return nil }
        return "\(imageName ?? "Image") — \(image.width) × \(image.height) px"
    }

    /// Color and width the Test Canvas uses for incoming strokes.
    var testCanvasStrokeStyle: (NSColor, CGFloat) {
        let width = CGFloat(plan?.penSize ?? settings.penSize)
        switch phase {
        case .drawing(let s), .preparing(let s, _), .countdown(let s, _, _):
            // Color Learn really selects colors in the Test Canvas's own picker: draw with it.
            if let plan, plan.automatic, let tc = testCanvas { return (tc.pickedColor.nsColor, width) }
            if let plan, plan.steps.indices.contains(s) { return (plan.steps[s].color.nsColor, width) }
        default: break
        }
        return (.black, width)
    }

    // MARK: Settings & processing

    private func settingsDidChange(from old: DrawSettings) {
        let c = settings.clamped()
        if c != settings { settings = c }   // didSet does not re-enter from within itself
        SettingsStore.save(settings)
        if old.maxColors != settings.maxColors || old.mergeDistance != settings.mergeDistance
            || old.penSize != settings.penSize {
            reprocess()
        }
        if old.skipNearWhite != settings.skipNearWhite { resetSkipSet() }
    }

    private func currentKey() -> ProcessingKey? {
        guard let image else { return nil }
        if let canvas {
            return ProcessingKey(imageToken: imageToken, layout: GridLayout(canvas: canvas, penSize: settings.penSize),
                                 options: settings.quantizeOptions, isPreviewLayout: false)
        }
        return ProcessingKey(imageToken: imageToken, layout: ImageProcessor.previewLayout(for: image),
                             options: settings.quantizeOptions, isPreviewLayout: true)
    }

    private func reprocess() {
        guard let image, let key = currentKey() else {
            processor.cancel()
            result = nil
            previewImage = nil
            isProcessing = false
            return
        }
        if let result, result.key == key { isProcessing = false; return }
        isProcessing = true
        processor.process(image: image, key: key) { [weak self] r in
            MainActor.assumeIsolated { self?.accept(r) }
        }
    }

    private func accept(_ r: ProcessedResult) {
        guard r.key == currentKey() else { return }
        let oldPalette = result?.quantized.palette
        result = r
        isProcessing = false
        if oldPalette != r.quantized.palette {
            resetSkipSet()
        } else {
            updatePreview()
        }
    }

    private func resetSkipSet() {
        if let q = result?.quantized, settings.skipNearWhite {
            skipSet = Set(q.palette.indices.filter { ColorMath.isNearWhite(q.palette[$0]) })
        } else {
            skipSet = []
        }
        updatePreview()
    }

    func toggleSkip(_ index: Int) {
        guard !isRunning else { return }
        if skipSet.contains(index) { skipSet.remove(index) } else { skipSet.insert(index) }
        updatePreview()
    }

    private func updatePreview() {
        guard let q = result?.quantized else { previewImage = nil; return }
        if skipSet.isEmpty, let p = result?.preview { previewImage = p }
        processor.renderPreview(q, removing: skipSet) { [weak self] img in
            MainActor.assumeIsolated { self?.previewImage = img }
        }
    }

    // MARK: Image input

    func chooseImage() {
        guard !isRunning else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an image for DrawBot to paint"
        if let last = SettingsStore.lastImagePath {
            panel.directoryURL = URL(fileURLWithPath: last).deletingLastPathComponent()
        }
        ScreenUtil.activateSelf()
        if let w = controlPanel.window, w.isVisible {
            panel.beginSheetModal(for: w) { [weak self] resp in
                MainActor.assumeIsolated {
                    if resp == .OK, let url = panel.url { self?.loadImage(url: url) }
                }
            }
        } else {
            if panel.runModal() == .OK, let url = panel.url { loadImage(url: url) }
        }
    }

    func loadImage(url: URL, reportErrors: Bool = true) {
        guard !isRunning else { return }
        isLoadingImage = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let loaded = Result { try ImageLoader.loadCGImage(from: url) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isLoadingImage = false
                    switch loaded {
                    case .success(let img):
                        self.setImage(img, name: url.lastPathComponent)
                        SettingsStore.lastImagePath = url.path
                    case .failure(let err):
                        if reportErrors { self.statusMessage = err.localizedDescription }
                    }
                }
            }
        }
    }

    func loadImage(data: Data, name: String) {
        guard !isRunning else { return }
        isLoadingImage = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let img = ImageLoader.loadCGImage(data: data)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isLoadingImage = false
                    if let img {
                        self.setImage(img, name: name)
                        SettingsStore.lastImagePath = nil   // pasted images are not saved anywhere
                    } else {
                        self.statusMessage = "That doesn't look like a readable image."
                    }
                }
            }
        }
    }

    private func setImage(_ img: CGImage, name: String) {
        imageToken += 1
        image = img
        imageName = name
        statusMessage = nil
        result = nil
        previewImage = nil
        reprocess()
    }

    /// ⌘V in the control panel.
    @discardableResult
    func pasteImage() -> Bool {
        guard !isRunning else { return false }
        let pb = NSPasteboard.general
        let urlOpts: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: urlOpts) as? [URL], let url = urls.first {
            loadImage(url: url)
            return true
        }
        let types: [NSPasteboard.PasteboardType] = [
            .png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier),
            NSPasteboard.PasteboardType(UTType.heic.identifier), NSPasteboard.PasteboardType(UTType.webP.identifier),
        ]
        for t in types {
            if let d = pb.data(forType: t) { loadImage(data: d, name: "Pasted image"); return true }
        }
        if let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation {
            loadImage(data: tiff, name: "Pasted image")
            return true
        }
        statusMessage = "The clipboard doesn't contain an image."
        return false
    }

    /// Drag-and-drop onto the control panel.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isRunning, let p = providers.first else { return false }
        if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = p.loadObject(ofClass: URL.self) { [weak self] url, _ in
                guard let url else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.loadImage(url: url) } }
            }
            return true
        }
        if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            _ = p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] data, _ in
                guard let data else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.loadImage(data: data, name: "Dropped image") } }
            }
            return true
        }
        return false
    }

    // MARK: Canvas selection

    func selectCanvas() {
        guard !isRunning, phase != .selectingCanvas else { return }
        if phase == .finished { closeDonePrompt() }
        phase = .selectingCanvas
        controlPanelWasVisible = controlPanel.isVisible
        controlPanel.hide()
        registerEsc()
        overlay.begin { [weak self] rect in self?.selectionFinished(rect) }
    }

    private func selectionFinished(_ rectCG: CGRect?) {
        unregisterEsc()
        phase = .ready
        if let rectCG {
            canvas = rectCG
            SettingsStore.lastCanvas = rectCG
            target = .none
            statusMessage = nil
            reprocess()
            // Let the overlay windows disappear before looking at what is under the canvas.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                MainActor.assumeIsolated { self?.captureTarget() }
            }
        }
        if controlPanelWasVisible { controlPanel.show() }
    }

    private func captureTarget() {
        guard let canvas else { target = .none; return }
        // WindowInspector returns NSRunningApplication.current when the canvas is on our own
        // normal-level window (the Test Canvas); our floating panels are looked through.
        if let app = WindowInspector.targetApp(for: canvas) {
            target = app.processIdentifier == getpid() ? .testCanvas : .app(app)
        } else {
            target = .none
        }
        refreshSite()
    }

    /// The website the browser under the canvas shows (nil for other apps). The user may switch
    /// tabs at any time, so this is re-read before learning, before drawing and when the panel
    /// opens.
    @Published private(set) var targetSite: SiteDetector.Site?

    func refreshSite() {
        guard case .app(let app) = target, !app.isTerminated, let canvas else {
            if targetSite != nil { targetSite = nil }
            return
        }
        let site = SiteDetector.site(of: app, at: CGPoint(x: canvas.midX, y: canvas.midY))
        if site != targetSite { targetSite = site }
    }

    /// "Zen — paintz.app", or just the app's name.
    var targetDescription: String {
        guard let site = targetSite, case .app = target else { return target.displayName }
        return "\(target.displayName) — \(site.name)"
    }

    /// Re-captures the target if it went away (terminated app, closed test canvas, nothing found).
    private func resolveTarget() {
        switch target {
        case .none: captureTarget()
        case .app(let a) where a.isTerminated: captureTarget()
        case .testCanvas where !(testCanvas?.isVisible ?? false): captureTarget()
        default: break
        }
    }

    private func screensChanged() {
        // The overlay windows were sized for the old screens.
        if phase == .selectingCanvas { overlay.cancel() }
        guard let c = canvas, !ScreenUtil.isOnConnectedScreen(c) else { return }
        if isRunning {
            stop(reason: "Displays changed")
        }
        canvas = nil
        SettingsStore.lastCanvas = nil
        target = .none
        statusMessage = "The canvas is no longer on a connected display — select it again."
        reprocess()
    }

    // MARK: Color Learn

    /// Key under which the target's learned color picker is stored: the app, plus the website
    /// for browsers (each web paint app has its own picker).
    var targetAppKey: String? {
        switch target {
        case .app(let a):
            guard let base = a.bundleIdentifier ?? a.localizedName.map({ "name:" + $0 }) else { return nil }
            if let site = targetSite { return base + "|site:" + site.key }
            return base
        case .testCanvas: return "local.drawbot.testcanvas"
        case .none: return nil
        }
    }

    var currentProfile: ColorPickerProfile? { targetAppKey.flatMap { colorProfiles[$0] } }

    var canLearn: Bool {
        !isRunning && phase != .selectingCanvas && canvas != nil && targetAppKey != nil && accessibilityTrusted
    }

    var learnStatusText: String {
        guard canvas != nil, targetAppKey != nil else {
            return "Select a canvas first. DrawBot learns the color picker of the app under the canvas."
        }
        if let p = currentProfile {
            return "Learned for \(targetDescription): \(p.summary)"
        }
        return "DrawBot hasn't learned \(targetDescription)'s color picker yet. Click Learn and select two colors while DrawBot watches."
    }

    /// Full Accessibility is needed to watch the keyboard (typing a hex code).
    var learnKeyboardWarning: String? {
        Permissions.isAXTrusted ? nil : "DrawBot can only watch typing with full Accessibility access, so it can only learn clicks."
    }

    func learnColorPicker() {
        guard !isRunning, phase != .selectingCanvas else { return }
        if phase == .finished { closeDonePrompt() }
        refreshPermission()
        guard accessibilityTrusted else {
            statusMessage = "DrawBot needs Accessibility permission to learn and use color pickers."
            showControlPanel()
            return
        }
        guard let canvas else { statusMessage = "Select a canvas first (⌃⌥⌘S)."; return }
        resolveTarget()
        refreshSite()
        guard let key = targetAppKey else {
            statusMessage = "DrawBot couldn't tell which app is under the canvas. Select the canvas again."
            return
        }
        let appName = targetDescription
        let isTestCanvas = target == .testCanvas
        let session = ColorLearnSession(
            target: .init(appKey: key, appName: appName, canvas: canvas,
                          activate: { [weak self] done in self?.activateTarget(then: done) },
                          recordsLocalWindow: { [weak self] w in
                              MainActor.assumeIsolated {
                                  guard isTestCanvas, let w, let tc = self?.testCanvas else { return false }
                                  return w === tc.window
                              }
                          },
                          careful: settings.speed == .careful,
                          watchEscape: { [weak self] on in
                              guard let self, self.phase == .learning else { return }
                              if on { self.registerEsc() } else { self.unregisterEsc() }
                          }),
            prompt: prompt, hud: hud, replayer: replayer,
            onLearned: { [weak self] profile, color in
                guard let self else { return }
                self.colorProfiles[profile.appKey] = profile
                SettingsStore.saveProfiles(self.colorProfiles)
                self.pickerColor[profile.appKey] = color
                if self.settings.colorSelection == .manual { self.settings.colorSelection = .automatic }
            },
            onEnd: { [weak self] in self?.learningEnded() })
        learnSession = session
        statusMessage = nil
        phase = .learning
        controlPanelWasVisible = controlPanel.isVisible
        controlPanel.hide()
        session.begin()
    }

    private func learningEnded() {
        learnSession = nil
        guard phase == .learning else { return }
        phase = .ready
        if let p = currentProfile {
            statusMessage = "Color picker learned for \(p.appName)."
        }
        if controlPanelWasVisible { controlPanel.show() }
    }

    func forgetColorProfile() {
        guard !isRunning, let key = targetAppKey else { return }
        colorProfiles[key] = nil
        pickerColor[key] = nil
        SettingsStore.saveProfiles(colorProfiles)
    }

    /// Brings the target app (or the Test Canvas) to the front, then calls `done`.
    private func activateTarget(then done: @escaping () -> Void) {
        switch target {
        case .testCanvas:
            openTestCanvas()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { done() }
        case .app(let app) where !app.isTerminated:
            AppActivator.activate(app) { _ in done() }
        default:
            done()
        }
    }

    /// Color Learn: select this step's color by replaying the learned picker input, then draw.
    private func autoSelect(step: Int) {
        guard let plan, let profile = plan.profile, plan.steps.indices.contains(step) else { return }
        if replayer.isRunning {
            // A canceled selection is still letting go of the mouse.
            let token = passToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.passToken == token else { return }
                    self.autoSelect(step: step)
                }
            }
            return
        }
        passToken += 1
        let token = passToken
        autoNote = ""
        prompt.hide()
        phase = .selectingColor(step: step)
        showHUD()
        registerEsc()
        resolveTarget()
        hideOwnWindowsOverlappingCanvas(plan.canvas)
        if let b = profile.pointerBounds { hideOwnWindowsOverlappingCanvas(b) }
        let color = plan.steps[step].color
        activateTarget { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated {
                    guard let self, self.passToken == token else { return }
                    // Never replay picker clicks into whatever other app happens to be in front.
                    if case .app(let app) = self.target, AppActivator.frontmostPID != app.processIdentifier {
                        self.unregisterEsc()
                        self.hud.hide()
                        self.phase = .awaitingColor(step: step)
                        self.autoNote = "Couldn't bring \(app.localizedName ?? "the drawing app") to the front to select the color. Click its window once (outside the canvas), then press Select for me."
                        self.showPrompt()
                        return
                    }
                    ModifierWait.whenReleased(quiet: pickerQuietPeriod, deadline: Date().addingTimeInterval(5)) { [weak self] in
                        guard let self, self.passToken == token else { return }
                        self.replayer.careful = plan.speed == SpeedPreset.careful.settings
                        self.replayer.stopOnUserMouseMove = plan.pauseOnMouseMove
                        let actions = profile.actions(for: color, previous: self.pickerColor[profile.appKey])
                        self.replayer.run(actions) { [weak self] outcome in
                            MainActor.assumeIsolated {
                                self?.autoSelectFinished(step: step, color: color, key: profile.appKey, outcome: outcome, token: token)
                            }
                        }
                    }
                }
            }
        }
    }

    private func autoSelectFinished(step: Int, color: RGB, key: String, outcome: InputReplayer.Outcome, token: Int) {
        guard passToken == token, case .selectingColor(let s) = phase, s == step else { return }
        switch outcome {
        case .completed:
            pickerColor[key] = color
            phase = .preparing(step: step, resumeIndex: 0)
            showHUD()
            checkCanvasThenCountdown(step: step, resumeIndex: 0, checkObstructions: true, token: token)
        case .stopped(let reason):
            pickerColor[key] = nil
            unregisterEsc()
            hud.hide()
            phase = .awaitingColor(step: step)
            autoNote = "Automatic color selection stopped (\(reason)). Select the color yourself and press Continue, or press Select for me."
            showPrompt()
            if case DrawingEngine.Reason.permissionLost = reason { refreshPermission() }
        }
    }

    // MARK: Permissions

    func refreshPermission() {
        let t = Permissions.isAccessibilityTrusted
        if t != accessibilityTrusted { accessibilityTrusted = t }
        if t { permissionRequested = false }
    }

    func grantPermission() {
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
        permissionRequested = true
    }

    func showPermissions() {
        refreshPermission()
        showControlPanel()
        if !accessibilityTrusted { grantPermission() }
    }

    func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        if bundlePath.hasSuffix(".app") {
            task.arguments = ["-c", "sleep 0.8; /usr/bin/open -n \"$1\"", "sh", bundlePath]
        } else {
            task.arguments = ["-c", "sleep 0.8; \"$1\" >/dev/null 2>&1 &", "sh", Bundle.main.executablePath ?? CommandLine.arguments[0]]
        }
        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            statusMessage = "Couldn't relaunch automatically — quit and reopen DrawBot."
        }
    }

    /// Polls the Accessibility state every second while the control panel is visible.
    func controlPanelVisibilityChanged(_ visible: Bool) {
        permissionTimer?.invalidate()
        permissionTimer = nil
        guard visible else { return }
        refreshPermission()
        refreshSite()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermission() }
        }
        RunLoop.main.add(t, forMode: .common)
        permissionTimer = t
    }

    // MARK: Windows

    func showControlPanel() {
        switch phase {
        case .preparing(let s, let r), .countdown(let s, let r, _):
            // Showing (and activating) the panel now would undo the target activation and might
            // cover the canvas: go back to the prompt first.
            cancelPassBackToPrompt(step: s, resumeIndex: r)
        case .selectingColor(let s):
            replayer.requestStop(reason: "Paused to show the DrawBot panel")
            cancelPassBackToPrompt(step: s, resumeIndex: 0)
        case .drawing:
            showPanelAfterPass = true
            engine.requestPause(reason: "Paused to show the DrawBot panel")
            return   // passFinished shows it
        default:
            break
        }
        controlPanel.show()
    }

    func openTestCanvas() {
        // Don't pop a window (and activate DrawBot) in the middle of a pass into another app.
        if passActive && target != .testCanvas { return }
        if testCanvas == nil {
            testCanvas = TestCanvasWindowController(strokeStyle: { [weak self] in
                MainActor.assumeIsolated { self?.testCanvasStrokeStyle ?? (.black, 4) }
            })
        }
        testCanvas?.show()
    }

    /// Our own windows (control panel, test canvas when it is not the target) would catch the
    /// synthetic clicks — WindowInspector deliberately ignores them — so move them away.
    private func hideOwnWindowsOverlappingCanvas(_ canvasCG: CGRect) {
        let canvasCocoa = ScreenUtil.toCocoa(canvasCG)
        var candidates: [NSWindow] = []
        if let w = controlPanel.window { candidates.append(w) }
        if let tc = testCanvas, target != .testCanvas { candidates.append(tc.window) }
        for w in candidates where w.isVisible && w.frame.intersects(canvasCocoa) {
            w.orderOut(nil)
            if !hiddenWindows.contains(where: { $0 === w }) { hiddenWindows.append(w) }
        }
    }

    private func restoreHiddenWindows() {
        for w in hiddenWindows { w.orderFront(nil) }
        hiddenWindows.removeAll()
    }

    // MARK: Esc hotkey (only while selecting / preparing / counting down / drawing)

    private func registerEsc() {
        guard !escRegistered else { return }
        escRegistered = HotKeyCenter.shared.register(id: Self.escHotKeyID, keyCode: UInt32(kVK_Escape), modifiers: []) { [weak self] in
            self?.escPressed()
        }
    }

    private func unregisterEsc() {
        guard escRegistered else { return }
        HotKeyCenter.shared.unregister(id: Self.escHotKeyID)
        escRegistered = false
    }

    private func escPressed() {
        switch phase {
        case .selectingCanvas:
            overlay.cancel()
        case .preparing(let s, let r), .countdown(let s, let r, _):
            cancelPassBackToPrompt(step: s, resumeIndex: r)
        case .drawing:
            engine.requestStop(reason: DrawingEngine.Reason.escape)
        case .selectingColor(let s):
            replayer.requestStop(reason: DrawingEngine.Reason.escape)
            cancelPassBackToPrompt(step: s, resumeIndex: 0)
        case .learning:
            learnSession?.escape()
        default:
            unregisterEsc()
        }
    }

    // MARK: Run control

    /// Menu "Start/Continue" and the control panel's Start button.
    func startOrContinue() {
        if phase == .learning || (promptWaiting && phase != .finished) {
            continueFromHotkey()
        } else {
            start()
        }
    }

    func start() {
        guard !isRunning, phase != .selectingCanvas else { return }
        if phase == .finished { closeDonePrompt() }
        refreshPermission()
        guard accessibilityTrusted else {
            statusMessage = "DrawBot needs Accessibility permission to move the mouse."
            showControlPanel()
            Permissions.requestAccessibility()
            permissionRequested = true
            return
        }
        guard image != nil else { statusMessage = "Choose an image first."; showControlPanel(); return }
        guard let canvas else { statusMessage = "Select a canvas first (⌃⌥⌘S)."; showControlPanel(); return }
        guard ScreenUtil.isOnConnectedScreen(canvas) else {
            statusMessage = "The canvas is no longer on a connected display — select it again."
            showControlPanel()
            return
        }
        guard let result, resultIsCurrent, !isProcessing else {
            statusMessage = "Still processing the image — try again in a moment."
            return
        }
        let q = result.quantized
        let est = result.estimates[settings.speed] ?? []
        let steps: [RunStep] = ColorMath.order(q, by: settings.order).compactMap { i in
            guard !skipSet.contains(i), result.strokes.indices.contains(i), !result.strokes[i].isEmpty else { return nil }
            return RunStep(paletteIndex: i, color: q.palette[i], strokes: result.strokes[i],
                           estimate: est.indices.contains(i) ? est[i] : 0)
        }
        guard !steps.isEmpty else {
            statusMessage = "Nothing to draw — every color is skipped."
            showControlPanel()
            return
        }
        resolveTarget()
        refreshSite()
        let profile = currentProfile
        let automatic = settings.colorSelection == .automatic
        if automatic && profile == nil {
            statusMessage = target == .none
                ? "DrawBot couldn't tell which app is under the canvas. Select the canvas again."
                : "DrawBot hasn't learned \(targetDescription)'s color picker yet. Click Learn Color Picker…, or set Color selection to “Ask me”."
            showControlPanel()
            return
        }
        plan = RunPlan(canvas: canvas, steps: steps, speed: settings.speed.settings,
                       pauseOnMouseMove: settings.pauseOnMouseMove, countdownSeconds: settings.countdownSeconds,
                       autoCopyHex: settings.autoCopyHex, penSize: settings.penSize, startedAt: Date(),
                       profile: profile, automatic: automatic && profile != nil)
        statusMessage = nil
        needsRegrant = false
        autoNote = ""
        if automatic && profile != nil {
            autoSelect(step: 0)
            return
        }
        phase = .awaitingColor(step: 0)
        showPrompt()
        // Bring the drawing app forward so the user can pick the first color straight away.
        if case .app(let app) = target, !app.isTerminated {
            AppActivator.activate(app) { _ in }
        }
    }

    /// ⌃⌥⌘↩ — acts only when a prompt is waiting.
    func continueFromHotkey() {
        switch phase {
        case .awaitingColor, .paused: handlePrompt(.proceed)
        case .obstructed: handlePrompt(.checkAgain)
        case .finished: handlePrompt(.close)
        case .learning: learnSession?.hotkeyProceed()
        default: break
        }
    }

    /// Stop from any state: back to ready with everything cleaned up.
    func stop(reason: String = "Stopped by user") {
        switch phase {
        case .ready:
            return
        case .selectingCanvas:
            overlay.cancel()
        case .drawing:
            if engine.isRunning {
                engine.requestStop(reason: reason)   // completion → endRun
            } else {
                endRun(message: "Stopped: \(reason)")
            }
        case .finished:
            closeDonePrompt()
        case .learning:
            learnSession?.cancel()
        default:
            endRun(message: "Stopped: \(reason)")
        }
    }

    private func handlePrompt(_ action: PromptAction) {
        if phase == .learning {
            learnSession?.handle(action)
            return
        }
        switch (phase, action) {
        case (.awaitingColor(let s), .autoSelect):
            autoSelect(step: s)
        case (.awaitingColor(let s), .proceed):
            beginPass(step: s, resumeIndex: 0, checkObstructions: true)
        case (.paused(let s, let r, _), .proceed):
            beginPass(step: s, resumeIndex: r, checkObstructions: true)
        case (.obstructed(let s, let r, _), .proceed):
            beginPass(step: s, resumeIndex: r, checkObstructions: false)   // "Draw anyway"
        case (.obstructed(let s, let r, _), .checkAgain):
            beginPass(step: s, resumeIndex: r, checkObstructions: true)
        case (.awaitingColor(let s), .skip), (.paused(let s, _, _), .skip):
            advance(from: s)
        case (.finished, _):
            closeDonePrompt()
        case (_, .stop):
            stop()
        default:
            break
        }
    }

    private func beginPass(step: Int, resumeIndex: Int, checkObstructions: Bool) {
        guard let plan else { return }
        passToken += 1
        let token = passToken
        prompt.hide()
        phase = .preparing(step: step, resumeIndex: resumeIndex)
        showHUD()
        registerEsc()
        resolveTarget()
        hideOwnWindowsOverlappingCanvas(plan.canvas)

        let afterActivation: () -> Void = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated {
                    guard let self, self.passToken == token else { return }
                    self.checkCanvasThenCountdown(step: step, resumeIndex: resumeIndex,
                                                  checkObstructions: checkObstructions, token: token)
                }
            }
        }
        switch target {
        case .testCanvas:
            // Drawing into ourselves: no activation of another app, just bring the window forward.
            openTestCanvas()
            afterActivation()
        case .app(let app) where !app.isTerminated:
            AppActivator.activate(app) { [weak self] ok in
                guard let self, self.passToken == token else { return }
                // If the drawing app isn't frontmost, its first click usually only activates the
                // window, silently losing the first stroke. Ask the user (unless "Draw anyway").
                if !ok, checkObstructions, AppActivator.frontmostPID != app.processIdentifier {
                    let name = app.localizedName ?? "the drawing app"
                    var message = "Couldn't bring \(name) to the front. Click its window once (outside the canvas, e.g. its title bar or toolbar), then press Check again."
                    if !AppActivator.canForceActivation {
                        message += " Granting DrawBot full Accessibility access lets it do this itself."
                    }
                    self.unregisterEsc()
                    self.hud.hide()
                    self.phase = .obstructed(step: step, resumeIndex: resumeIndex, message: message)
                    self.showPrompt()
                    return
                }
                afterActivation()
            }
        default:
            afterActivation()
        }
    }

    private func checkCanvasThenCountdown(step: Int, resumeIndex: Int, checkObstructions: Bool, token: Int) {
        guard let plan, case .preparing = phase else { return }
        let targetPID: pid_t?
        switch target {
        case .app(let app): targetPID = app.processIdentifier
        // Our own windows don't count, but another app's window over the Test Canvas does.
        case .testCanvas: targetPID = getpid()
        case .none: targetPID = nil
        }
        if checkObstructions, let targetPID {
            let obstructions = WindowInspector.obstructions(of: plan.canvas, targetPID: targetPID)
            if !obstructions.isEmpty {
                var names: [String] = []
                for o in obstructions {
                    let name = o.ownerName.isEmpty ? "another app" : o.ownerName
                    if !names.contains(name) { names.append(name) }
                }
                let message = "Something from \(Self.listFormat(names)) is covering the canvas — move it away."
                unregisterEsc()
                hud.hide()
                phase = .obstructed(step: step, resumeIndex: resumeIndex, message: message)
                showPrompt()
                return
            }
        }
        countdown(step: step, resumeIndex: resumeIndex, remaining: plan.countdownSeconds, token: token)
    }

    private func countdown(step: Int, resumeIndex: Int, remaining: Int, token: Int) {
        guard passToken == token else { return }
        if remaining <= 0 {
            waitForModifierRelease(step: step, resumeIndex: resumeIndex, token: token, deadline: Date().addingTimeInterval(5))
            return
        }
        phase = .countdown(step: step, resumeIndex: resumeIndex, remaining: remaining)
        showHUD()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                self?.countdown(step: step, resumeIndex: resumeIndex, remaining: remaining - 1, token: token)
            }
        }
    }

    /// Synthetic events inherit the keyboard's modifier state; if the user is still holding
    /// ⌃⌥⌘ from the Continue hotkey, clicks would become right-clicks / ⌘-clicks. Wait for release.
    private func waitForModifierRelease(step: Int, resumeIndex: Int, token: Int, deadline: Date) {
        guard passToken == token else { return }
        let held = NSEvent.modifierFlags.intersection([.control, .option, .command, .shift])
        if held.isEmpty || Date() > deadline {
            startDrawing(step: step, resumeIndex: resumeIndex)
            return
        }
        phase = .countdown(step: step, resumeIndex: resumeIndex, remaining: 0)
        showHUD()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                self?.waitForModifierRelease(step: step, resumeIndex: resumeIndex, token: token, deadline: deadline)
            }
        }
    }

    private func startDrawing(step: Int, resumeIndex: Int, attempt: Int = 0) {
        if engine.isRunning {
            // A previous pass is still releasing (stop raced with a new start). Retry briefly.
            let token = passToken
            if attempt < 40 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.passToken == token else { return }
                        self.startDrawing(step: step, resumeIndex: resumeIndex, attempt: attempt + 1)
                    }
                }
            } else {
                endRun(message: "Stopped: the previous pass did not finish")
            }
            return
        }
        guard let plan, plan.steps.indices.contains(step) else {
            endRun(message: "Stopped: internal error (no color to draw)")
            return
        }
        let strokes = plan.steps[step].strokes
        guard resumeIndex < strokes.count else {
            passToken += 1
            unregisterEsc()
            hud.hide()
            advance(from: step)
            return
        }
        if target == .testCanvas, let tc = testCanvas { tc.window.orderFront(nil) }
        engine.speed = plan.speed
        engine.pauseOnUserMouseMove = plan.pauseOnMouseMove
        drawProgress = Double(resumeIndex) / Double(max(1, strokes.count))
        phase = .drawing(step: step)
        showHUD()
        engine.draw(strokes: strokes, startingAt: resumeIndex, clampRect: plan.canvas, progress: { [weak self] p in
            MainActor.assumeIsolated {
                guard let self, case .drawing(let s) = self.phase, s == step else { return }
                self.drawProgress = p.fraction
                self.showHUD()
            }
        }, completion: { [weak self] outcome in
            MainActor.assumeIsolated { self?.passFinished(step: step, outcome: outcome) }
        })
    }

    private func passFinished(step: Int, outcome: DrawingEngine.Outcome) {
        // A late completion after the run was already torn down must not restart anything (nor
        // take Esc away from a pass / canvas selection that has started since).
        guard case .drawing(let s) = phase, s == step else {
            if !passActive && phase != .selectingCanvas { unregisterEsc() }
            return
        }
        unregisterEsc()
        hud.hide()
        let wantsPanel = showPanelAfterPass
        showPanelAfterPass = false
        defer { if wantsPanel { controlPanel.show() } }
        switch outcome {
        case .completed:
            advance(from: step)
        case .paused(let resumeIndex, let reason):
            phase = .paused(step: step, resumeIndex: resumeIndex, reason: reason)
            showPrompt()
        case .stopped(let reason):
            endRun(message: "Stopped: \(reason)")
            switch reason {
            case DrawingEngine.Reason.eventsIgnored:
                needsRegrant = true
                showControlPanel()
            case DrawingEngine.Reason.permissionMissing, DrawingEngine.Reason.permissionLost:
                refreshPermission()
                permissionRequested = true
                showControlPanel()
            default:
                break
            }
        }
    }

    private func cancelPassBackToPrompt(step: Int, resumeIndex: Int) {
        passToken += 1
        unregisterEsc()
        hud.hide()
        phase = resumeIndex == 0 ? .awaitingColor(step: step) : .paused(step: step, resumeIndex: resumeIndex, reason: "Canceled")
        showPrompt()
    }

    private func advance(from step: Int) {
        guard let plan else { endRun(message: nil); return }
        let next = step + 1
        autoNote = ""
        if next < plan.steps.count {
            if plan.automatic {
                autoSelect(step: next)
                return
            }
            phase = .awaitingColor(step: next)
            showPrompt()
        } else {
            finishRun()
        }
    }

    private func finishRun() {
        guard let plan else { return }
        passToken += 1
        unregisterEsc()
        hud.hide()
        restoreHiddenWindows()
        let elapsed = Date().timeIntervalSince(plan.startedAt)
        let strokes = plan.steps.reduce(0) { $0 + $1.strokes.count }
        phase = .finished
        statusMessage = "Done — \(plan.steps.count) color\(plan.steps.count == 1 ? "" : "s"), \(strokes) strokes."
        prompt.show(PromptContent(mode: .done(summary: "Painted \(plan.steps.count) color\(plan.steps.count == 1 ? "" : "s") (\(strokes) strokes) in \(TimeEstimator.format(elapsed))."),
                                  color: nil),
                    canvasCG: plan.canvas, autoCopyHex: false)
        self.plan = nil
    }

    private func closeDonePrompt() {
        prompt.hide()
        if phase == .finished { phase = .ready }
    }

    private func endRun(message: String?) {
        passToken += 1
        showPanelAfterPass = false
        if engine.isRunning { engine.requestStop(reason: "Stopped") }
        if replayer.isRunning { replayer.requestStop(reason: "Stopped") }
        unregisterEsc()
        prompt.hide()
        hud.hide()
        restoreHiddenWindows()
        plan = nil
        drawProgress = 0
        phase = .ready
        if let message { statusMessage = message }
    }

    // MARK: Prompt & HUD content

    private func showPrompt() {
        guard let plan else { return }
        let step: Int
        let mode: PromptMode
        var remaining = 0
        switch phase {
        case .awaitingColor(let s):
            step = s; mode = .color
        case .paused(let s, let r, let reason):
            step = s; mode = .paused(reason: reason); remaining = plan.steps.indices.contains(s) ? plan.steps[s].strokes.count - r : 0
        case .obstructed(let s, let r, let message):
            step = s; mode = .obstructed(message: message); remaining = plan.steps.indices.contains(s) ? plan.steps[s].strokes.count - r : 0
        default:
            return
        }
        guard plan.steps.indices.contains(step) else { return }
        let st = plan.steps[step]
        var content = PromptContent(mode: mode, color: st.color, stepNumber: step + 1, stepCount: plan.steps.count,
                                    strokeCount: st.strokes.count, strokesRemaining: remaining,
                                    estimate: st.estimate > 0 ? "≈ \(TimeEstimator.format(st.estimate))" : "",
                                    brushHint: "Brush: hard, round, 100% opacity, " + Self.brushSize(pen: plan.penSize, canvas: plan.canvas))
        if mode == .color {
            content.canAutoSelect = plan.profile != nil
            content.note = autoNote
        }
        prompt.show(content, canvasCG: plan.canvas, autoCopyHex: plan.autoCopyHex && mode == .color)
    }

    private func showHUD() {
        guard let plan else { return }
        let step: Int
        let mode: HUDContent.Mode
        switch phase {
        case .preparing(let s, _): step = s; mode = .preparing
        case .countdown(let s, _, let n): step = s; mode = .countdown(n)
        case .drawing(let s): step = s; mode = .drawing(fraction: drawProgress)
        case .selectingColor(let s): step = s; mode = .selectingColor
        default: return
        }
        guard plan.steps.indices.contains(step) else { return }
        hud.show(HUDContent(mode: mode, color: plan.steps[step].color, stepNumber: step + 1, stepCount: plan.steps.count),
                 canvasCG: plan.canvas)
    }

    // MARK: Quitting

    /// Quit while the engine is drawing: stop it and wait (≤ 2 s) until the worker has released the
    /// mouse button, so the system is never left with a synthetic button held down.
    func prepareForTermination(_ done: @escaping () -> Void) {
        stop(reason: "Quitting")
        waitForEngineIdle(deadline: Date().addingTimeInterval(2), done)
    }

    var isEngineRunning: Bool { engine.isRunning || replayer.isRunning }

    private func waitForEngineIdle(deadline: Date, _ done: @escaping () -> Void) {
        if (!engine.isRunning && !replayer.isRunning) || Date() > deadline { done(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { done(); return }
                self.waitForEngineIdle(deadline: deadline, done)
            }
        }
    }

    static func listFormat(_ names: [String]) -> String {
        switch names.count {
        case 0: return "another app"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }

    // MARK: Status text for the menu / panel

    var phaseDescription: String {
        switch phase {
        case .ready: return canStart ? "Ready to draw" : "Not ready"
        case .selectingCanvas: return "Selecting canvas…"
        case .awaitingColor(let s): return "Waiting for color \(s + 1)"
        case .preparing: return "Getting ready…"
        case .obstructed: return "Canvas is covered"
        case .countdown(_, _, let n): return "Starting in \(n)…"
        case .drawing(let s): return "Drawing color \(s + 1) · \(Int(drawProgress * 100))%"
        case .paused(_, _, let reason): return "Paused — \(reason)"
        case .finished: return "Done!"
        case .selectingColor(let s): return "Selecting color \(s + 1)…"
        case .learning: return "Learning the color picker…"
        }
    }
}
