import AppKit
import Foundation

/// Scroll-wheel brightness adjustments while the pointer is over the menu bar icon.
@MainActor
final class StatusItemScrollMonitor {
    private static let preciseUnitsPerStep: Double = 10
    private static let minApplyInterval: TimeInterval = 1.0 / 20.0

    private let button: NSStatusBarButton
    private let target: any InputTarget
    private let settings: SettingsStore
    private var monitor: Any?
    private var preciseResidual: Double = 0
    private var lastApplyUptime: TimeInterval = 0

    init(button: NSStatusBarButton, target: any InputTarget, settings: SettingsStore) {
        self.button = button
        self.target = target
        self.settings = settings
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handleScroll(event)
        }
    }

    func invalidate() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        preciseResidual = 0
    }

    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard settings.settings.scrollWheelOnMenuBarIcon else { return event }
        guard let window = event.window, window === button.window else { return event }
        let location = button.convert(event.locationInWindow, from: nil)
        guard button.bounds.contains(location) else { return event }

        // Swallow inertial leftovers so a flick on the icon doesn't keep ramping.
        if !event.momentumPhase.isEmpty {
            return nil
        }

        let deltaY = event.scrollingDeltaY
        guard deltaY != 0 else { return nil }

        let step = settings.settings.hotkeys.step
        let applyDelta: Double
        if event.hasPreciseScrollingDeltas {
            preciseResidual += deltaY
            guard abs(preciseResidual) >= Self.preciseUnitsPerStep else { return nil }
            let ticks = (preciseResidual / Self.preciseUnitsPerStep).rounded(.towardZero)
            preciseResidual -= ticks * Self.preciseUnitsPerStep
            applyDelta = ticks * step
        } else {
            // Mouse wheels send ±1–3 lines per click; one step per tick.
            applyDelta = deltaY > 0 ? step : -step
        }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastApplyUptime < Self.minApplyInterval {
            if event.hasPreciseScrollingDeltas, step != 0 {
                preciseResidual += (applyDelta / step) * Self.preciseUnitsPerStep
            }
            return nil
        }
        lastApplyUptime = now

        // Natural scrolling: scrolling up (positive scrollingDeltaY) = brighter.
        target.adjustAllLevels(by: applyDelta)
        if settings.settings.showOSD, let display = target.displays.first {
            let value = target.level(for: display) ?? 0
            BrightnessOSD.showBrightness(on: display.id, value: value)
        }
        return nil
    }
}
