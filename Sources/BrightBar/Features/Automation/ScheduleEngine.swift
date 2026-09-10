import AppKit
import Combine
import Foundation

/// Fires scheduled brightness/preset changes, including sunrise/sunset offsets.
@MainActor
final class ScheduleEngine {
    @Published private(set) var nextEvent: (date: Date, entry: ScheduleEntry)?

    private weak var target: AutomationTarget?
    private let settings: SettingsStore
    private let location: LocationProvider
    private let ramp: RampAnimator
    private let presets: PresetApplier

    private var fireTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var isRunning = false
    /// Slack so a just-fired event is not selected as "next" again.
    private static let futureSlack: TimeInterval = 0.25

    init(
        target: AutomationTarget,
        settings: SettingsStore,
        location: LocationProvider,
        ramp: RampAnimator,
        presets: PresetApplier
    ) {
        self.target = target
        self.settings = settings
        self.location = location
        self.ramp = ramp
        self.presets = presets
    }

    deinit {
        fireTimer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    func start() {
        stop()
        isRunning = true

        location.$coordinate
            .dropFirst()
            .sink { [weak self] _ in self?.reschedule(catchUp: false) }
            .store(in: &cancellables)

        observe(NSWorkspace.didWakeNotification, workspace: true) { [weak self] in
            self?.reschedule(catchUp: true)
        }
        observe(.NSSystemClockDidChange, workspace: false) { [weak self] in
            self?.reschedule(catchUp: true)
        }
        observe(.NSCalendarDayChanged, workspace: false) { [weak self] in
            self?.reschedule(catchUp: false)
        }

        reschedule(catchUp: true)
    }

    func stop() {
        isRunning = false
        cancellables.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        invalidateTimer(&fireTimer)
        nextEvent = nil
    }

    func reevaluate() {
        guard isRunning else { return }
        reschedule(catchUp: false)
    }

    // MARK: - Schedule

    private func reschedule(catchUp: Bool) {
        guard isRunning else { return }
        invalidateTimer(&fireTimer)

        let schedule = settings.settings.schedule
        guard schedule.enabled else {
            nextEvent = nil
            return
        }

        let now = Date()
        if catchUp {
            applyCatchUp(now: now, schedule: schedule)
        }

        let fires = upcomingFires(now: now, schedule: schedule)
        guard let next = fires.min(by: { $0.date < $1.date }) else {
            nextEvent = nil
            return
        }
        nextEvent = (next.date, next.entry)
        automationLogger.info("Next schedule event at \(next.date.timeIntervalSince(now), format: .fixed(precision: 0))s")

        fireTimer = automationTimer(fireAt: next.date, tolerance: 1) { [weak self] in
            self?.timerFired(expected: next)
        }
    }

    private func timerFired(expected: Fire) {
        guard isRunning else { return }
        let schedule = settings.settings.schedule
        guard schedule.enabled else { return }

        // Apply every entry that shares this fire time (within 1 s).
        let sameTime = fires(for: expected.date, schedule: schedule, daysFromToday: [0, 1])
            .filter { abs($0.date.timeIntervalSince(expected.date)) < 1 }
        if sameTime.isEmpty {
            apply(expected.entry, duration: schedule.rampDurationSeconds)
        } else {
            for fire in sameTime.sorted(by: { $0.order < $1.order }) {
                apply(fire.entry, duration: schedule.rampDurationSeconds)
            }
        }
        automationLogger.info("Schedule fired \(expected.entry.id.uuidString, privacy: .public)")
        reschedule(catchUp: false)
    }

    /// Instantly apply the latest of today's triggers whose fire time is already past.
    private func applyCatchUp(now: Date, schedule: ScheduleSettings) {
        let calendar = Calendar.current
        let todayFires = fires(for: now, schedule: schedule, daysFromToday: [0])
            .filter { $0.date <= now }
        guard let latest = todayFires.max(by: {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.order < $1.order
        }) else { return }

        // Only catch up if the fire belongs to today's civil date *as a trigger*
        // (sunrise+offset may land before midnight; we still count it).
        guard calendar.isDate(latest.referenceDay, inSameDayAs: now) else { return }
        automationLogger.info("Schedule catch-up \(latest.entry.id.uuidString, privacy: .public)")
        apply(latest.entry, duration: 0)
    }

    private func apply(_ entry: ScheduleEntry, duration: TimeInterval) {
        if let id = entry.presetID, let preset = settings.preset(id) {
            presets.apply(preset, ramp: duration)
            return
        }
        guard let brightness = entry.brightness, let target else {
            automationLogger.error("Schedule entry \(entry.id.uuidString, privacy: .public) has no preset or brightness")
            return
        }
        let source: LevelChangeSource = .schedule
        for display in target.displays {
            if duration > 0 {
                ramp.animate(display, to: brightness, duration: duration, source: source)
            } else {
                target.setLevel(brightness, for: display, source: source)
            }
        }
    }

    // MARK: - Fire times

    private struct Fire {
        var date: Date
        var entry: ScheduleEntry
        var referenceDay: Date
        var order: Int
    }

    private func upcomingFires(now: Date, schedule: ScheduleSettings) -> [Fire] {
        fires(for: now, schedule: schedule, daysFromToday: [0, 1])
            .filter { $0.date > now + Self.futureSlack }
    }

    private func fires(for now: Date, schedule: ScheduleSettings, daysFromToday: [Int]) -> [Fire] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let coordinate = location.resolvedCoordinate(from: schedule)
        var result: [Fire] = []

        for (order, entry) in schedule.entries.enumerated() where entry.enabled {
            for dayOffset in daysFromToday {
                guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
                if let date = fireDate(for: entry, on: day, coordinate: coordinate, calendar: calendar) {
                    result.append(Fire(date: date, entry: entry, referenceDay: day, order: order))
                }
            }
        }
        return result
    }

    private func fireDate(
        for entry: ScheduleEntry,
        on day: Date,
        coordinate: (lat: Double, lon: Double)?,
        calendar: Calendar
    ) -> Date? {
        switch entry.trigger {
        case .time(let hour, let minute):
            guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)

        case .sunrise(let offsetMinutes):
            guard let coordinate else {
                markMissingCoordinate()
                return nil
            }
            guard let times = SunCalculator.sunTimes(
                for: day,
                latitude: coordinate.lat,
                longitude: coordinate.lon
            ) else { return nil }
            return times.sunrise.addingTimeInterval(Double(offsetMinutes) * 60)

        case .sunset(let offsetMinutes):
            guard let coordinate else {
                markMissingCoordinate()
                return nil
            }
            guard let times = SunCalculator.sunTimes(
                for: day,
                latitude: coordinate.lat,
                longitude: coordinate.lon
            ) else { return nil }
            return times.sunset.addingTimeInterval(Double(offsetMinutes) * 60)
        }
    }

    private func markMissingCoordinate() {
        if location.lastError == nil {
            location.lastError = "No coordinates available; sunrise/sunset entries are skipped."
        }
    }

    private func observe(_ name: Notification.Name, workspace: Bool, handler: @escaping @MainActor () -> Void) {
        let center: NotificationCenter = workspace ? NSWorkspace.shared.notificationCenter : .default
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            Task { @MainActor in
                handler()
            }
        }
        observers.append(token)
    }
}
