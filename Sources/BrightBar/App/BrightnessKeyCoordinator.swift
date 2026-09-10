import AppKit
import Combine
import Foundation
import os

/// Wires NX brightness / volume / mute keys to the display under the cursor and Accessibility state.
@MainActor
final class MediaKeyCoordinator: ObservableObject {
    private static let logger = Logger(subsystem: "com.brightbar.app", category: "input")

    @Published private(set) var brightnessKeysEnabled: Bool
    @Published var needsAccessibilityPermission = false

    private let target: any InputTarget
    private let settings: SettingsStore
    private let tap = MediaKeyTap()
    private var permissionPollTimer: Timer?
    private var permissionPollDeadline: Date?
    private var cancellables = Set<AnyCancellable>()
    private var lastKeysWanted = false

    init(target: any InputTarget, settings: SettingsStore) {
        self.target = target
        self.settings = settings
        self.brightnessKeysEnabled = settings.settings.brightnessKeysEnabled
        self.lastKeysWanted = Self.keysWanted(settings.settings)

        tap.shouldHandle = { [weak self] key in
            self?.display(for: key)
        }
        tap.onKey = { [weak self] display, key, modifiers in
            self?.handleMediaKey(display: display, key: key, modifiers: modifiers)
        }

        applyEnabledState(promptIfUntrusted: lastKeysWanted)

        settings.$settings
            .dropFirst()
            .sink { [weak self] newSettings in
                self?.settingsDidChange(newSettings)
            }
            .store(in: &cancellables)
    }

    /// Writes into `SettingsStore`; the `$settings` observer applies the tap / permission flow.
    func setBrightnessKeysEnabled(_ enabled: Bool) {
        guard settings.settings.brightnessKeysEnabled != enabled else { return }
        settings.settings.brightnessKeysEnabled = enabled
    }

    /// Menu-item compatibility wrapper.
    func setEnabled(_ enabled: Bool) {
        setBrightnessKeysEnabled(enabled)
    }

    /// Re-check trust when the popover opens (no extra prompt).
    func handlePopoverOpened() {
        applyEnabledState(promptIfUntrusted: false)
    }

    func shutdown() {
        stopPolling()
        tap.stop()
        cancellables.removeAll()
    }

    // MARK: - Target display

    /// Cursor screen decides. Built-in → pass through. Clamshell with no resolved
    /// screen → first external.
    func targetDisplay() -> ExternalDisplay? {
        InputDisplayLookup.mediaKeyDisplay(from: target.displays)
    }

    // MARK: - Key routing

    private func display(for key: MediaKeyTap.MediaKey) -> ExternalDisplay? {
        switch key {
        case .brightnessUp, .brightnessDown:
            guard settings.settings.brightnessKeysEnabled else { return nil }
            return targetDisplay()
        case .volumeUp, .volumeDown, .mute:
            guard settings.settings.volumeKeysEnabled else { return nil }
            return InputDisplayLookup.mediaKeyVolumeDisplay(from: target.displays)
        }
    }

    private func handleMediaKey(
        display: ExternalDisplay,
        key: MediaKeyTap.MediaKey,
        modifiers: NSEvent.ModifierFlags
    ) {
        switch key {
        case .brightnessUp, .brightnessDown:
            let step = MediaKeyTap.step(for: modifiers)
            let delta = key == .brightnessUp ? step : -step
            let current = target.level(for: display) ?? 0
            target.setLevel(current + delta, for: display)
            if settings.settings.showOSD {
                let value = target.level(for: display) ?? current
                BrightnessOSD.showBrightness(on: display.id, value: value)
            }
        case .volumeUp, .volumeDown:
            let step = MediaKeyTap.step(for: modifiers)
            let delta = key == .volumeUp ? step : -step
            target.adjustVolume(by: delta, for: display)
            showVolumeOSD(on: display)
        case .mute:
            target.toggleMute(for: display)
            showVolumeOSD(on: display)
        }
    }

    private func showVolumeOSD(on display: ExternalDisplay) {
        guard settings.settings.showOSD else { return }
        BrightnessOSD.showVolume(
            on: display.id,
            value: target.volume(for: display) ?? 0,
            muted: target.isMuted(for: display) ?? false
        )
    }

    // MARK: - Permission / tap lifecycle

    private static func keysWanted(_ settings: AppSettings) -> Bool {
        settings.brightnessKeysEnabled || settings.volumeKeysEnabled
    }

    private func settingsDidChange(_ newSettings: AppSettings) {
        brightnessKeysEnabled = newSettings.brightnessKeysEnabled
        let wanted = Self.keysWanted(newSettings)
        guard wanted != lastKeysWanted else { return }
        let becameWanted = wanted && !lastKeysWanted
        lastKeysWanted = wanted
        applyEnabledState(promptIfUntrusted: becameWanted)
    }

    private func applyEnabledState(promptIfUntrusted: Bool) {
        let wanted = Self.keysWanted(settings.settings)
        guard wanted else {
            stopPolling()
            tap.stop()
            needsAccessibilityPermission = false
            return
        }

        if AccessibilityPermission.isTrusted {
            stopPolling()
            needsAccessibilityPermission = false
            if !tap.start() {
                Self.logger.error("Failed to create media key event tap")
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

typealias BrightnessKeyCoordinator = MediaKeyCoordinator
