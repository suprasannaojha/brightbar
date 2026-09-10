import Foundation

/// Applies a named preset to every connected external display.
@MainActor
final class PresetApplier {
    private weak var target: AutomationTarget?
    private let ramp: RampAnimator

    init(target: AutomationTarget, ramp: RampAnimator) {
        self.target = target
        self.ramp = ramp
    }

    /// Brightness is ramped when `seconds > 0`; contrast (if the preset sets one
    /// and the display supports it) is applied immediately.
    func apply(_ preset: Preset, ramp seconds: Double = 0) {
        guard let target else { return }
        automationLogger.info("Applying preset \(preset.name, privacy: .public) ramp=\(seconds, format: .fixed(precision: 1))s")
        for display in target.displays {
            if seconds > 0 {
                ramp.animate(display, to: preset.brightness, duration: seconds, source: .preset)
            } else {
                target.setLevel(preset.brightness, for: display, source: .preset)
            }
            if let contrast = preset.contrast, display.capabilities.supportsContrast {
                target.setContrast(contrast, for: display)
            }
        }
    }
}
