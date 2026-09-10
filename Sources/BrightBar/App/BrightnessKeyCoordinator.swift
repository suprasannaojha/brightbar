import AppKit
import Combine
import CoreGraphics
import Foundation
import os

/// Wires brightness-key taps to the display under the cursor and Accessibility state.
@MainActor
final class BrightnessKeyCoordinator: ObservableObject {
    private static let enabledDefaultsKey = "brightnessKeysEnabled"
    private static let logger = Logger(subsystem: "com.brightbar.app", category: "keys")

    @Published private(set) var brightnessKeysEnabled: Bool
    @Published var needsAccessibilityPermission = false

    private let store: BrightnessStore
    private let tap = MediaKeyTap()
    private var permissionPollTimer: Timer?
    private var permissionPollDeadline: Date?

    init(store: BrightnessStore) {
        self.store = store
        if UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) == nil {
            self.brightnessKeysEnabled = true
        } else {
            self.brightnessKeysEnabled = UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
        }

        tap.shouldHandleBrightnessKey = { [weak self] in
            self?.targetDisplay()
        }
        tap.onBrightnessKey = { [weak self] display, direction, modifiers in
            self?.handleBrightnessKey(display: display, direction: direction, modifiers: modifiers)
        }

        applyEnabledState(promptIfUntrusted: brightnessKeysEnabled)
    }

    func setEnabled(_ enabled: Bool) {
        guard brightnessKeysEnabled != enabled else { return }
        brightnessKeysEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
        applyEnabledState(promptIfUntrusted: enabled)
    }

    /// Re-check trust when the popover opens (no extra prompt).
    func handlePopoverOpened() {
        applyEnabledState(promptIfUntrusted: false)
    }

    func shutdown() {
        stopPolling()
        tap.stop()
    }

    // MARK: - Target display

    /// Cursor screen decides. Built-in → pass through. Clamshell with no resolved
    /// screen → first external.
    func targetDisplay() -> ExternalDisplay? {
        let location = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(location, $0.frame, false) }),
           let id = cgDisplayID(for: screen) {
            return store.displays.first { $0.id == id }
        }

        if !hasBuiltinDisplay() {
            return store.displays.first
        }
        return nil
    }

    private func cgDisplayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[key] as? NSNumber {
            return number.uint32Value
        }
        return screen.deviceDescription[key] as? CGDirectDisplayID
    }

    private func hasBuiltinDisplay() -> Bool {
        NSScreen.screens.contains { screen in
            guard let id = cgDisplayID(for: screen) else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
    }

    // MARK: - Key handling

    private func handleBrightnessKey(
        display: ExternalDisplay,
        direction: MediaKeyTap.Direction,
        modifiers: NSEvent.ModifierFlags
    ) {
        let step = MediaKeyTap.step(for: modifiers)
        let delta = direction == .up ? step : -step
        let current = store.brightness[display.id] ?? 0
        store.setBrightness(current + delta, for: display)
        let value = store.brightness[display.id] ?? current
        BrightnessOSD.showBrightness(on: display.id, value: value)
    }

    // MARK: - Permission / tap lifecycle

    private func applyEnabledState(promptIfUntrusted: Bool) {
        guard brightnessKeysEnabled else {
            stopPolling()
            tap.stop()
            needsAccessibilityPermission = false
            return
        }

        if AccessibilityPermission.isTrusted {
            stopPolling()
            needsAccessibilityPermission = false
            if !tap.start() {
                Self.logger.error("Failed to create brightness key event tap")
                needsAccessibilityPermission = true
            }
            return
        }

        tap.stop()
        needsAccessibilityPermission = true
        if promptIfUntrusted {
            AccessibilityPermission.requestPrompt()
            startPolling()
        }
    }

    private func startPolling() {
        permissionPollDeadline = Date().addingTimeInterval(120)
        permissionPollTimer?.invalidate()
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollPermission()
            }
        }
    }

    private func pollPermission() {
        if AccessibilityPermission.isTrusted {
            stopPolling()
            applyEnabledState(promptIfUntrusted: false)
            return
        }
        if let deadline = permissionPollDeadline, Date() >= deadline {
            stopPolling()
        }
    }

    private func stopPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
        permissionPollDeadline = nil
    }
}
