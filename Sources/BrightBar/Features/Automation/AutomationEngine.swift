import Combine
import Foundation

/// Owns sync, schedule, restore, location, and preset ramps.
///
/// Integrator wiring:
/// 1. Conform `BrightnessStore` to `AutomationTarget` (`setLevel` should call the
///    existing clamped write path; emit `userDidChangeLevel` only for slider/keys).
/// 2. Call `recordLevel(_:for:)` from the store on **every** level change so
///    restore-on-wake / reconnect can replay it.
/// 3. Add `NSLocationUsageDescription` to Info.plist (required for sunrise/sunset
///    via CoreLocation). Package.swift should link `CoreLocation` if auto-link
///    does not pick it up.
@MainActor
final class AutomationEngine: ObservableObject {
    @Published private(set) var nextScheduledEvent: (date: Date, entry: ScheduleEntry)?

    private let settings: SettingsStore
    private let ramp: RampAnimator
    private let presets: PresetApplier
    private let sync: BuiltinSyncEngine
    private let location: LocationProvider
    private let schedule: ScheduleEngine
    private let restore: RestoreEngine

    private var nextEventCancellable: AnyCancellable?
    private var settingsCancellable: AnyCancellable?
    private var lastRelevant: RelevantSnapshot?
    private var isRunning = false

    init(target: AutomationTarget, settings: SettingsStore) {
        self.settings = settings
        let ramp = RampAnimator(target: target)
        let presets = PresetApplier(target: target, ramp: ramp)
        let location = LocationProvider()
        self.ramp = ramp
        self.presets = presets
        self.sync = BuiltinSyncEngine(target: target, settings: settings)
        self.location = location
        self.schedule = ScheduleEngine(
            target: target,
            settings: settings,
            location: location,
            ramp: ramp,
            presets: presets
        )
        self.restore = RestoreEngine(target: target, settings: settings)

        nextEventCancellable = schedule.$nextEvent
            .sink { [weak self] value in
                self?.nextScheduledEvent = value
            }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        applySettings(settings.settings, force: true)

        settingsCancellable = settings.$settings
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] newSettings in
                self?.applySettings(newSettings, force: false)
            }

        location.start(schedule: settings.settings.schedule)
        restore.start()
        sync.start()
        schedule.start()
        automationLogger.info("AutomationEngine started")
    }

    func stop() {
        guard isRunning else {
            ramp.cancelAll()
            return
        }
        isRunning = false
        settingsCancellable = nil
        sync.stop()
        schedule.stop()
        restore.stop()
        location.stop()
        ramp.cancelAll()
        lastRelevant = nil
        automationLogger.info("AutomationEngine stopped")
    }

    /// Persist a level for restore-on-wake / reconnect. The integrator should
    /// call this from `BrightnessStore` on every level change.
    func recordLevel(_ level: Double, for display: ExternalDisplay) {
        restore.recordLevel(level, for: display)
    }

    func applyPreset(_ preset: Preset, ramp seconds: Double = 0) {
        presets.apply(preset, ramp: seconds)
    }

    func syncNow() {
        sync.syncNow()
    }

    // MARK: - Settings

    private struct DisplayAutomationBits: Equatable {
        var brightnessMode: BrightnessMode
        var syncOffset: Double
        var syncCurve: Double
        var minBrightness: Double
        var maxBrightness: Double
    }

    private struct RelevantSnapshot: Equatable {
        var schedule: ScheduleSettings
        var displays: [String: DisplayAutomationBits]
        var restoreOnWake: Bool
        var restoreOnReconnect: Bool
        var presets: [Preset]
    }

    private func applySettings(_ appSettings: AppSettings, force: Bool) {
        let snapshot = RelevantSnapshot(
            schedule: appSettings.schedule,
            displays: appSettings.displays.mapValues { ds in
                DisplayAutomationBits(
                    brightnessMode: ds.brightnessMode,
                    syncOffset: ds.syncOffset,
                    syncCurve: ds.syncCurve,
                    minBrightness: ds.minBrightness,
                    maxBrightness: ds.maxBrightness
                )
            },
            restoreOnWake: appSettings.restoreOnWake,
            restoreOnReconnect: appSettings.restoreOnReconnect,
            presets: appSettings.presets
        )
        if !force, snapshot == lastRelevant { return }
        lastRelevant = snapshot

        location.apply(appSettings.schedule)
        sync.reevaluate()
        schedule.reevaluate()
        restore.reevaluate()
    }
}
