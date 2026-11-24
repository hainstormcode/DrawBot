import AppKit
import DrawBotCore
import SwiftUI

enum PromptMode: Equatable {
    /// Waiting for the user to pick this colour in their drawing app.
    case color
    /// Interrupted mid-colour (mouse moved, Esc during countdown…).
    case paused(reason: String)
    /// Something covers the canvas.
    case obstructed(message: String)
    /// All colours drawn.
    case done(summary: String)
    /// Colour Learn: the user demonstrates selecting this colour while DrawBot records.
    case learnDemo(recorded: String)
    /// Colour Learn: DrawBot just tried to select the colour itself — did it work?
    case learnVerify
    /// Colour Learn finished (or gave up).
    case learnResult(success: Bool, message: String)

    var isLearn: Bool {
        switch self {
        case .learnDemo, .learnVerify, .learnResult: return true
        default: return false
        }
    }
}

struct PromptContent: Equatable {
    var mode: PromptMode
    var color: RGB?
    var stepNumber: Int = 0
    var stepCount: Int = 0
    var strokeCount: Int = 0
    var strokesRemaining: Int = 0
    var estimate: String = ""
    /// "Brush: hard, round, 100% opacity, ≈ 4 px …" (colour mode only).
    var brushHint: String = ""
    /// Header for Colour Learn modes ("Teach DrawBot · colour 1 of 2").
    var title: String = ""
    /// The drawing app's name.
    var appName: String = ""
    /// An extra message (e.g. why automatic selection stopped).
    var note: String = ""
    /// Colour mode: offer "Select for me" (a learned colour picker exists).
    var canAutoSelect: Bool = false
}

enum PromptAction {
    case proceed        // Continue / Resume / Draw anyway (obstructed)
    case checkAgain
    case skip           // Skip this colour / Skip rest of this colour
    case stop
    case close
    case autoSelect     // Select for me (Colour Learn)
    case redo           // Colour Learn: start this demonstration (or the whole lesson) over
    case no             // Colour Learn: the try didn't select the right colour
    case retry          // Colour Learn: try selecting the colour again
}

/// Non-activating floating panel. Clicking its buttons never steals focus from the drawing app.
final class PromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// ⌘Q while the prompt has the keyboard quits DrawBot (the panel never activates DrawBot,
    /// so the main menu might not be consulted).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "q" {
            NSApp.terminate(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Become key (which a non-activating panel does WITHOUT activating DrawBot) before AppKit
    /// dispatches the click. A click into a non-key window otherwise depends on every view under
    /// the cursor accepting first mouse — and SwiftUI's buttons are internal views we can't
    /// override — so one click on Continue might only focus the panel.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow { makeKey() }
        super.sendEvent(event)
    }
}

final class ColorPromptController {
    private let panel: PromptPanel
    private let hosting: FirstMouseHostingView<PromptView>
    var onAction: (PromptAction) -> Void = { _ in }

    init() {
        panel = PromptPanel(contentRect: CGRect(x: 0, y: 0, width: 330, height: 300),
                            styleMask: [.titled, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
                            backing: .buffered, defer: true)
        panel.title = "DrawBot"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // Not movable by background: SwiftUI content would turn button clicks into window drags.
        // The (transparent) title bar strip at the top still moves the panel.
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        hosting = FirstMouseHostingView(rootView: PromptView(content: PromptContent(mode: .color), act: { _ in }))
        panel.contentView = hosting
    }

    var isVisible: Bool { panel.isVisible }

    func show(_ content: PromptContent, canvasCG: CGRect?, autoCopyHex: Bool) {
        hosting.rootView = PromptView(content: content, act: { [weak self] a in self?.onAction(a) })
        hosting.layoutSubtreeIfNeeded()
        panel.setContentSize(hosting.fittingSize)
        // Re-place every time: the canvas may have changed and the size differs per mode.
        panel.setFrameOrigin(ScreenUtil.placement(size: panel.frame.size, avoidingCanvasCG: canvasCG))
        if autoCopyHex, let c = content.color {
            switch content.mode {
            case .color, .learnDemo: Self.copyHex(c)
            default: break
            }
        }
        panel.orderFrontRegardless()
        // SwiftUI may settle its size a run-loop later; re-fit and re-place (a bottom-corner
        // placement must not grow off the screen or onto the canvas).
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                let fit = self.hosting.fittingSize
                let current = self.panel.contentRect(forFrameRect: self.panel.frame).size
                guard abs(fit.height - current.height) > 1 || abs(fit.width - current.width) > 1 else { return }
                self.panel.setContentSize(fit)
                self.panel.setFrameOrigin(ScreenUtil.placement(size: self.panel.frame.size, avoidingCanvasCG: canvasCG))
            }
        }
    }

    /// Replaces the content of a visible prompt without moving it (the user may have dragged it
    /// out of the way). Keeps the top-left corner fixed.
    func update(_ content: PromptContent) {
        guard panel.isVisible else { return }
        hosting.rootView = PromptView(content: content, act: { [weak self] a in self?.onAction(a) })
        hosting.layoutSubtreeIfNeeded()
        let topLeft = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.setContentSize(hosting.fittingSize)
        panel.setFrameTopLeftPoint(topLeft)
    }

    func hide() { panel.orderOut(nil) }

    static func copyHex(_ c: RGB) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(c.hexNoHash, forType: .string)
    }
}

struct PromptView: View {
    let content: PromptContent
    let act: (PromptAction) -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch content.mode {
            case .done(let summary):
                doneBody(summary)
            case .learnResult(let success, let message):
                learnResultBody(success: success, message: message)
            default:
                header
                if let c = content.color { colorInfo(c) }
                message
                buttons
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 26)
        .padding(.bottom, 16)
        .frame(width: 330, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: content) { _ in copied = false }
    }

    private var header: some View {
        HStack {
            if content.mode.isLearn {
                Label(content.title, systemImage: "wand.and.stars").font(.headline)
            } else {
                Text("Colour \(content.stepNumber) of \(content.stepCount)")
                    .font(.headline)
            }
            Spacer()
            if case .paused = content.mode {
                Label("Paused", systemImage: "pause.circle.fill").foregroundColor(.orange).font(.subheadline.weight(.semibold))
            } else if case .obstructed = content.mode {
                Label("Blocked", systemImage: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.subheadline.weight(.semibold))
            }
        }
    }

    private func colorInfo(_ c: RGB) -> some View {
        let hsb = ColorMath.hsb(c)
        return HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: c.nsColor))
                .frame(width: 84, height: 84)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(c.hex).font(.system(.title3, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                    Button(copied ? "Copied" : "Copy hex") {
                        ColorPromptController.copyHex(c)
                        copied = true
                    }
                    .controlSize(.small)
                    .help("Copies \(c.hexNoHash) (without #) to the clipboard")
                }
                Text("RGB \(c.r), \(c.g), \(c.b)").font(.system(.callout, design: .monospaced))
                Text("HSB \(Int(hsb.h.rounded()))°, \(Int(hsb.s.rounded()))%, \(Int(hsb.b.rounded()))%")
                    .font(.system(.callout, design: .monospaced))
                if content.mode.isLearn {
                    let hsl = ColorMath.hsl(c)
                    Text("HSL \(Int(hsl.h.rounded()))°, \(Int(hsl.s.rounded()))%, \(Int(hsl.l.rounded()))%")
                        .font(.system(.callout, design: .monospaced))
                }
                Text(ColorMath.approximateName(c).capitalized).font(.callout).foregroundColor(.secondary)
                if content.strokeCount > 0 {
                    Text(strokeLine).font(.callout).foregroundColor(.secondary)
                }
            }
        }
    }

    private var strokeLine: String {
        var s: String
        if content.strokesRemaining > 0 && content.strokesRemaining < content.strokeCount {
            s = "≈ \(content.strokesRemaining) of \(content.strokeCount) strokes left"
        } else {
            s = "≈ \(content.strokeCount) strokes"
        }
        if !content.estimate.isEmpty { s += " · \(content.estimate)" }
        return s
    }

    @ViewBuilder private var message: some View {
        switch content.mode {
        case .color:
            Text("Select this colour in your drawing app, then press **Continue** (⌃⌥⌘↩).")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            if !content.note.isEmpty {
                Text(content.note).font(.callout.weight(.semibold)).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !content.brushHint.isEmpty {
                Text(content.brushHint)
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .learnDemo(let recorded):
            Text("Select this colour in **\(content.appName)** the way you normally do. DrawBot is watching your clicks and typing.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("If the colour picker is a popup or dialog, open it, choose the colour, and close it again before pressing Done, every time. Typing the colour's values (the hex code, which is on the clipboard, or R, G and B) is the most reliable. Clicking works too: get as close as you can. If what you get looks different from the swatch here, your app is changing the colour; try another way. Do it the same way each time, and don't paint on the canvas.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            if !content.note.isEmpty {
                Text(content.note).font(.callout.weight(.semibold)).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("When the colour is selected, press **Done** (⌃⌥⌘↩).")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Label(recorded, systemImage: "record.circle").font(.caption).foregroundColor(.red)
        case .learnVerify:
            Text("DrawBot just tried to select this colour by itself. Is it selected in **\(content.appName)** now, with the colour picker closed again (nothing covering the canvas)?")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            if !content.note.isEmpty {
                Text(content.note).font(.callout.weight(.semibold)).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Compare it with the swatch above carefully: a slightly different shade counts as No. If you answer No, DrawBot asks you to select it yourself once more, or suggests another way to teach it.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        case .learnResult:
            EmptyView()
        case .paused(let reason):
            Text("Paused — \(reason)").font(.callout.weight(.semibold)).foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Text("Make sure this colour is still selected, then press **Resume** (⌃⌥⌘↩).")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
        case .obstructed(let msg):
            Text(msg).font(.callout.weight(.semibold)).foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Text("Windows over the canvas would receive the drawing clicks.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        case .done:
            EmptyView()
        }
    }

    @ViewBuilder private var buttons: some View {
        switch content.mode {
        case .color:
            HStack {
                Button("Stop", role: .cancel) { act(.stop) }
                Spacer()
                Button("Skip this colour") { act(.skip) }
                if content.canAutoSelect {
                    Button("Select for me") { act(.autoSelect) }
                        .help("Let DrawBot select this colour with what it learned about the colour picker")
                }
                Button("Continue") { act(.proceed) }.keyboardShortcut(.defaultAction)
            }
        case .learnDemo:
            HStack {
                Button("Cancel", role: .cancel) { act(.stop) }
                Spacer()
                Button("Start over") { act(.redo) }
                    .help("Forget what was recorded for this colour")
                Button("Done") { act(.proceed) }.keyboardShortcut(.defaultAction)
            }
        case .learnVerify:
            HStack {
                Button("Cancel", role: .cancel) { act(.stop) }
                Spacer()
                Button("Try again") { act(.retry) }
                Button("No") { act(.no) }
                Button("Yes, it worked") { act(.proceed) }.keyboardShortcut(.defaultAction)
            }
        case .learnResult:
            EmptyView()
        case .paused:
            HStack {
                Button("Stop", role: .cancel) { act(.stop) }
                Spacer()
                Button("Skip rest of colour") { act(.skip) }
                Button("Resume") { act(.proceed) }.keyboardShortcut(.defaultAction)
            }
        case .obstructed:
            HStack {
                Button("Stop", role: .cancel) { act(.stop) }
                Spacer()
                Button("Draw anyway") { act(.proceed) }
                Button("Check again") { act(.checkAgain) }.keyboardShortcut(.defaultAction)
            }
        case .done:
            EmptyView()
        }
    }

    private func learnResultBody(success: Bool, message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.system(size: 30)).foregroundColor(success ? .green : .orange)
                Text(success ? "Colour picker learned" : "Couldn't learn the colour picker").font(.title3.weight(.semibold))
            }
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                if !success {
                    Button("Cancel", role: .cancel) { act(.stop) }
                }
                Spacer()
                if success {
                    Button("Close") { act(.close) }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Start over") { act(.redo) }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func doneBody(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 30)).foregroundColor(.green)
                Text("Done!").font(.title2.weight(.semibold))
            }
            if !summary.isEmpty {
                Text(summary).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Close") { act(.close) }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
