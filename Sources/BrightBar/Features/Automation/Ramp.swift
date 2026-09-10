import Foundation

/// Smoothly interpolates a display's level over a duration at ~10 steps/s.
@MainActor
final class RampAnimator {
    private static let stepsPerSecond: Double = 10

    private weak var target: AutomationTarget?
    private var timers: [String: Timer] = [:]

    init(target: AutomationTarget) {
        self.target = target
    }

    deinit {
        timers.values.forEach { $0.invalidate() }
    }

    /// Linear blend in BrightBar level space (-50...100), not in cd/m².
    /// A new ramp for the same display cancels the previous one.
    func animate(
        _ display: ExternalDisplay,
        to level: Double,
        duration: TimeInterval,
        source: LevelChangeSource
    ) {
        cancel(display)
        guard let target else { return }
        let start = target.currentLevel(for: display) ?? 0
        if duration <= 0 || abs(level - start) < 0.5 {
            target.setLevel(level, for: display, source: source)
            return
        }

        let totalSteps = max(1, Int((duration * Self.stepsPerSecond).rounded()))
        let stepInterval = duration / Double(totalSteps)
        let key = display.persistentKey
        var step = 0

        let timer = automationTimer(
            interval: stepInterval,
            tolerance: min(0.05, stepInterval * 0.25),
            repeats: true
        ) { [weak self] in
            guard let self else { return }
            step += 1
            let t = min(1, Double(step) / Double(totalSteps))
            // Linear interpolation: value = start + (end − start) · t
            let value = start + (level - start) * t
            if let live = self.target?.displays.first(where: { $0.persistentKey == key }) {
                self.target?.setLevel(value, for: live, source: source)
            } else {
                self.target?.setLevel(value, for: display, source: source)
            }
            if step >= totalSteps {
                self.cancel(display)
            }
        }
        timers[key] = timer
    }

    func cancel(_ display: ExternalDisplay) {
        let key = display.persistentKey
        timers[key]?.invalidate()
        timers[key] = nil
    }

    func cancelAll() {
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()
    }
}
