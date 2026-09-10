import CoreGraphics
import Foundation

// MARK: - Display model

/// Hardware identity of a display, stable across reconnects/reboots (unlike `CGDirectDisplayID`).
struct DisplayIdentity: Hashable, Codable {
    var vendor: UInt32
    var product: UInt32
    var serial: UInt32
    /// EDID alphanumeric serial when the panel reports one.
    var alphanumericSerial: String?

    /// Key used to persist per-display settings.
    var persistentKey: String {
        if let alphanumericSerial, !alphanumericSerial.isEmpty {
            return "\(vendor)-\(product)-\(alphanumericSerial)"
        }
        return "\(vendor)-\(product)-\(serial)"
    }
}

/// How a display can be controlled.
struct DisplayCapabilities: Hashable, Codable {
    /// Display answers DDC/CI over I²C (most third-party monitors).
    var supportsDDC: Bool = false
    /// Display exposes native brightness through Apple's DisplayServices
    /// (Apple Studio Display, Pro Display XDR, LG UltraFine, etc.).
    var supportsNativeBrightness: Bool = false
    /// Display reports audio (volume/mute) over DDC.
    var supportsAudio: Bool = false
    /// Display reports contrast over DDC.
    var supportsContrast: Bool = false

    var canControlBrightness: Bool { supportsDDC || supportsNativeBrightness }
}

/// An external (non built-in) display.
struct ExternalDisplay: Identifiable, Hashable {
    /// CoreGraphics display ID. Stable while the display stays connected.
    let id: CGDirectDisplayID
    /// Human readable name, e.g. "DELL U2723QE". Falls back to "Display <id>" when unknown.
    let name: String
    let identity: DisplayIdentity
    let capabilities: DisplayCapabilities

    var persistentKey: String { identity.persistentKey }
}

// MARK: - VCP

/// MCCS VCP codes used by BrightBar.
enum VCPCode: UInt8, CaseIterable {
    case brightness = 0x10
    case contrast = 0x12
    case inputSource = 0x60
    case volume = 0x62
    case mute = 0x8D
    case powerMode = 0xD6
}

/// Common VCP 0x60 input-source values (MCCS 2.2a). Vendors deviate; treat as best effort.
enum InputSource: UInt16, CaseIterable, Codable, Identifiable {
    case vga1 = 0x01
    case vga2 = 0x02
    case dvi1 = 0x03
    case dvi2 = 0x04
    case compositeVideo1 = 0x05
    case sVideo1 = 0x07
    case displayPort1 = 0x0F
    case displayPort2 = 0x10
    case hdmi1 = 0x11
    case hdmi2 = 0x12
    case usbC1 = 0x19
    case usbC2 = 0x1B
    case thunderbolt = 0x1A

    var id: UInt16 { rawValue }

    var displayName: String {
        switch self {
        case .vga1: return "VGA 1"
        case .vga2: return "VGA 2"
        case .dvi1: return "DVI 1"
        case .dvi2: return "DVI 2"
        case .compositeVideo1: return "Composite"
        case .sVideo1: return "S-Video"
        case .displayPort1: return "DisplayPort 1"
        case .displayPort2: return "DisplayPort 2"
        case .hdmi1: return "HDMI 1"
        case .hdmi2: return "HDMI 2"
        case .usbC1: return "USB-C 1"
        case .usbC2: return "USB-C 2"
        case .thunderbolt: return "Thunderbolt"
        }
    }

    /// The inputs worth showing in a menu by default.
    static var common: [InputSource] {
        [.hdmi1, .hdmi2, .displayPort1, .displayPort2, .usbC1, .usbC2, .thunderbolt, .dvi1, .vga1]
    }
}

/// MCCS VCP 0xD6 power modes.
enum PowerMode: UInt16 {
    case on = 0x01
    case standby = 0x02
    case suspend = 0x03
    case off = 0x04
    /// Hard power off; not all monitors can wake from this over DDC.
    case powerOff = 0x05
}

// MARK: - Controller

/// Abstraction over the mechanism used to control external displays.
///
/// Implementations must be safe to call from any thread and must serialize hardware access
/// internally; each call should be a single short transaction. Callers debounce slider changes.
protocol BrightnessController: AnyObject {
    /// Re-scan connected displays. Returns only external displays (built-in excluded).
    func refreshDisplays() -> [ExternalDisplay]

    /// Read current brightness 0...100. Returns nil if the display does not answer.
    func readBrightness(for display: ExternalDisplay) -> Int?

    /// Write brightness 0...100 (clamped). Returns true on success.
    @discardableResult
    func setBrightness(_ value: Int, for display: ExternalDisplay) -> Bool

    /// Raw VCP read (DDC only). Returns (current, max) in native units, nil on failure.
    func readVCP(_ code: VCPCode, for display: ExternalDisplay) -> (current: UInt16, max: UInt16)?

    /// Raw VCP write (DDC only) in native units. Returns true on success.
    @discardableResult
    func writeVCP(_ code: VCPCode, value: UInt16, for display: ExternalDisplay) -> Bool
}

// MARK: - Convenience API built on raw VCP (shared by every implementation)

extension BrightnessController {
    /// Reads a 0...100 percentage for a VCP code, scaling by the reported max.
    func readPercent(_ code: VCPCode, for display: ExternalDisplay) -> Int? {
        guard let result = readVCP(code, for: display) else { return nil }
        let max = result.max == 0 ? 100 : UInt32(result.max)
        let value = UInt32(min(result.current, UInt16(max)))
        return Int((value * 100 + max / 2) / max)
    }

    /// Writes a 0...100 percentage for a VCP code, scaling by `nativeMax` (default 100).
    @discardableResult
    func writePercent(_ code: VCPCode, percent: Int, nativeMax: UInt16 = 100, for display: ExternalDisplay) -> Bool {
        let clamped = UInt32(min(100, max(0, percent)))
        let max = nativeMax == 0 ? 100 : UInt32(nativeMax)
        let native = UInt16(min(max, (clamped * max + 50) / 100))
        return writeVCP(code, value: native, for: display)
    }

    func readContrast(for display: ExternalDisplay) -> Int? {
        readPercent(.contrast, for: display)
    }

    @discardableResult
    func setContrast(_ percent: Int, for display: ExternalDisplay) -> Bool {
        let nativeMax = readVCP(.contrast, for: display)?.max ?? 100
        return writePercent(.contrast, percent: percent, nativeMax: nativeMax, for: display)
    }

    func readVolume(for display: ExternalDisplay) -> Int? {
        readPercent(.volume, for: display)
    }

    @discardableResult
    func setVolume(_ percent: Int, for display: ExternalDisplay) -> Bool {
        let nativeMax = readVCP(.volume, for: display)?.max ?? 100
        return writePercent(.volume, percent: percent, nativeMax: nativeMax, for: display)
    }

    /// MCCS: 1 = muted, 2 = unmuted.
    func readMute(for display: ExternalDisplay) -> Bool? {
        guard let result = readVCP(.mute, for: display) else { return nil }
        return result.current == 1
    }

    @discardableResult
    func setMute(_ muted: Bool, for display: ExternalDisplay) -> Bool {
        writeVCP(.mute, value: muted ? 1 : 2, for: display)
    }

    func readInputSource(for display: ExternalDisplay) -> UInt16? {
        // Some monitors put the input code in the low byte with junk in the high byte.
        guard let result = readVCP(.inputSource, for: display) else { return nil }
        return result.current & 0xFF
    }

    @discardableResult
    func setInputSource(_ source: UInt16, for display: ExternalDisplay) -> Bool {
        writeVCP(.inputSource, value: source, for: display)
    }

    @discardableResult
    func setPowerMode(_ mode: PowerMode, for display: ExternalDisplay) -> Bool {
        writeVCP(.powerMode, value: mode.rawValue, for: display)
    }
}
