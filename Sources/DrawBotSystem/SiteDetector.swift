import AppKit
import ApplicationServices

/// Works out which website a browser window shows, so Colour Learn can keep a separate colour
/// picker per site (every web paint app in one browser shares the browser's app ID).
///
/// Uses the Accessibility API (DrawBot already needs that permission):
/// 1. the URL of the page (`AXURL` of the window's `AXWebArea`: Safari, Chromium browsers and
///    Firefox-based browsers expose it), reduced to its host, e.g. "paintz.app";
/// 2. failing that, the window title minus the browser's own name, e.g. "PaintZ".
public enum SiteDetector {
    /// Browsers we know (others are recognised when their window contains a web area).
    public static let knownBrowsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "app.zen-browser.zen",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "com.kagi.kagimacOS", "org.torproject.torbrowser",
        "net.waterfox.waterfox", "io.github.zen-browser.zen", "com.sigmaos.sigmaos.macos", "ai.perplexity.comet",
    ]

    public struct Site: Equatable, Sendable {
        /// Stable key part: "paintz.app", or "title:paintz" when only the title was available.
        public let key: String
        /// For display: "paintz.app" or "PaintZ".
        public let name: String
    }

    /// The site shown in `app`'s window that contains `point` (CG global), or nil if it isn't a
    /// browser window (or Accessibility isn't granted).
    public static func site(of app: NSRunningApplication, at point: CGPoint) -> Site? {
        guard Permissions.isAXTrusted else { return nil }
        let isBrowser = app.bundleIdentifier.map { knownBrowsers.contains($0) } ?? false
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        // Chromium and Electron only build their accessibility tree when asked to.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let window = window(of: appElement, containing: point) else { return nil }
        if let url = webAreaURL(in: window), let host = host(fromURL: url) {
            return Site(key: host, name: host)
        }
        guard isBrowser, let title: String = attribute(window, kAXTitleAttribute) else { return nil }
        guard let name = siteName(fromTitle: title, appName: app.localizedName ?? "") else { return nil }
        return Site(key: "title:" + name.lowercased(), name: name)
    }

    // MARK: Pure helpers (unit-tested)

    /// "https://www.paint.sumo.app/x?y" → "paint.sumo.app". Nil for non-web URLs.
    public static func host(fromURL s: String) -> String? {
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// "untitled.png - PaintZ — Zen Browser" → "PaintZ"; "Paint" → "Paint".
    /// Drops the browser's own name, then keeps the last part (sites usually put their name last).
    public static func siteName(fromTitle title: String, appName: String) -> String? {
        let separators = [" — ", " – ", " - ", " | ", " · "]
        var parts = [title]
        for sep in separators { parts = parts.flatMap { $0.components(separatedBy: sep) } }
        parts = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let browserWords = ["zen", "firefox", "chrome", "chromium", "safari", "edge", "brave", "arc", "opera", "vivaldi",
                            "browser", "mozilla", "orion", "waterfox", "private browsing"]
        let app = appName.lowercased()
        while let last = parts.last, parts.count > 1 {
            let l = last.lowercased()
            if (!app.isEmpty && (l == app || l.contains(app))) || browserWords.contains(where: { l.contains($0) }) {
                parts.removeLast()
            } else {
                break
            }
        }
        guard let name = parts.last, !name.isEmpty else { return nil }
        return name
    }

    // MARK: Accessibility plumbing

    private static func attribute<T>(_ e: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success, let v else { return nil }
        return v as? T
    }

    private static func frame(of e: AXUIElement) -> CGRect? {
        guard let pos: AXValue = attribute(e, kAXPositionAttribute), let size: AXValue = attribute(e, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pos, .cgPoint, &p), AXValueGetValue(size, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    private static func window(of app: AXUIElement, containing point: CGPoint) -> AXUIElement? {
        let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute) ?? []
        if let w = windows.first(where: { frame(of: $0)?.contains(point) ?? false }) { return w }
        return attribute(app, kAXFocusedWindowAttribute)
    }

    /// Breadth-first search for the first web area (bounded, so a huge tree can't stall us).
    private static func webAreaURL(in window: AXUIElement) -> String? {
        var queue: [AXUIElement] = [window]
        var visited = 0
        while !queue.isEmpty && visited < 1500 {
            let e = queue.removeFirst()
            visited += 1
            if let role: String = attribute(e, kAXRoleAttribute), role == "AXWebArea" {
                if let url: URL = attribute(e, kAXURLAttribute) { return url.absoluteString }
                if let s: String = attribute(e, kAXURLAttribute) { return s }
                if let s: String = attribute(e, "AXDocument") { return s }
                continue   // don't descend into the page itself
            }
            let children: [AXUIElement] = attribute(e, kAXChildrenAttribute) ?? []
            queue.append(contentsOf: children)
        }
        return nil
    }
}
