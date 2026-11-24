import AppKit

// Menu-bar (accessory) app: no Dock icon, and its windows may appear over other apps'
// full-screen spaces. LSUIElement in Info.plist does the same for the bundled app.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
