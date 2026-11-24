import AppKit
import ApplicationServices

public enum AppActivator {
    /// Brings `app` to the front (yielding activation first on macOS 14+), polling until it is the
    /// frontmost application or `timeout` elapses. Completion on main thread: true if frontmost.
    /// Must be called on the main thread; never blocks it.
    ///
    /// Strategy: macOS 14+ → `NSApp.yieldActivation(to:)` + `app.activate(from: .current)`
    /// (falling back to `app.activate()`); macOS 13 → `activate(options: .activateIgnoringOtherApps)`.
    /// If the app still isn't frontmost after 300 ms (cooperative activation can refuse requests
    /// from an inactive accessory app), we ask again and, when Accessibility is granted, set the
    /// app's AX "frontmost" attribute, which works regardless of who is active and also switches
    /// to the app's full-screen Space. Completion is always asynchronous, exactly once.
    public static func activate(_ app: NSRunningApplication, timeout: TimeInterval = 1.5, completion: @escaping (Bool) -> Void) {
        let pid = app.processIdentifier
        if app.isTerminated {
            DispatchQueue.main.async { completion(false) }
            return
        }
        if frontmostPID == pid {
            DispatchQueue.main.async { completion(true) }
            return
        }
        requestActivation(app)
        poll(app: app, pid: pid, start: ProcessInfo.processInfo.systemUptime, timeout: max(0, timeout),
             fallbackDone: false, completion: completion)
    }

    /// True when the reliable fallback (setting the app's AX "frontmost" attribute) is available.
    /// It needs FULL Accessibility trust (`Permissions.isAXTrusted`); with only event-posting
    /// access (`CGPreflightPostEventAccess`) activation relies on cooperative activation alone,
    /// which macOS 14+ may refuse for an inactive accessory app. The UI may surface this.
    public static var canForceActivation: Bool { Permissions.isAXTrusted }

    public static var frontmostPID: pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    // MARK: Private

    private static let pollInterval: TimeInterval = 0.05
    private static let fallbackAfter: TimeInterval = 0.3

    private static func poll(app: NSRunningApplication, pid: pid_t, start: TimeInterval, timeout: TimeInterval,
                             fallbackDone: Bool, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
            if frontmostPID == pid {
                completion(true)
                return
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            if app.isTerminated || elapsed >= timeout {
                completion(false)
                return
            }
            var fallbackDone = fallbackDone
            if !fallbackDone && elapsed >= fallbackAfter {
                fallbackDone = true
                requestActivation(app)
                activateViaAccessibility(pid: pid)
            }
            poll(app: app, pid: pid, start: start, timeout: timeout, fallbackDone: fallbackDone, completion: completion)
        }
    }

    private static func requestActivation(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            NSApp?.yieldActivation(to: app)
            if !app.activate(from: NSRunningApplication.current, options: []) {
                _ = app.activate(options: [])
            }
        } else {
            _ = app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    private static func activateViaAccessibility(pid: pid_t) {
        guard canForceActivation else { return }
        let element = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }
}
