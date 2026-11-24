import AppKit
import CoreGraphics

public struct OnScreenWindow: Sendable, Equatable {
    public let windowID: CGWindowID
    public let pid: pid_t
    public let ownerName: String
    /// CG global coordinates.
    public let bounds: CGRect
    public let layer: Int
    public let alpha: Double
    public init(windowID: CGWindowID, pid: pid_t, ownerName: String, bounds: CGRect, layer: Int, alpha: Double) {
        self.windowID = windowID; self.pid = pid; self.ownerName = ownerName
        self.bounds = bounds; self.layer = layer; self.alpha = alpha
    }
}

/// Uses CGWindowListCopyWindowInfo (bounds/pid/layer need no Screen Recording permission).
///
/// Filtering (everything here): windows with alpha < 0.05, layer >= 24 (`NSWindow.Level.mainMenu`:
/// menu bar, status items, cursor, screen-saver overlays…), width or height < 4 pt, windows
/// owned by "Window Server", and the Dock's transparent full-display window (layer 20, covers
/// every screen, would otherwise be "front-most" everywhere) are ignored. Window titles are never
/// read (they'd need Screen Recording permission).
public enum WindowInspector {
    /// On-screen windows front-to-back containing `point` (CG global), excluding this process,
    /// windows with alpha < 0.05, and system chrome at layer >= 24 (menu bar, Dock, cursor…).
    public static func windows(at point: CGPoint) -> [OnScreenWindow] {
        let own = ProcessInfo.processInfo.processIdentifier
        return onScreenWindows().filter { $0.pid != own && $0.bounds.contains(point) }
    }

    /// The front-most such window at `point`, or nil.
    public static func topWindow(at point: CGPoint) -> OnScreenWindow? {
        windows(at: point).first
    }

    /// The app that owns the front-most window at the centre of `canvas` (the app being drawn in).
    ///
    /// Normal-level windows (layer 0: document windows, full-screen apps) win over floating ones,
    /// so another app's transient overlay at the centre (a notification banner, a floating
    /// utility, the Dock) is not mistaken for the drawing app; if no normal window is there, the
    /// front-most eligible window counts.
    ///
    /// DrawBot's own NORMAL-level windows (layer 0, e.g. the Test Canvas) count here, so this
    /// returns `NSRunningApplication.current` when the canvas is on the Test Canvas. DrawBot's
    /// floating panels / overlays (layer != 0) and click-through windows are looked through.
    public static func targetApp(for canvas: CGRect) -> NSRunningApplication? {
        let own = ProcessInfo.processInfo.processIdentifier
        guard let candidate = targetWindow(in: onScreenWindows(), canvas: canvas, ownPID: own,
                                           ownClickThrough: ownClickThroughWindowIDs() ?? [])
        else { return nil }
        if candidate.pid == own { return NSRunningApplication.current }
        return NSRunningApplication(processIdentifier: candidate.pid)
    }

    /// Windows that are front-most at any of a 7×7 grid of sample points inset 2 pt inside
    /// `canvas` — i.e. things (colour pickers, palettes, popups) that would catch the drawing
    /// clicks: windows of other apps, and the target app's own FLOATING windows (layer != 0) where
    /// they lie over one of its normal (layer 0) windows. De-duplicated by windowID. Empty means
    /// the canvas is clear.
    ///
    /// DrawBot's own windows DO count as obstructions (they'd catch the clicks too), except
    /// click-through ones (`ignoresMouseEvents`, e.g. the HUD) and except when `targetPID` is
    /// DrawBot itself. Own windows can only be inspected on the main thread; called from another
    /// thread, own windows are ignored.
    public static func obstructions(of canvas: CGRect, targetPID: pid_t) -> [OnScreenWindow] {
        let all = onScreenWindows()
        let own = ProcessInfo.processInfo.processIdentifier
        let clickThrough = ownClickThroughWindowIDs()
        let considered = all.filter { w in
            guard w.pid == own, w.pid != targetPID else { return true }
            guard let clickThrough else { return false } // off main thread: ignore own windows
            return !clickThrough.contains(w.windowID)
        }
        return obstructions(in: considered, canvas: canvas, targetPID: targetPID)
    }

    /// All eligible on-screen windows, front-to-back, INCLUDING this process's own windows
    /// (same filtering as above, minus the own-process exclusion).
    public static func onScreenWindows() -> [OnScreenWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return filterEligible(parse(info), displays: activeDisplayBounds())
    }

    // MARK: - Internal (pure, unit-tested)

    static let systemChromeLayer = 24 // kCGMainMenuWindowLevel / NSWindow.Level.mainMenu
    static let dockLayer = 20 // kCGDockWindowLevel

    static func parse(_ info: [[String: Any]]) -> [OnScreenWindow] {
        info.compactMap { d -> OnScreenWindow? in
            guard let number = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let boundsDict = d[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            let layer = (d[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let alpha = (d[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            let owner = d[kCGWindowOwnerName as String] as? String ?? ""
            return OnScreenWindow(windowID: number, pid: pid, ownerName: owner,
                                  bounds: bounds.standardized, layer: layer, alpha: alpha)
        }
    }

    static func filterEligible(_ windows: [OnScreenWindow], displays: [CGRect]) -> [OnScreenWindow] {
        windows.filter { w in
            if w.alpha < 0.05 { return false }
            if w.layer >= systemChromeLayer { return false }
            if w.bounds.width < 4 || w.bounds.height < 4 { return false }
            if w.ownerName == "Window Server" { return false }
            if w.ownerName == "Dock", coversADisplay(w.bounds, displays: displays) { return false }
            return true
        }
    }

    static func coversADisplay(_ r: CGRect, displays: [CGRect]) -> Bool {
        displays.contains { d in r.contains(d.insetBy(dx: 1, dy: 1)) }
    }

    /// 7×7 sample points inset 2 pt inside `canvas` (fewer distinct points for tiny canvases).
    static func samplePoints(in canvas: CGRect) -> [CGPoint] {
        let r = canvas.standardized
        let inset = r.insetBy(dx: min(2, r.width / 2), dy: min(2, r.height / 2))
        var pts: [CGPoint] = []
        for j in 0..<7 {
            for i in 0..<7 {
                pts.append(CGPoint(x: inset.minX + inset.width * CGFloat(i) / 6,
                                   y: inset.minY + inset.height * CGFloat(j) / 6))
            }
        }
        return pts
    }

    /// `windows` must already be eligible and front-to-back. See `targetApp(for:)`.
    static func targetWindow(in windows: [OnScreenWindow], canvas: CGRect, ownPID: pid_t,
                             ownClickThrough: Set<CGWindowID>) -> OnScreenWindow? {
        let c = CGPoint(x: canvas.midX, y: canvas.midY)
        let candidates = windows.filter { w in
            guard w.bounds.contains(c) else { return false }
            if w.pid == ownPID { return w.layer == 0 && !ownClickThrough.contains(w.windowID) }
            return true
        }
        return candidates.first { $0.layer == 0 } ?? candidates.first
    }

    /// `windows` must already be eligible and front-to-back.
    static func obstructions(in windows: [OnScreenWindow], canvas: CGRect, targetPID: pid_t) -> [OnScreenWindow] {
        var seen = Set<CGWindowID>()
        var result: [OnScreenWindow] = []
        for p in samplePoints(in: canvas) {
            guard let i = windows.firstIndex(where: { $0.bounds.contains(p) }) else { continue }
            let top = windows[i]
            if top.pid == targetPID {
                // The target's own floating window (palette, colour picker, popover) over one of
                // its normal windows catches the clicks too. The target's own windows are fine
                // otherwise (e.g. when the canvas itself is on a floating window).
                guard top.layer != 0,
                      windows[(i + 1)...].contains(where: { $0.pid == targetPID && $0.layer == 0 && $0.bounds.contains(p) })
                else { continue }
            }
            if seen.insert(top.windowID).inserted { result.append(top) }
        }
        return result
    }

    // MARK: - Private

    private static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    /// Window numbers of this process's click-through windows; nil off the main thread.
    private static func ownClickThroughWindowIDs() -> Set<CGWindowID>? {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated {
            Set(NSApplication.shared.windows
                .filter { $0.ignoresMouseEvents && $0.windowNumber > 0 }
                .map { CGWindowID($0.windowNumber) })
        }
    }
}
