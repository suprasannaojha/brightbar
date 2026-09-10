import AppKit
import Carbon
import Combine
import Foundation
import os

/// Global Carbon hotkeys. Does not require Accessibility permission.
@MainActor
final class HotkeyManager: ObservableObject {
    private static let logger = Logger(subsystem: "com.brightbar.app", category: "input")
    /// Four-char code `'BBar'`.
    private static let signature: OSType = 0x42426172

    @Published var failedBindings: [String] = []

    private let target: any InputTarget
    private let settings: SettingsStore
    private var cancellables = Set<AnyCancellable>()
    private var eventHandler: EventHandlerRef?
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: Action] = [:]
    private var lastSnapshot: HotkeySnapshot?
    private var isRunning = false

    init(target: any InputTarget, settings: SettingsStore) {
        self.target = target
        self.settings = settings
    }

    func start() {
        isRunning = true
        guard installHandlerIfNeeded() else { return }
        reregister(force: true)
        observeSettingsIfNeeded()
    }

    func stop() {
        isRunning = false
        cancellables.removeAll()
        lastSnapshot = nil
        unregisterAll()
        if let eventHandler {
            let status = RemoveEventHandler(eventHandler)
            Self.logger.info("RemoveEventHandler OSStatus=\(status)")
            self.eventHandler = nil
        }
    }

    // MARK: - Carbon handler

    private func installHandlerIfNeeded() -> Bool {
        if eventHandler != nil { return true }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var ref: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyCarbonHandler,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &ref
        )
        Self.logger.info("InstallEventHandler OSStatus=\(status)")
        guard status == noErr else {
            failedBindings = ["Event handler"]
            return false
        }
        eventHandler = ref
        return true
    }

    fileprivate func handleHotKeyEvent(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr else {
            Self.logger.error("GetEventParameter OSStatus=\(status)")
            return status
        }
        performAction(for: hotKeyID.id)
        return noErr
    }

    // MARK: - Registration

    private func observeSettingsIfNeeded() {
        guard cancellables.isEmpty else { return }
        settings.$settings
            .dropFirst()
            .sink { [weak self] newSettings in
                self?.settingsChanged(newSettings)
            }
            .store(in: &cancellables)
    }

    private func settingsChanged(_ newSettings: AppSettings) {
        guard isRunning else { return }
        let snapshot = HotkeySnapshot(newSettings)
        guard snapshot != lastSnapshot else { return }
        reregister(force: false)
    }

    private func reregister(force: Bool) {
        let snapshot = HotkeySnapshot(settings.settings)
        if !force, snapshot == lastSnapshot { return }
        lastSnapshot = snapshot
        unregisterAll()
        registerAll(from: settings.settings)
    }

    private func unregisterAll() {
        for (id, ref) in hotKeyRefs {
            let status = UnregisterEventHotKey(ref)
            Self.logger.info("UnregisterEventHotKey id=\(id) OSStatus=\(status)")
        }
        hotKeyRefs.removeAll()
        actions.removeAll()
        failedBindings = []
    }

    private func registerAll(from appSettings: AppSettings) {
        let bindings = appSettings.hotkeys
        register(bindings.brightnessUp, id: BuiltinID.brightnessUp.rawValue, name: "Brightness Up", action: .brightnessUp)
        register(bindings.brightnessDown, id: BuiltinID.brightnessDown.rawValue, name: "Brightness Down", action: .brightnessDown)
        register(bindings.allBrightnessUp, id: BuiltinID.allBrightnessUp.rawValue, name: "All Brightness Up", action: .allBrightnessUp)
        register(bindings.allBrightnessDown, id: BuiltinID.allBrightnessDown.rawValue, name: "All Brightness Down", action: .allBrightnessDown)
        register(bindings.volumeUp, id: BuiltinID.volumeUp.rawValue, name: "Volume Up", action: .volumeUp)
        register(bindings.volumeDown, id: BuiltinID.volumeDown.rawValue, name: "Volume Down", action: .volumeDown)
        register(bindings.toggleMute, id: BuiltinID.toggleMute.rawValue, name: "Toggle Mute", action: .toggleMute)

        var nextPresetID: UInt32 = BuiltinID.presetBase.rawValue
        for preset in appSettings.presets {
            guard let hotkey = preset.hotkey else { continue }
            register(hotkey, id: nextPresetID, name: "Preset: \(preset.name)", action: .preset(preset.id))
            nextPresetID += 1
        }
    }

    private func register(_ hotkey: Hotkey?, id: UInt32, name: String, action: Action) {
        guard let hotkey else { return }

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        Self.logger.info("RegisterEventHotKey \(name, privacy: .public) OSStatus=\(status)")
        if status == noErr, let ref {
            hotKeyRefs[id] = ref
            actions[id] = action
        } else {
            failedBindings.append(name)
            Self.logger.error("Hotkey registration failed for \(name, privacy: .public) OSStatus=\(status)")
        }
    }

    // MARK: - Actions

    private func performAction(for id: UInt32) {
        guard let action = actions[id] else { return }
        let step = settings.settings.hotkeys.step
        switch action {
        case .brightnessUp:
            adjustCursorBrightness(by: step)
        case .brightnessDown:
            adjustCursorBrightness(by: -step)
        case .allBrightnessUp:
            target.adjustAllLevels(by: step)
            showBrightnessOSD(on: target.displays.first)
        case .allBrightnessDown:
            target.adjustAllLevels(by: -step)
            showBrightnessOSD(on: target.displays.first)
        case .volumeUp:
            adjustVolume(by: step)
        case .volumeDown:
            adjustVolume(by: -step)
        case .toggleMute:
            toggleMute()
        case .preset(let presetID):
            if let preset = settings.settings.presets.first(where: { $0.id == presetID }) {
                target.applyPreset(preset)
                showBrightnessOSD(on: target.displays.first)
            }
        }
    }

    private func adjustCursorBrightness(by delta: Double) {
        guard let display = InputDisplayLookup.hotkeyDisplay(from: target.displays) else { return }
        let current = target.level(for: display) ?? 0
        target.setLevel(current + delta, for: display)
        showBrightnessOSD(on: display)
    }

    private func adjustVolume(by delta: Double) {
        guard let display = InputDisplayLookup.volumeHotkeyDisplay(from: target.displays) else { return }
        target.adjustVolume(by: delta, for: display)
        showVolumeOSD(on: display)
    }

    private func toggleMute() {
        guard let display = InputDisplayLookup.volumeHotkeyDisplay(from: target.displays) else { return }
        target.toggleMute(for: display)
        showVolumeOSD(on: display)
    }

    private func showBrightnessOSD(on display: ExternalDisplay?) {
        guard settings.settings.showOSD, let display else { return }
        let value = target.level(for: display) ?? 0
        BrightnessOSD.showBrightness(on: display.id, value: value)
    }

    private func showVolumeOSD(on display: ExternalDisplay) {
        guard settings.settings.showOSD else { return }
        BrightnessOSD.showVolume(
            on: display.id,
            value: target.volume(for: display) ?? 0,
            muted: target.isMuted(for: display) ?? false
        )
    }

    private enum BuiltinID: UInt32 {
        case brightnessUp = 1
        case brightnessDown = 2
        case allBrightnessUp = 3
        case allBrightnessDown = 4
        case volumeUp = 5
        case volumeDown = 6
        case toggleMute = 7
        case presetBase = 100
    }

    private enum Action: Equatable {
        case brightnessUp
        case brightnessDown
        case allBrightnessUp
        case allBrightnessDown
        case volumeUp
        case volumeDown
        case toggleMute
        case preset(UUID)
    }

    private struct HotkeySnapshot: Equatable {
        var brightnessUp: Hotkey?
        var brightnessDown: Hotkey?
        var allBrightnessUp: Hotkey?
        var allBrightnessDown: Hotkey?
        var volumeUp: Hotkey?
        var volumeDown: Hotkey?
        var toggleMute: Hotkey?
        var presets: [(UUID, Hotkey)]

        init(_ settings: AppSettings) {
            brightnessUp = settings.hotkeys.brightnessUp
            brightnessDown = settings.hotkeys.brightnessDown
            allBrightnessUp = settings.hotkeys.allBrightnessUp
            allBrightnessDown = settings.hotkeys.allBrightnessDown
            volumeUp = settings.hotkeys.volumeUp
            volumeDown = settings.hotkeys.volumeDown
            toggleMute = settings.hotkeys.toggleMute
            presets = settings.presets.compactMap { preset in
                guard let hotkey = preset.hotkey else { return nil }
                return (preset.id, hotkey)
            }
        }

        static func == (lhs: HotkeySnapshot, rhs: HotkeySnapshot) -> Bool {
            lhs.brightnessUp == rhs.brightnessUp
                && lhs.brightnessDown == rhs.brightnessDown
                && lhs.allBrightnessUp == rhs.allBrightnessUp
                && lhs.allBrightnessDown == rhs.allBrightnessDown
                && lhs.volumeUp == rhs.volumeUp
                && lhs.volumeDown == rhs.volumeDown
                && lhs.toggleMute == rhs.toggleMute
                && lhs.presets.elementsEqual(rhs.presets, by: { $0.0 == $1.0 && $0.1 == $1.1 })
        }
    }
}

/// C callback. Carbon delivers this on the application event target (main thread).
private func hotkeyCarbonHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    _ = nextHandler
    guard let event, let userData else {
        return OSStatus(eventNotHandledErr)
    }
    return MainActor.assumeIsolated {
        Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            .handleHotKeyEvent(event)
    }
}
