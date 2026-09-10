import Combine
import Foundation
import os

let automationLogger = Logger(subsystem: "com.brightbar.app", category: "automation")

/// Who initiated a brightness write. The store uses this to suppress
/// `userDidChangeLevel` when the write came from automation.
enum LevelChangeSource: Equatable, CustomStringConvertible {
    case user
    case sync
    case schedule
    case preset
    case restore

    var description: String {
        switch self {
        case .user: return "user"
        case .sync: return "sync"
        case .schedule: return "schedule"
        case .preset: return "preset"
        case .restore: return "restore"
        }
    }
}

/// Surface the automation engines drive. The integrator should conform
/// `BrightnessStore` to this (without modifying the engines).
///
/// `setLevel` is the store's existing clamped/debounced write path.
/// `userDidChangeLevel` must fire only for slider/key changes, not for
/// automation writes (`source != .user`).
@MainActor
protocol AutomationTarget: AnyObject {
    var displays: [ExternalDisplay] { get }
    /// Current level per display, -50...100 (negative = software dimming).
    func currentLevel(for display: ExternalDisplay) -> Double?
    /// Set level -50...100 (store clamps, debounces hardware writes).
    func setLevel(_ level: Double, for display: ExternalDisplay, source: LevelChangeSource)
    func setContrast(_ percent: Double, for display: ExternalDisplay)
    /// Publisher that fires when the display list changes (plug/unplug) — e.g. `$displays.map{_ in ()}`.
    var displaysDidChange: AnyPublisher<Void, Never> { get }
    /// Fires when the USER manually changes a level (slider/keys) — NOT when automation sets it.
    var userDidChangeLevel: AnyPublisher<(ExternalDisplay, Double), Never> { get }
}

// MARK: - Run-loop timers

/// Repeating/one-shot timer on the main run loop (`.common` so it still fires while a menu is tracking).
@MainActor
func automationTimer(
    interval: TimeInterval,
    tolerance: TimeInterval,
    repeats: Bool,
    handler: @escaping @MainActor () -> Void
) -> Timer {
    let timer = Timer(timeInterval: interval, repeats: repeats) { _ in
        // Added to the main run loop, so the callback already runs on the main actor.
        MainActor.assumeIsolated {
            handler()
        }
    }
    timer.tolerance = tolerance
    RunLoop.main.add(timer, forMode: .common)
    return timer
}

@MainActor
func automationTimer(
    fireAt date: Date,
    tolerance: TimeInterval,
    handler: @escaping @MainActor () -> Void
) -> Timer {
    let timer = Timer(fire: date, interval: 0, repeats: false) { _ in
        MainActor.assumeIsolated {
            handler()
        }
    }
    timer.tolerance = tolerance
    RunLoop.main.add(timer, forMode: .common)
    return timer
}

func invalidateTimer(_ timer: inout Timer?) {
    timer?.invalidate()
    timer = nil
}
