import AppKit
import DrawBotCore
import DrawBotSystem
import SwiftUI
import UniformTypeIdentifiers

/// Floating, normal-activating panel (so pickers and steppers work) that also handles ⌘V / ⌘W
/// itself — an accessory app has no Edit menu to route them.
final class ControlNSPanel: NSPanel {
    var onPaste: () -> Bool = { false }

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let chars = event.charactersIgnoringModifiers?.lowercased() {
            switch chars {
            case "v": if onPaste() { return true }
            case "w": performClose(nil); return true
            case "q": NSApp.terminate(nil); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class ControlPanelController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private unowned let controller: AppController

    init(controller: AppController) {
        self.controller = controller
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    private func makeWindow() -> NSWindow {
        let panel = ControlNSPanel(contentRect: CGRect(x: 0, y: 0, width: 420, height: 640),
                                   styleMask: [.titled, .closable, .resizable],
                                   backing: .buffered, defer: false)
        panel.title = "DrawBot"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = CGSize(width: 380, height: 420)
        panel.onPaste = { [weak self] in
            MainActor.assumeIsolated { self?.controller.pasteImage() ?? false }
        }
        let hosting = NSHostingView(rootView: ControlPanelView(controller: controller))
        // Only the SwiftUI minimum constrains the window. With the default options the scroll
        // view's ideal (content) height would pin the panel's size and stop it resizing.
        hosting.sizingOptions = [.minSize]
        panel.contentView = hosting
        panel.setContentSize(CGSize(width: 420, height: 640))
        panel.delegate = self
        if let screen = NSScreen.screens.first {
            let vf = screen.visibleFrame
            panel.setFrameOrigin(CGPoint(x: vf.maxX - panel.frame.width - 24, y: vf.maxY - panel.frame.height - 24))
        }
        panel.setFrameAutosaveName("DrawBotControlPanel")
        return panel
    }

    func show() {
        let w = window ?? makeWindow()
        window = w
        ScreenUtil.activateSelf()
        w.makeKeyAndOrderFront(nil)
        controller.controlPanelVisibilityChanged(true)
    }

    func hide() {
        guard let w = window, w.isVisible else { return }
        w.orderOut(nil)
        controller.controlPanelVisibilityChanged(false)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { controller.controlPanelVisibilityChanged(false) }
    }
}

// MARK: - SwiftUI

struct ControlPanelView: View {
    @ObservedObject var controller: AppController
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PermissionRow(controller: controller)
                    imageSection
                    canvasSection
                    colorSelectionSection
                    settingsSection
                    previewSection
                }
                .padding(16)
            }
            Divider()
            bottomBar
        }
        .frame(minWidth: 380, minHeight: 420)
        .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $dropTargeted) { providers in
            controller.handleDrop(providers)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .opacity(dropTargeted ? 1 : 0)
                .allowsHitTesting(false)
        )
    }

    // MARK: Sections

    private var imageSection: some View {
        Section2(title: "Image") {
            HStack(spacing: 8) {
                Button("Choose Image…") { controller.chooseImage() }
                Button("Paste") { controller.pasteImage() }
                    .help("Paste an image from the clipboard (⌘V)")
                Spacer()
                if controller.isLoadingImage { ProgressView().controlSize(.small) }
            }
            if let info = controller.imageInfo {
                Text(info).font(.callout).lineLimit(1).truncationMode(.middle)
            } else {
                Text("Choose, drop or paste (⌘V) an image.").font(.callout).foregroundColor(.secondary)
            }
        }
        .disabled(controller.isRunning)
    }

    private var canvasSection: some View {
        Section2(title: "Canvas") {
            HStack(spacing: 8) {
                Button("Select Canvas (⌃⌥⌘S)") { controller.selectCanvas() }
                Button("Test Canvas") { controller.openTestCanvas() }
                    .help("Open a blank window to try DrawBot without a paint app")
                Spacer()
            }
            if let d = controller.canvasDescription {
                Text(d).font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Text("Drawing into:").foregroundColor(.secondary)
                    Text(controller.targetDescription).lineLimit(1).truncationMode(.tail)
                }
                .font(.callout)
                if let g = controller.gridDescription {
                    Text(g).font(.caption).foregroundColor(.secondary)
                }
            } else {
                Text("Drag a rectangle over the drawing area of your paint app.")
                    .font(.callout).foregroundColor(.secondary)
            }
        }
        .disabled(controller.isRunning)
    }

    private var colorSelectionSection: some View {
        Section2(title: "Color selection") {
            Picker("", selection: $controller.settings.colorSelection) {
                ForEach(ColorSelectionMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            HStack(alignment: .top, spacing: 6) {
                if controller.currentProfile != nil {
                    Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                } else if controller.settings.colorSelection == .automatic {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                }
                Text(controller.learnStatusText)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(controller.currentProfile == nil ? "Learn Color Picker…" : "Learn Again…") {
                    controller.learnColorPicker()
                }
                .disabled(!controller.canLearn)
                .help("Select two colors in your drawing app while DrawBot watches; it then selects colors by itself")
                if controller.currentProfile != nil {
                    Button("Forget") { controller.forgetColorProfile() }
                        .help("Delete what DrawBot learned about this app's color picker")
                }
                Spacer()
            }
            if let warning = controller.learnKeyboardWarning {
                Text(warning).font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("Color Learn watches you select two colors (clicks, drags and typing, e.g. a hex code), works out how your color picker works, tries a third color and asks if it worked. Afterwards DrawBot selects every color by itself.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .disabled(controller.isRunning)
    }

    private var settingsSection: some View {
        Section2(title: "Settings") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Colors")
                    HStack {
                        Slider(value: intBinding(\.maxColors), in: 1...32)
                        Stepper("\(controller.settings.maxColors)", value: $controller.settings.maxColors, in: DrawSettings.colorRange)
                            .monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                    }
                    .help("How many colors to draw with. 1 makes a doodle: the picture is split into a dark and a light half, the light half is left as blank canvas, and only the dark half is drawn, like black pen on white paper.")
                }
                GridRow {
                    Text("Merge similar")
                    HStack {
                        Slider(value: roundedBinding(\.mergeDistance), in: DrawSettings.mergeRange)
                        Text(controller.settings.mergeDistance < 0.5 ? "Off" : "\(Int(controller.settings.mergeDistance))")
                            .monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                    .help("Colors closer together than this are merged into one. 0 keeps every color apart; around 10 merges shades that are hard to tell apart.")
                }
                GridRow {
                    Text("Pen size")
                    HStack {
                        Slider(value: roundedBinding(\.penSize), in: DrawSettings.penRange)
                        Stepper("\(AppController.formatPen(controller.settings.penSize)) pt",
                                value: $controller.settings.penSize, in: DrawSettings.penRange, step: 1)
                            .monospacedDigit()
                            .frame(width: 72, alignment: .trailing)
                    }
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Text(controller.penHelperText)
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                GridRow {
                    Text("Speed")
                    Picker("", selection: $controller.settings.speed) {
                        ForEach(SpeedPreset.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Color selection")
                    Picker("", selection: $controller.settings.selectionSpeed) {
                        ForEach(SelectionSpeed.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .disabled(controller.settings.colorSelection != .automatic)
                    .help("How quickly DrawBot selects each color when it selects colors automatically: the pauses before and between its clicks and keystrokes. Fast and Ludicrous also skip the countdown after the first color. If colors come out wrong (the app needs time to open its picker), go slower.")
                }
                GridRow {
                    Text("Strokes")
                    Picker("", selection: $controller.settings.strokeStyle) {
                        ForEach(StrokeStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .help("A* paths keep the pen down across each shape, steering around other colors: far fewer strokes, usually faster. Top to bottom paints each color row by row, one stroke per stretch.")
                }
                GridRow {
                    Text("Color order")
                    Picker("", selection: $controller.settings.order) {
                        ForEach(ColorOrder.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Countdown")
                    Stepper("\(controller.settings.countdownSeconds) s", value: $controller.settings.countdownSeconds,
                            in: DrawSettings.countdownRange)
                        .monospacedDigit()
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Pause if I move the mouse", isOn: $controller.settings.pauseOnMouseMove)
                Toggle("Skip near-white colors", isOn: $controller.settings.skipNearWhite)
            }
            .padding(.top, 2)
        }
        .disabled(controller.isRunning)
    }

    private var previewSection: some View {
        Section2(title: "Preview") {
            ZStack {
                if let img = controller.previewImage {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                        .background(Checkerboard())
                        .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.05))
                        .overlay(Text(controller.image == nil ? "No image" : "Processing…").foregroundColor(.secondary))
                }
                if controller.isProcessing && controller.previewImage != nil {
                    ProgressView().controlSize(.small)
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 200)

            PaletteStrip(controller: controller)

            Text(controller.footerText).font(.caption).foregroundColor(.secondary)
        }
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let msg = controller.statusMessage {
                Text(msg).font(.callout)
                    .foregroundColor(msg.hasPrefix("Stopped") || msg.contains("needs") ? .orange : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(controller.phaseDescription).font(.caption).foregroundColor(.secondary)
                Spacer()
                if controller.isRunning {
                    Button("Stop (⌃⌥⌘.)") { controller.stop() }
                }
                Button(action: { controller.start() }) {
                    Text("Start Drawing").frame(minWidth: 110)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(!controller.canStart)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Whole numbers without `step:` (which draws tick marks under macOS sliders).
    private func roundedBinding(_ kp: WritableKeyPath<DrawSettings, Double>) -> Binding<Double> {
        Binding(get: { controller.settings[keyPath: kp] },
                set: { v in
                    let r = v.rounded()
                    if controller.settings[keyPath: kp] != r { controller.settings[keyPath: kp] = r }
                })
    }

    private func intBinding(_ kp: WritableKeyPath<DrawSettings, Int>) -> Binding<Double> {
        Binding(get: { Double(controller.settings[keyPath: kp]) },
                set: { controller.settings[keyPath: kp] = Int($0.rounded()) })
    }
}

/// A titled group with consistent styling in light and dark mode.
struct Section2<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 8, content: content)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }
}

struct PermissionRow: View {
    @ObservedObject var controller: AppController

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(controller.accessibilityTrusted ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
            if controller.accessibilityTrusted {
                Text("Ready").font(.callout.weight(.medium))
                Spacer()
            } else {
                Text("DrawBot needs Accessibility permission")
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Grant…") { controller.grantPermission() }
                if controller.permissionRequested {
                    Button("Relaunch DrawBot") { controller.relaunch() }
                        .help("macOS sometimes only applies the permission after a relaunch")
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill((controller.accessibilityTrusted && !controller.needsRegrant ? Color.green : Color.orange).opacity(0.12)))
        if controller.needsRegrant {
            VStack(alignment: .leading, spacing: 6) {
                Text("macOS ignored DrawBot's mouse events. Remove DrawBot from Privacy & Security → Accessibility (–), add it again (+), then relaunch.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Accessibility Settings") { Permissions.openAccessibilitySettings() }
                    Button("Relaunch DrawBot") { controller.relaunch() }
                    Spacer()
                    Button("Dismiss") { controller.needsRegrant = false }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        }
    }
}

struct PaletteStrip: View {
    @ObservedObject var controller: AppController

    var body: some View {
        let indices = controller.orderedPalette
        let total = max(1, controller.totalOpaquePixels)
        if let q = controller.result?.quantized, !indices.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)], spacing: 6) {
                ForEach(indices, id: \.self) { i in
                    if q.palette.indices.contains(i) {
                        Swatch(color: q.palette[i], percent: Double(q.counts[i]) / Double(total) * 100,
                               skipped: controller.skipSet.contains(i))
                            .onTapGesture { controller.toggleSkip(i) }
                            .help(controller.skipSet.contains(i) ? "Skipped — click to draw this color" : "Click to skip this color")
                    }
                }
            }
            .disabled(controller.isRunning)
        }
    }
}

struct Swatch: View {
    let color: RGB
    let percent: Double
    let skipped: Bool

    var body: some View {
        VStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(nsColor: color.nsColor))
                .frame(height: 28)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                .overlay(skipped ? CrossOut().stroke(Color.red, lineWidth: 2) : nil)
            Text(color.hexNoHash).font(.system(size: 10, design: .monospaced))
            Text(percent < 0.1 ? "<0.1%" : String(format: "%.1f%%", percent))
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
        .opacity(skipped ? 0.45 : 1)
        .contentShape(Rectangle())
    }
}

struct CrossOut: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + 3, y: rect.minY + 3))
        p.addLine(to: CGPoint(x: rect.maxX - 3, y: rect.maxY - 3))
        p.move(to: CGPoint(x: rect.maxX - 3, y: rect.minY + 3))
        p.addLine(to: CGPoint(x: rect.minX + 3, y: rect.maxY - 3))
        return p
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.95)))
            let cols = Int((size.width / s).rounded(.up)), rows = Int((size.height / s).rounded(.up))
            var path = Path()
            for r in 0..<rows {
                for c in 0..<cols where (r + c) % 2 == 1 {
                    path.addRect(CGRect(x: CGFloat(c) * s, y: CGFloat(r) * s, width: s, height: s))
                }
            }
            ctx.fill(path, with: .color(Color(white: 0.82)))
        }
    }
}
