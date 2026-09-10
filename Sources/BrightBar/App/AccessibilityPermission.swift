import ApplicationServices
import AppKit
import Foundation

enum AccessibilityPermission {
    private static var hasRequestedPrompt = false

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system Accessibility prompt at most once per process.
    static func requestPrompt() {
        guard !hasRequestedPrompt else { return }
        hasRequestedPrompt = true
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
