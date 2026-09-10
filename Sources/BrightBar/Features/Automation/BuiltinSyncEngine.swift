import Combine
import Foundation

/// Follows the built-in panel (ambient-light sensor via DisplayServices) and
/// maps that 0...1 value onto each external display in `.syncWithBuiltin` mode.
@MainActor
final class BuiltinSyncEngine {
    /// After a manual tweak on a synced display, ignore ALS updates for this long.
    static let pauseDuration: TimeInterval = 30

    private static let pollInterval: TimeInterval = 0.5
    private static let pollTolerance: TimeInterval = 0.1
    /// Minimum change in the built-in 0...1 reading before we remap.
    private static let builtinDelta: Float = 0.005
    /// Minimum change in the mapped -50...100 level before we write.
    private static let levelDelta: Double = 1
    private static let coalesceInterval: TimeInterval = 0.1

    private weak var target: AutomationTarget?
    private let settings: SettingsStore

    private var pollTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var lastBuiltin: Float?
    private var lastWriteAt: [String: Date] = [:]
    private var pendingPercent: [String: (display: ExternalDisplay, percent: Double)] = [:]
    private var coalesceTimers: [String: Timer] = [:]
    private var pauseUntil: [String: Date] = [:]
    private var resumeTimers: [String: Timer] = [:]
    private var isRunning = false

    init(target: AutomationTarget, settings: SettingsStore) {
        self.target = target
        self.settings = settings
    }

    deinit {
        pollTimer?.invalidate()
        coalesceTimers.values.forEach { $0.invalidate() }
        resumeTimers.values.forEach { $0.invalidate() }
    }

    func start() {
        stop()
        isRunning = true
        guard let target else { return }

        target.displaysDidChange
            .sink { [weak self] in self?.reevaluate() }
            .store(in: &cancellables)

        target.userDidChangeLevel
            .sink { [weak self] display, _ in self?.pauseAfterUserChange(display) }
            .store(in: &cancellables)

        reevaluate()
    }

    func stop() {
        isRunning = false
        cancellables.removeAll()
        invalidateTimer(&pollTimer)
        coalesceTimers.values.forEach { $0.invalidate() }
        coalesceTimers.removeAll()
        resumeTimers.values.forEach { $0.invalidate() }
        resumeTimers.removeAll()
        pendingPercent.removeAll()
    }

    func reevaluate() {
        guard isRunning else { return }
        if shouldPoll {
            startPollingIfNeeded()
            syncNow()
        } else {
            invalidateTimer(&pollTimer)
            lastBuiltin = nil
        }
    }

    /// Remap the current built-in brightness onto every synced display (still respects per-display pauses).
    func syncNow() {
        guard isRunning, let value = readBuiltin() else { return }
        lastBuiltin = value
        // Force a write so a min/max (hardware range) edit still reaches DDC even
        // when the slider-space percent did not change.
        apply(builtin: value, force: true)
    }

    // MARK: - Polling

    private var shouldPoll: Bool {
        guard DisplayServicesBridge.builtinDisplayID() != nil else { return false }
        return hasSyncedDisplay
    }

    private var hasSyncedDisplay: Bool {
        guard let target else { return false }
        return target.displays.contains { isSynced($0) }
    }

    private func isSynced(_ display: ExternalDisplay) -> Bool {
        settings.display(display.persistentKey).brightnessMode == .syncWithBuiltin
    }

    private func startPollingIfNeeded() {
        guard pollTimer == nil else { return }
        automationLogger.info("Built-in sync polling started")
        pollTimer = automationTimer(
            interval: Self.pollInterval,
            tolerance: Self.pollTolerance,
            repeats: true
        ) { [weak self] in
            self?.poll()
        }
    }

    private func poll() {
        guard isRunning else { return }
        if !shouldPoll {
            invalidateTimer(&pollTimer)
            lastBuiltin = nil
            return
        }
        guard let value = readBuiltin() else { return }
        if let last = lastBuiltin, abs(value - last) < Self.builtinDelta {
            return
        }
        lastBuiltin = value
        apply(builtin: value)
    }

    private func readBuiltin() -> Float? {
        guard let id = DisplayServicesBridge.builtinDisplayID() else { return nil }
        return DisplayServicesBridge.brightness(of: id)
    }

    // MARK: - Mapping

    /// Map a built-in 0...1 reading onto slider space (−50...100).
    ///
    /// `x` is the normalised built-in brightness.
    /// `y = x^γ` (`syncCurve`): γ = 1 is linear; γ < 1 lifts dark ALS readings;
    /// γ > 1 keeps the external dimmer until the built-in is quite bright.
    /// `percent = 100y + syncOffset`, then clamped to slider space. Hardware
    /// min/max mapping happens in `BrightnessStore.setLevel` — do not clamp
    /// to `minBrightness`/`maxBrightness` here or the range is applied twice.
    static func mappedPercent(builtin xRaw: Float, settings: DisplaySettings) -> Double {
        let x = min(max(Double(xRaw), 0), 1)
        let gamma = min(max(settings.syncCurve, 0.25), 4)
        let y = pow(x, gamma)
        let offset = min(max(settings.syncOffset, -50), 50)
        let percent = y * 100 + offset
        return min(max(percent, -50), 100)
    }

    private func apply(builtin: Float, force: Bool = false) {
        guard let target else { return }
        let now = Date()
        for display in target.displays where isSynced(display) {
            if let until = pauseUntil[display.persistentKey], until > now {
                continue
            }
            let ds = settings.display(display.persistentKey)
            let percent = Self.mappedPercent(builtin: builtin, settings: ds)
            enqueueWrite(percent, for: display, force: force)
        }
    }

    private func applyOne(_ display: ExternalDisplay) {
        guard isSynced(display), let value = lastBuiltin ?? readBuiltin() else { return }
        let ds = settings.display(display.persistentKey)
        enqueueWrite(Self.mappedPercent(builtin: value, settings: ds), for: display)
    }

    // MARK: - Coalesced writes (≤ 1 per display per 100 ms)

    private func enqueueWrite(_ percent: Double, for display: ExternalDisplay, force: Bool = false) {
        guard let target else { return }
        if !force, let current = target.currentLevel(for: display), abs(current - percent) < Self.levelDelta {
            return
        }
        let key = display.persistentKey
        let now = Date()
        if !force, let last = lastWriteAt[key], now.timeIntervalSince(last) < Self.coalesceInterval {
            pendingPercent[key] = (display, percent)
            if coalesceTimers[key] == nil {
                let wait = max(0.001, Self.coalesceInterval - now.timeIntervalSince(last))
                let timer = automationTimer(interval: wait, tolerance: 0.02, repeats: false) { [weak self] in
                    self?.flushPending(key)
                }
                coalesceTimers[key] = timer
            }
            return
        }
        commit(percent, for: display)
    }

    private func flushPending(_ key: String) {
        coalesceTimers[key]?.invalidate()
        coalesceTimers[key] = nil
        guard let pending = pendingPercent.removeValue(forKey: key) else { return }
        if let current = target?.currentLevel(for: pending.display),
           abs(current - pending.percent) < Self.levelDelta {
            return
        }
        commit(pending.percent, for: pending.display)
    }

    private func commit(_ percent: Double, for display: ExternalDisplay) {
        lastWriteAt[display.persistentKey] = Date()
        automationLogger.debug("sync \(display.name, privacy: .public) → \(percent)")
        target?.setLevel(percent, for: display, source: .sync)
    }

    // MARK: - Manual pause

    private func pauseAfterUserChange(_ display: ExternalDisplay) {
        guard isSynced(display) else { return }
        let key = display.persistentKey
        pauseUntil[key] = Date().addingTimeInterval(Self.pauseDuration)
        resumeTimers[key]?.invalidate()
        automationLogger.info("Sync paused \(Self.pauseDuration, format: .fixed(precision: 0))s on \(display.name, privacy: .public)")
        resumeTimers[key] = automationTimer(
            interval: Self.pauseDuration,
            tolerance: 0.2,
            repeats: false
        ) { [weak self] in
            guard let self else { return }
            self.pauseUntil[key] = nil
            self.resumeTimers[key]?.invalidate()
            self.resumeTimers[key] = nil
            guard let display = self.target?.displays.first(where: { $0.persistentKey == key }) else { return }
            self.applyOne(display)
        }
    }
}
