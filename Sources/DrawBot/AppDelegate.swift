import AppKit
import Carbon.HIToolbox
import DrawBotCore
import DrawBotSystem

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var controller: AppController!
    private var startItem: NSMenuItem?
    private var stopItem: NSMenuItem?
    private var selectItem: NSMenuItem?
    private var statusLine: NSMenuItem?
    private var learnItem: NSMenuItem?

    private enum HotKeyID: UInt32 { case showPanel = 1, selectCanvas = 2, proceed = 3, stop = 4 }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = AppController()
        setUpMainMenu()
        setUpStatusItem()
        registerHotKeys()
        // First launch (or missing permission): show the panel so the user sees what to do.
        if !controller.accessibilityTrusted || controller.image == nil && SettingsStore.lastImagePath == nil {
            controller.showControlPanel()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller, controller.isEngineRunning || controller.isRunning else { return .terminateNow }
        // The drawing thread may be holding the (synthetic) mouse button: let it release first.
        controller.prepareForTermination {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop(reason: "Quitting")
        HotKeyCenter.shared.unregisterAll()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.showControlPanel()
        return true
    }

    // MARK: Main menu

    /// A menu-bar (accessory) app shows no main menu, but AppKit still looks key equivalents up
    /// in it whenever a DrawBot window is key: this is what makes ⌘Q quit and gives text fields
    /// ⌘A / ⌘C / ⌘V / ⌘X / ⌘Z.
    private func setUpMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "DrawBot")
        appMenu.addItem(withTitle: "Quit DrawBot", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let img = NSImage(systemSymbolName: "paintbrush.pointed", accessibilityDescription: "DrawBot")
                ?? NSImage(systemSymbolName: "paintbrush", accessibilityDescription: "DrawBot")
            img?.isTemplate = true
            button.image = img
            if img == nil { button.title = "DB" }
            button.toolTip = "DrawBot"
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusLine = status
        menu.addItem(.separator())

        let hotMods: NSEvent.ModifierFlags = [.control, .option, .command]
        menu.addItem(makeItem("Show DrawBot", #selector(showPanel), key: "p", mods: hotMods))
        selectItem = makeItem("Select Canvas…", #selector(selectCanvas), key: "s", mods: hotMods)
        menu.addItem(selectItem!)
        startItem = makeItem("Start", #selector(startOrContinue), key: "\r", mods: hotMods)
        menu.addItem(startItem!)
        stopItem = makeItem("Stop (Esc while drawing)", #selector(stop), key: ".", mods: hotMods)
        menu.addItem(stopItem!)
        menu.addItem(.separator())
        menu.addItem(makeItem("Open Test Canvas", #selector(openTestCanvas)))
        learnItem = makeItem("Learn Colour Picker…", #selector(learnColorPicker))
        menu.addItem(learnItem!)
        menu.addItem(makeItem("Permissions…", #selector(permissions)))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit DrawBot", #selector(quit), key: "q", mods: [.command]))
        item.menu = menu
        statusItem = item
    }

    private func makeItem(_ title: String, _ action: Selector, key: String = "", mods: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.keyEquivalentModifierMask = mods
        mi.target = self
        return mi
    }

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated { updateMenu() }
    }

    private func updateMenu() {
        controller.refreshPermission()
        statusLine?.title = controller.accessibilityTrusted ? controller.phaseDescription : "Needs Accessibility permission"
        switch controller.phase {
        case .awaitingColor, .obstructed: startItem?.title = "Continue"; startItem?.isEnabled = true
        case .paused: startItem?.title = "Resume"; startItem?.isEnabled = true
        case .learning: startItem?.title = "Continue"; startItem?.isEnabled = true
        case .preparing, .countdown, .drawing, .selectingColor: startItem?.title = "Start"; startItem?.isEnabled = false
        default:
            startItem?.title = "Start Drawing"
            startItem?.isEnabled = controller.phase != .selectingCanvas
        }
        stopItem?.isEnabled = controller.isRunning || controller.phase == .selectingCanvas
        selectItem?.isEnabled = !controller.isRunning && controller.phase != .selectingCanvas
        learnItem?.isEnabled = controller.canLearn
    }

    @objc private func showPanel() { controller.showControlPanel() }
    @objc private func selectCanvas() { controller.selectCanvas() }
    @objc private func startOrContinue() { controller.startOrContinue() }
    @objc private func stop() { controller.stop() }
    @objc private func openTestCanvas() { controller.openTestCanvas() }
    @objc private func learnColorPicker() { controller.learnColorPicker() }
    @objc private func permissions() { controller.showPermissions() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Global hotkeys (⌃⌥⌘ + key)

    private func registerHotKeys() {
        let mods: HotKeyCenter.Modifiers = [.control, .option, .command]
        let hk = HotKeyCenter.shared
        var failed: [String] = []
        if !hk.register(id: HotKeyID.showPanel.rawValue, keyCode: UInt32(kVK_ANSI_P), modifiers: mods, handler: { [weak self] in
            self?.controller.showControlPanel()
        }) { failed.append("⌃⌥⌘P") }
        if !hk.register(id: HotKeyID.selectCanvas.rawValue, keyCode: UInt32(kVK_ANSI_S), modifiers: mods, handler: { [weak self] in
            self?.controller.selectCanvas()
        }) { failed.append("⌃⌥⌘S") }
        if !hk.register(id: HotKeyID.proceed.rawValue, keyCode: UInt32(kVK_Return), modifiers: mods, handler: { [weak self] in
            self?.controller.continueFromHotkey()   // only acts when a prompt is waiting
        }) { failed.append("⌃⌥⌘↩") }
        if !hk.register(id: HotKeyID.stop.rawValue, keyCode: UInt32(kVK_ANSI_Period), modifiers: mods, handler: { [weak self] in
            self?.controller.stop()
        }) { failed.append("⌃⌥⌘.") }
        if !failed.isEmpty {
            controller.statusMessage = "Couldn't register hotkey\(failed.count == 1 ? "" : "s") \(failed.joined(separator: ", ")) — another app may be using \(failed.count == 1 ? "it" : "them")."
        }
    }
}
