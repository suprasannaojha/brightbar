import AppKit
import Combine
import CoreGraphics
import Darwin
import Foundation

/// `BrightnessController` is not Sendable (defined in Core). Hardware access is
/// serialized onto background queues by this store; the box only exists to satisfy
/// the compiler when hopping off the main actor.
private final class ControllerHandle: @unchecked Sendable {
    let controller: BrightnessController
    init(_ controller: BrightnessController) {
        self.controller = controller
    }
}

@MainActor
final class BrightnessStore: ObservableObject {
    static let minimumLevel: Double = -50
    static let maximumLevel: Double = 100

    @Published var displays: [ExternalDisplay] = []
    /// Per-display level in `minimumLevel...maximumLevel`. Values `>= 0` are DDC
    /// brightness; values `< 0` keep hardware at 0 and apply software dimming.
    @Published var brightness: [CGDirectDisplayID: Double] = [:]
    @Published var contrast: [CGDirectDisplayID: Double] = [:]
    @Published var volume: [CGDirectDisplayID: Double] = [:]
    @Published var muted: [CGDirectDisplayID: Bool] = [:]
    @Published var inputSource: [CGDirectDisplayID: UInt16] = [:]
    @Published var unsupported: Set<CGDirectDisplayID> = []
    @Published var isRefreshing = false

    weak var automation: AutomationEngine?

    let settings: SettingsStore

    private let controllerHandle: ControllerHandle
    private let dimmer = SoftwareDimmer()
    private let hardwareQueue = DispatchQueue(label: "com.brightbar.hardware", qos: .userInitiated)
    private let userDidChangeLevelSubject = PassthroughSubject<(ExternalDisplay, Double), Never>()
    private var pendingWrites: [CGDirectDisplayID: DispatchWorkItem] = [:]
    private var pendingContrastWrites: [CGDirectDisplayID: DispatchWorkItem] = [:]
    private var pendingVolumeWrites: [CGDirectDisplayID: DispatchWorkItem] = [:]
    private var hardwareTarget: [CGDirectDisplayID: Int] = [:]
    private var lastSoftwareLevel: [CGDirectDisplayID: Double] = [:]
    private var persistWorkItems: [String: DispatchWorkItem] = [:]
    private var displayChangeWorkItem: DispatchWorkItem?
    private var wakeRefreshWorkItem: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var refreshGeneration = 0
    private var shouldReapplySoftwareDim = false

    init(controller: BrightnessController, settings: SettingsStore) {
        self.controllerHandle = ControllerHandle(controller)
        self.settings = settings

        // IDs from CoreGraphics are unstable for about a second after plug/unplug.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleRefreshAfterDisplayChange()
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleWakeRefresh()
            }
        }

        refresh()
    }

    deinit {
        pendingWrites.values.forEach { $0.cancel() }
        pendingContrastWrites.values.forEach { $0.cancel() }
        pendingVolumeWrites.values.forEach { $0.cancel() }
        persistWorkItems.values.forEach { $0.cancel() }
        displayChangeWorkItem?.cancel()
        wakeRefreshWorkItem?.cancel()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func shutdown() {
        pendingWrites.values.forEach { $0.cancel() }
        pendingWrites.removeAll()
        pendingContrastWrites.values.forEach { $0.cancel() }
        pendingContrastWrites.removeAll()
        pendingVolumeWrites.values.forEach { $0.cancel() }
        pendingVolumeWrites.removeAll()
        wakeRefreshWorkItem?.cancel()
        wakeRefreshWorkItem = nil
        flushPersistedAuxiliaryState()
        dimmer.clearAll()
    }

    func isSoftwareOnly(_ display: ExternalDisplay) -> Bool {
        unsupported.contains(display.id) || settings.display(display.persistentKey).forceSoftwareDimming
    }

    func refresh() {
        isRefreshing = true
        refreshGeneration += 1
        let generation = refreshGeneration
        let previousBrightness = brightness
        let previousContrast = contrast
        let previousVolume = volume
        let previousMuted = muted
        let previousInput = inputSource
        let previousIDs = Set(displays.map(\.id))
        let handle = controllerHandle
        let displaySettings = settings.settings.displays

        DispatchQueue.global(qos: .userInitiated).async {
            let controller = handle.controller
            let displays = controller.refreshDisplays()
            var nextBrightness: [CGDirectDisplayID: Double] = [:]
            var nextContrast: [CGDirectDisplayID: Double] = [:]
            var nextVolume: [CGDirectDisplayID: Double] = [:]
            var nextMuted: [CGDirectDisplayID: Bool] = [:]
            var nextInput: [CGDirectDisplayID: UInt16] = [:]
            var unsupported: Set<CGDirectDisplayID> = []

            for display in displays {
                let ds = displaySettings[display.persistentKey] ?? DisplaySettings()
                let previous = previousBrightness[display.id]

                if ds.forceSoftwareDimming {
                    unsupported.insert(display.id)
                    if let previous, previous < 0 {
                        nextBrightness[display.id] = previous
                    } else {
                        nextBrightness[display.id] = 0
                    }
                } else if let value = controller.readBrightness(for: display) {
                    let slider = sliderLevel(fromHardware: Double(value), settings: ds)
                    if let previous, previous < 0, slider <= 0.5 {
                        nextBrightness[display.id] = previous
                    } else {
                        nextBrightness[display.id] = slider
                    }
                } else {
                    unsupported.insert(display.id)
                    if let previous, previous < 0 {
                        nextBrightness[display.id] = previous
                    } else {
                        nextBrightness[display.id] = 0
                    }
                }

                if display.capabilities.supportsContrast {
                    usleep(20_000)
                    if let value = controller.readContrast(for: display) {
                        nextContrast[display.id] = Double(value)
                    }
                }
                if display.capabilities.supportsAudio {
                    usleep(20_000)
                    if let value = controller.readVolume(for: display) {
                        nextVolume[display.id] = Double(value)
                    }
                    usleep(20_000)
                    if let value = controller.readMute(for: display) {
                        nextMuted[display.id] = value
                    }
                }
                if display.capabilities.supportsDDC {
                    usleep(20_000)
                    if let value = controller.readInputSource(for: display) {
                        nextInput[display.id] = value
                    }
                }
            }

            Task { @MainActor [weak self] in
                guard let self, generation == self.refreshGeneration else { return }

                let liveIDs = Set(displays.map(\.id))
                let staleIDs = previousIDs.union(self.lastSoftwareLevel.keys).subtracting(liveIDs)
                for id in staleIDs {
                    self.pendingWrites[id]?.cancel()
                    self.pendingWrites.removeValue(forKey: id)
                    self.pendingContrastWrites[id]?.cancel()
                    self.pendingContrastWrites.removeValue(forKey: id)
                    self.pendingVolumeWrites[id]?.cancel()
                    self.pendingVolumeWrites.removeValue(forKey: id)
                    self.hardwareTarget.removeValue(forKey: id)
                    self.lastSoftwareLevel.removeValue(forKey: id)
                    self.dimmer.clear(for: id)
                }

                var brightness = nextBrightness
                for (id, work) in self.pendingWrites where !work.isCancelled {
                    if let pending = self.brightness[id] {
                        brightness[id] = pending
                    }
                }
                var contrast = nextContrast
                for (id, work) in self.pendingContrastWrites where !work.isCancelled {
                    if let pending = self.contrast[id] {
                        contrast[id] = pending
                    }
                }
                var volume = nextVolume
                for (id, work) in self.pendingVolumeWrites where !work.isCancelled {
                    if let pending = self.volume[id] {
                        volume[id] = pending
                    }
                }
                var muted = nextMuted
                var input = nextInput
                for display in displays {
                    if contrast[display.id] == nil, let previous = previousContrast[display.id] {
                        contrast[display.id] = previous
                    }
                    if volume[display.id] == nil, let previous = previousVolume[display.id] {
                        volume[display.id] = previous
                    }
                    if muted[display.id] == nil, let previous = previousMuted[display.id] {
                        muted[display.id] = previous
                    }
                    if input[display.id] == nil, let previous = previousInput[display.id] {
                        input[display.id] = previous
                    }
                }

                self.displays = displays
                self.brightness = brightness
                self.contrast = contrast
                self.volume = volume
                self.muted = muted
                self.inputSource = input
                self.unsupported = unsupported
                self.reconcileSoftwareDimming(reapply: self.shouldReapplySoftwareDim)
                self.shouldReapplySoftwareDim = false
                self.isRefreshing = false

                for display in displays {
                    if let level = brightness[display.id] {
                        self.automation?.recordLevel(level, for: display)
                    }
                    self.schedulePersistAuxiliary(for: display)
                }
            }
        }
    }

    func setBrightness(_ value: Double, for display: ExternalDisplay) {
        setLevel(value, for: display, source: .user)
    }

    func setLevel(_ level: Double, for display: ExternalDisplay, source: LevelChangeSource) {
        let softwareOnly = isSoftwareOnly(display)
        let upper = softwareOnly ? 0 : Self.maximumLevel
        let clamped = min(max(level, Self.minimumLevel), upper)
        brightness[display.id] = clamped
        applySoftwareDimmingIfNeeded(clamped, for: display.id)
        automation?.recordLevel(clamped, for: display)
        if source == .user {
            userDidChangeLevelSubject.send((display, clamped))
        }

        if softwareOnly { return }

        let ds = settings.display(display.persistentKey)
        let hardwareValue = hardwarePercent(forLevel: clamped, settings: ds)
        if hardwareTarget[display.id] == hardwareValue, clamped <= 0 {
            return
        }

        hardwareTarget[display.id] = hardwareValue
        pendingWrites[display.id]?.cancel()

        let handle = controllerHandle
        let displayID = display.id
        var work: DispatchWorkItem!
        work = DispatchWorkItem {
            handle.controller.setBrightness(hardwareValue, for: display)
            Task { @MainActor [weak self] in
                guard let self, self.pendingWrites[displayID] === work else { return }
                self.pendingWrites.removeValue(forKey: displayID)
            }
        }
        pendingWrites[display.id] = work
        hardwareQueue.asyncAfter(deadline: .now() + 0.07, execute: work)
    }

    func setAll(_ value: Double) {
        for display in displays {
            setLevel(value, for: display, source: .user)
        }
    }

    func adjustAll(by delta: Double) {
        for display in displays {
            let current = brightness[display.id] ?? 0
            setLevel(current + delta, for: display, source: .user)
        }
    }

    func setContrast(_ percent: Double, for display: ExternalDisplay) {
        let clamped = min(max(percent, 0), 100)
        contrast[display.id] = clamped
        schedulePersistAuxiliary(for: display)

        guard display.capabilities.supportsContrast else { return }

        pendingContrastWrites[display.id]?.cancel()
        let handle = controllerHandle
        let displayID = display.id
        let hardwareValue = Int(clamped.rounded())
        var work: DispatchWorkItem!
        work = DispatchWorkItem {
            handle.controller.setContrast(hardwareValue, for: display)
            Task { @MainActor [weak self] in
                guard let self, self.pendingContrastWrites[displayID] === work else { return }
                self.pendingContrastWrites.removeValue(forKey: displayID)
            }
        }
        pendingContrastWrites[display.id] = work
        hardwareQueue.asyncAfter(deadline: .now() + 0.07, execute: work)
    }

    func setVolume(_ percent: Double, for display: ExternalDisplay) {
        let clamped = min(max(percent, 0), 100)
        volume[display.id] = clamped
        schedulePersistAuxiliary(for: display)

        guard display.capabilities.supportsAudio else { return }

        pendingVolumeWrites[display.id]?.cancel()
        let handle = controllerHandle
        let displayID = display.id
        let hardwareValue = Int(clamped.rounded())
        var work: DispatchWorkItem!
        work = DispatchWorkItem {
            handle.controller.setVolume(hardwareValue, for: display)
            Task { @MainActor [weak self] in
                guard let self, self.pendingVolumeWrites[displayID] === work else { return }
                self.pendingVolumeWrites.removeValue(forKey: displayID)
            }
        }
        pendingVolumeWrites[display.id] = work
        hardwareQueue.asyncAfter(deadline: .now() + 0.07, execute: work)
    }

    func adjustVolume(by delta: Double, for display: ExternalDisplay) {
        let current = volume[display.id] ?? 0
        setVolume(current + delta, for: display)
    }

    func toggleMute(for display: ExternalDisplay) {
        if let current = muted[display.id] {
            setMuted(!current, for: display)
            return
        }

        let handle = controllerHandle
        hardwareQueue.async {
            let current = handle.controller.readMute(for: display) ?? false
            let next = !current
            _ = handle.controller.setMute(next, for: display)
            Task { @MainActor [weak self] in
                self?.muted[display.id] = next
            }
        }
    }

    func setMuted(_ isMuted: Bool, for display: ExternalDisplay) {
        muted[display.id] = isMuted
        guard display.capabilities.supportsAudio else { return }
        let handle = controllerHandle
        hardwareQueue.async {
            _ = handle.controller.setMute(isMuted, for: display)
        }
    }

    func setInputSource(_ source: UInt16, for display: ExternalDisplay) {
        inputSource[display.id] = source
        schedulePersistAuxiliary(for: display)
        guard display.capabilities.supportsDDC else { return }
        let handle = controllerHandle
        hardwareQueue.async {
            _ = handle.controller.setInputSource(source, for: display)
        }
    }

    func setPower(_ mode: PowerMode, for display: ExternalDisplay) {
        let handle = controllerHandle
        hardwareQueue.async {
            _ = handle.controller.setPowerMode(mode, for: display)
        }
    }

    func applyPreset(_ preset: Preset) {
        if let automation {
            automation.applyPreset(preset)
            return
        }
        for display in displays {
            setLevel(preset.brightness, for: display, source: .preset)
            if let contrast = preset.contrast {
                setContrast(contrast, for: display)
            }
        }
    }

    // MARK: - Software dimming

    private func softwareLevel(for value: Double) -> Double {
        value < 0 ? min(1.0, -value / -Self.minimumLevel) : 0
    }

    private func applySoftwareDimmingIfNeeded(_ value: Double, for displayID: CGDirectDisplayID) {
        let level = softwareLevel(for: value)
        let previous = lastSoftwareLevel[displayID] ?? 0
        guard abs(level - previous) > 0.005 else { return }
        lastSoftwareLevel[displayID] = level
        dimmer.setLevel(level, for: displayID)
    }

    private func reconcileSoftwareDimming(reapply: Bool) {
        for display in displays {
            let id = display.id
            let value = brightness[id] ?? 0
            let ds = settings.display(display.persistentKey)
            if value < 0 {
                lastSoftwareLevel[id] = softwareLevel(for: value)
                hardwareTarget[id] = hardwarePercent(forLevel: 0, settings: ds)
            } else {
                if (lastSoftwareLevel[id] ?? 0) > 0.005 {
                    dimmer.clear(for: id)
                }
                lastSoftwareLevel[id] = 0
                if pendingWrites[id] == nil {
                    hardwareTarget[id] = hardwarePercent(forLevel: value, settings: ds)
                }
            }
        }

        if reapply {
            dimmer.reapplyAll()
        }
    }

    private func scheduleRefreshAfterDisplayChange() {
        displayChangeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.shouldReapplySoftwareDim = true
                self?.refresh()
            }
        }
        displayChangeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func scheduleWakeRefresh() {
        wakeRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        wakeRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func schedulePersistAuxiliary(for display: ExternalDisplay) {
        let key = display.persistentKey
        persistWorkItems[key]?.cancel()
        let contrastValue = contrast[display.id]
        let volumeValue = volume[display.id]
        let inputValue = inputSource[display.id]
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.settings.updateDisplay(key) { row in
                    if let contrastValue { row.lastContrast = contrastValue }
                    if let volumeValue { row.lastVolume = volumeValue }
                    if let inputValue { row.lastInputSource = inputValue }
                }
                self.persistWorkItems[key] = nil
            }
        }
        persistWorkItems[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func flushPersistedAuxiliaryState() {
        persistWorkItems.values.forEach { $0.cancel() }
        persistWorkItems.removeAll()
        for display in displays {
            settings.updateDisplay(display.persistentKey) { row in
                if let value = contrast[display.id] { row.lastContrast = value }
                if let value = volume[display.id] { row.lastVolume = value }
                if let value = inputSource[display.id] { row.lastInputSource = value }
            }
        }
    }
}

// MARK: - InputTarget

extension BrightnessStore: InputTarget {
    func level(for display: ExternalDisplay) -> Double? {
        brightness[display.id]
    }

    func setLevel(_ level: Double, for display: ExternalDisplay) {
        setLevel(level, for: display, source: .user)
    }

    func adjustAllLevels(by delta: Double) {
        adjustAll(by: delta)
    }

    func volume(for display: ExternalDisplay) -> Double? {
        volume[display.id]
    }

    func isMuted(for display: ExternalDisplay) -> Bool? {
        muted[display.id]
    }
}

// MARK: - AutomationTarget

extension BrightnessStore: AutomationTarget {
    func currentLevel(for display: ExternalDisplay) -> Double? {
        brightness[display.id]
    }

    var displaysDidChange: AnyPublisher<Void, Never> {
        $displays.map { _ in () }.eraseToAnyPublisher()
    }

    var userDidChangeLevel: AnyPublisher<(ExternalDisplay, Double), Never> {
        userDidChangeLevelSubject.eraseToAnyPublisher()
    }
}

/// Maps slider level 0...100 onto the display's usable hardware range.
private func hardwarePercent(forLevel level: Double, settings ds: DisplaySettings) -> Int {
    let positive = min(max(level, 0), 100)
    let minB = ds.minBrightness
    let maxB = max(ds.maxBrightness, minB)
    let mapped = minB + (positive / 100.0) * (maxB - minB)
    return Int(min(100, max(0, mapped)).rounded())
}

/// Inverse of `hardwarePercent` so the slider stays in 0...100.
private func sliderLevel(fromHardware percent: Double, settings ds: DisplaySettings) -> Double {
    let minB = ds.minBrightness
    let maxB = max(ds.maxBrightness, minB)
    let span = maxB - minB
    if span < 0.5 {
        return percent >= maxB ? 100 : 0
    }
    let mapped = (percent - minB) / span * 100
    return min(100, max(0, mapped))
}

