import CoreGraphics
import Foundation

/// An external (non built-in) display that can potentially be controlled over DDC/CI.
struct ExternalDisplay: Identifiable, Hashable {
    /// CoreGraphics display ID. Stable while the display stays connected.
    let id: CGDirectDisplayID
    /// Human readable name, e.g. "DELL U2723QE". Falls back to "Display <id>" when unknown.
    let name: String
}

/// Abstraction over the mechanism used to read/write brightness on external displays.
///
/// Implementations must be safe to call from the main thread; long-running I2C work
/// should be short (single DDC transaction) so UI stays responsive. Callers are
/// expected to debounce slider changes before calling `setBrightness`.
protocol BrightnessController: AnyObject {
    /// Re-scan connected displays. Returns only external displays (built-in excluded).
    func refreshDisplays() -> [ExternalDisplay]

    /// Read current brightness 0...100. Returns nil if the display does not answer DDC.
    func readBrightness(for display: ExternalDisplay) -> Int?

    /// Write brightness 0...100 (clamped). Returns true on success.
    @discardableResult
    func setBrightness(_ value: Int, for display: ExternalDisplay) -> Bool
}
