import AppKit
import ApplicationServices
import CoreGraphics

/// Permission helpers.
///
/// What actually gates `CGEvent.post(tap: .cghidEventTap)`: since macOS 10.15 the TCC service
/// "PostEvent", which System Settings shows under Privacy & Security → **Accessibility**. Granting
/// the app Accessibility covers it, and `CGPreflightPostEventAccess()` checks it directly. Without
/// it, posting does NOT fail. The events are silently dropped. So the process counts as trusted
/// when EITHER `AXIsProcessTrusted()` (full Accessibility) OR `CGPreflightPostEventAccess()` (event
/// synthesis only) is true. Both calls are cheap, never prompt, and are safe on any thread.
public enum Permissions {
    /// True when this process may post synthetic input events (Accessibility / "Privacy & Security
    /// → Accessibility"). Never prompts.
    public static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted() || CGPreflightPostEventAccess()
    }

    /// True only when full Accessibility (AX API) access is granted. Never prompts.
    /// (AppActivator's AX fallback needs this; posting events only needs `isAccessibilityTrusted`.)
    public static var isAXTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that adds DrawBot to the Accessibility list (no-op if trusted).
    public static func requestAccessibility() {
        guard !isAccessibilityTrusted else { return }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        // Shows the "would like to control this computer using accessibility features" alert and
        // adds the app (switched off) to the Accessibility list. We deliberately do not also call
        // CGRequestPostEventAccess(): it would show a second, near-identical alert.
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Opens System Settings → Privacy & Security → Accessibility.
    public static func openAccessibilitySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }
}
