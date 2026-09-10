import AppKit
import Combine
import Foundation

/// Replays `lastBrightness` / `lastContrast` after sleep and after a monitor is plugged in.
///
/// The integrator must call `recordLevel(_:for:)` from the store on **every**
/// level change (user, sync, schedule, preset, restore, and initial hardware
/// reads). This engine also observes `userDidChangeLevel` as a backstop for
/// slider/key changes. Writes to `SettingsStore` are trailing-debounced 1 s
/// per display.
@MainActor
final class RestoreEngine {
    private weak var target: AutomationTarget?
    private let settings: SettingsStore

    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var wakeTimer: Timer?
    private var reconnectTimers: [String: Timer] = [:]
    private var knownKeys: Set<String> = []
    private var pendingLevels: [String: Double] = [:]
    private var pendingWork: [String: DispatchWorkItem] = [:]
    private var isRunning = false

    private static let wakeDelay: TimeInterval = 2
    private static let reconnectDelay: TimeInterval = 1.5
    private static let persistDelay: TimeInterval = 1

    init(target: AutomationTarget, settings: SettingsStore) {
        self.target = target
        self.settings = settings
    }

    deinit {
        wakeTimer?.invalidate()
        reconnectTimers.values.forEach { $0.invalidate() }
        pendingWork.values.forEach { $0.cancel() }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    func start() {
        stop()
        isRunning = true
        knownKeys = Set(target?.displays.map(\.persistentKey) ?? [])

        target?.displaysDidChange
            .sink { [weak self] in self?.displaysChanged() }
            .store(in: &cancellables)

        target?.userDidChangeLevel
            .sink { [weak self] display, level in
                self?.recordLevel(level, for: display)
            }
            .store(in: &cancellables)

        observeWorkspace(NSWorkspace.didWakeNotification)
        observeWorkspace(NSWorkspace.screensDidWakeNotification)
    }

    func stop() {
        isRunning = false
        cancellables.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        invalidateTimer(&wakeTimer)
        reconnectTimers.values.forEach { $0.invalidate() }
        reconnectTimers.removeAll()
        flushAllPending()
    }

    func reevaluate() {
        // Flags are read at fire time so a settings edit during the delay is honoured.
    }

    /// Persist `display`'s level as `DisplaySettings.lastBrightness`.
    /// Call from the store on every level change; trailing-debounced 1 s.
    func recordLevel(_ level: Double, for display: ExternalDisplay) {
        recordLevel(level, forKey: display.persistentKey)
    }

    // MARK: - Persist

    private func recordLevel(_ level: Double, forKey key: String) {
        pendingLevels[key] = level
        pendingWork[key]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.flush(key)
            }
        }
        pendingWork[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.persistDelay, execute: work)
    }

    private func flush(_ key: String) {
        pendingWork[key]?.cancel()
        pendingWork[key] = nil
        guard let level = pendingLevels.removeValue(forKey: key) else { return }
        settings.updateDisplay(key) { $0.lastBrightness = level }
    }

    private func flushAllPending() {
        let keys = Array(pendingLevels.keys)
        for key in keys {
            flush(key)
        }
    }

    // MARK: - Wake / reconnect

    private func observeWorkspace(_ name: Notification.Name) {
        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleWakeRestore()
            }
        }
        observers.append(token)
    }

    private func scheduleWakeRestore() {
        guard isRunning else { return }
        invalidateTimer(&wakeTimer)
        wakeTimer = automationTimer(interval: Self.wakeDelay, tolerance: 0.2, repeats: false) { [weak self] in
            guard let self else { return }
            invalidateTimer(&self.wakeTimer)
            guard self.settings.settings.restoreOnWake else { return }
            automationLogger.info("Restore on wake")
            self.restoreAllConnected()
        }
    }

    private func displaysChanged() {
        guard isRunning, let target else { return }
        let current = Set(target.displays.map(\.persistentKey))
        let added = current.subtracting(knownKeys)
        knownKeys = current

        for key in added {
            reconnectTimers[key]?.invalidate()
            reconnectTimers[key] = automationTimer(
                interval: Self.reconnectDelay,
                tolerance: 0.2,
                repeats: false
            ) { [weak self] in
                guard let self else { return }
                self.reconnectTimers[key]?.invalidate()
                self.reconnectTimers[key] = nil
                guard self.settings.settings.restoreOnReconnect else { return }
                guard let display = self.target?.displays.first(where: { $0.persistentKey == key }) else { return }
                automationLogger.info("Restore on reconnect \(display.name, privacy: .public)")
                self.restore(display)
            }
        }

        for key in reconnectTimers.keys where !current.contains(key) {
            reconnectTimers[key]?.invalidate()
            reconnectTimers[key] = nil
        }
    }

    private func restoreAllConnected() {
        guard let target else { return }
        for display in target.displays {
            restore(display)
        }
    }

    private func restore(_ display: ExternalDisplay) {
        let ds = settings.display(display.persistentKey)
        if let brightness = ds.lastBrightness {
            target?.setLevel(brightness, for: display, source: .restore)
        }
        if let contrast = ds.lastContrast {
            target?.setContrast(contrast, for: display)
        }
    }
}
