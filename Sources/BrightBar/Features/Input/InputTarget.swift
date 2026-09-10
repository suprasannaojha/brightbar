import Foundation

/// Abstraction the input layer talks to so it can compile independently of `BrightnessStore`.
/// The integrator should conform the store (or a thin wrapper) to this protocol.
@MainActor
protocol InputTarget: AnyObject {
    var displays: [ExternalDisplay] { get }
    func level(for display: ExternalDisplay) -> Double?          // -50...100
    func setLevel(_ level: Double, for display: ExternalDisplay)
    func adjustAllLevels(by delta: Double)
    func volume(for display: ExternalDisplay) -> Double?
    func adjustVolume(by delta: Double, for display: ExternalDisplay)
    func toggleMute(for display: ExternalDisplay)
    func isMuted(for display: ExternalDisplay) -> Bool?
    func applyPreset(_ preset: Preset)
}
