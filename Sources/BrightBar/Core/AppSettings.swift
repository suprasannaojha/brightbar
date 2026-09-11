import Combine
import Foundation

// MARK: - Value types

/// A global keyboard shortcut (Carbon key code + Carbon modifier mask).
struct Hotkey: Codable, Equatable, Hashable {
    var keyCode: UInt32
    /// Carbon modifiers: cmdKey (0x100), shiftKey (0x200), optionKey (0x800), controlKey (0x1000).
    var carbonModifiers: UInt32
}

enum BrightnessMode: String, Codable, CaseIterable, Identifiable {
    /// Slider / keys only.
    case manual
    /// Follow the built-in display (ambient-light sensor drives it), through offset + curve.
    case syncWithBuiltin

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .manual: return "Manual"
        case .syncWithBuiltin: return "Sync with built-in display"
        }
    }
}

/// Per-monitor settings, keyed by `DisplayIdentity.persistentKey`.
struct DisplaySettings: Codable, Equatable {
    var friendlyName: String?
    var brightnessMode: BrightnessMode = .manual
    /// Added to the mapped built-in value, in percent (-50...50).
    var syncOffset: Double = 0
    /// Exponent applied to the normalized built-in value (0.25...4). 1 = linear.
    var syncCurve: Double = 1
    /// Usable hardware range; slider maps 0...100 onto this. minBrightness < maxBrightness.
    var minBrightness: Double = 0
    var maxBrightness: Double = 100
    /// Skip DDC and dim purely with the gamma table (for monitors that lie about DDC).
    var forceSoftwareDimming: Bool = false
    var showContrast: Bool = false
    var showVolume: Bool = false

    // Last known state, restored on reconnect / wake.
    var lastBrightness: Double?
    var lastContrast: Double?
    var lastVolume: Double?
    var lastInputSource: UInt16?

    init() {}
}

struct Preset: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    /// -50...100 (negative = software dimming), applied to all displays.
    var brightness: Double
    /// 0...100, nil = leave unchanged.
    var contrast: Double?
    var hotkey: Hotkey?
}

enum ScheduleTrigger: Codable, Equatable {
    /// Fixed local time.
    case time(hour: Int, minute: Int)
    /// Relative to sunrise, in minutes (negative = before).
    case sunrise(offsetMinutes: Int)
    /// Relative to sunset, in minutes.
    case sunset(offsetMinutes: Int)
}

struct ScheduleEntry: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var enabled: Bool = true
    var trigger: ScheduleTrigger
    /// Either apply a preset...
    var presetID: UUID?
    /// ...or a plain brightness value (-50...100). `presetID` wins when both are set.
    var brightness: Double?
}

struct ScheduleSettings: Codable, Equatable {
    var enabled: Bool = false
    /// Use CoreLocation for sunrise/sunset. When false, `latitude`/`longitude` are used.
    var useLocation: Bool = true
    var latitude: Double?
    var longitude: Double?
    /// Transition duration in seconds (0 = instant).
    var rampDurationSeconds: Double = 120
    var entries: [ScheduleEntry] = []
}

struct HotkeyBindings: Codable, Equatable {
    /// Cursor-display brightness.
    var brightnessUp: Hotkey?
    var brightnessDown: Hotkey?
    /// All displays at once.
    var allBrightnessUp: Hotkey?
    var allBrightnessDown: Hotkey?
    var volumeUp: Hotkey?
    var volumeDown: Hotkey?
    var toggleMute: Hotkey?
    /// Step for hotkeys and scroll wheel, percent.
    var step: Double = 5
}

// MARK: - Root model

struct AppSettings: Equatable {
    // Keys & input
    var brightnessKeysEnabled: Bool = true
    var volumeKeysEnabled: Bool = true
    var scrollWheelOnMenuBarIcon: Bool = true
    var hotkeys: HotkeyBindings = HotkeyBindings()

    // Menu bar / UI
    var iconReflectsBrightness: Bool = true
    var showPercentInMenuBar: Bool = false
    var showOSD: Bool = true
    var hideIconWhenNoDisplays: Bool = true

    // Behaviour
    var restoreOnWake: Bool = true
    var restoreOnReconnect: Bool = true

    // Automation
    var presets: [Preset] = AppSettings.defaultPresets
    var schedule: ScheduleSettings = ScheduleSettings()

    // Per display
    var displays: [String: DisplaySettings] = [:]

    static let defaultPresets: [Preset] = [
        Preset(name: "Day", brightness: 80, contrast: nil, hotkey: nil),
        Preset(name: "Evening", brightness: 40, contrast: nil, hotkey: nil),
        Preset(name: "Night", brightness: -20, contrast: nil, hotkey: nil),
    ]
}

extension AppSettings: Codable {
    enum CodingKeys: String, CodingKey {
        case brightnessKeysEnabled
        case volumeKeysEnabled
        case scrollWheelOnMenuBarIcon
        case hotkeys
        case iconReflectsBrightness
        case showPercentInMenuBar
        case showOSD
        case hideIconWhenNoDisplays
        case restoreOnWake
        case restoreOnReconnect
        case presets
        case schedule
        case displays
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        brightnessKeysEnabled = try container.decodeIfPresent(Bool.self, forKey: .brightnessKeysEnabled) ?? true
        volumeKeysEnabled = try container.decodeIfPresent(Bool.self, forKey: .volumeKeysEnabled) ?? true
        scrollWheelOnMenuBarIcon = try container.decodeIfPresent(Bool.self, forKey: .scrollWheelOnMenuBarIcon) ?? true
        hotkeys = try container.decodeIfPresent(HotkeyBindings.self, forKey: .hotkeys) ?? HotkeyBindings()
        iconReflectsBrightness = try container.decodeIfPresent(Bool.self, forKey: .iconReflectsBrightness) ?? true
        showPercentInMenuBar = try container.decodeIfPresent(Bool.self, forKey: .showPercentInMenuBar) ?? false
        showOSD = try container.decodeIfPresent(Bool.self, forKey: .showOSD) ?? true
        hideIconWhenNoDisplays = try container.decodeIfPresent(Bool.self, forKey: .hideIconWhenNoDisplays) ?? true
        restoreOnWake = try container.decodeIfPresent(Bool.self, forKey: .restoreOnWake) ?? true
        restoreOnReconnect = try container.decodeIfPresent(Bool.self, forKey: .restoreOnReconnect) ?? true
        presets = try container.decodeIfPresent([Preset].self, forKey: .presets) ?? AppSettings.defaultPresets
        schedule = try container.decodeIfPresent(ScheduleSettings.self, forKey: .schedule) ?? ScheduleSettings()
        displays = try container.decodeIfPresent([String: DisplaySettings].self, forKey: .displays) ?? [:]
    }
}

// MARK: - Store

/// Single source of truth for user settings, persisted as JSON in UserDefaults.
///
/// Main-actor only. Writes are coalesced (250 ms) so slider-driven edits don't hammer defaults.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    static let defaultsKey = "com.brightbar.settings.v1"

    @Published var settings: AppSettings {
        didSet { scheduleSave() }
    }

    private let defaults: UserDefaults
    private var saveWorkItem: DispatchWorkItem?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
            // Migrate the pre-settings flag used by the first release.
            if defaults.object(forKey: "brightnessKeysEnabled") != nil {
                settings.brightnessKeysEnabled = defaults.bool(forKey: "brightnessKeysEnabled")
            }
        }
    }

    /// Settings for a display; returns defaults when none are stored yet.
    func display(_ key: String) -> DisplaySettings {
        settings.displays[key] ?? DisplaySettings()
    }

    /// Mutate a display's settings in place (creating them on first use).
    func updateDisplay(_ key: String, _ mutate: (inout DisplaySettings) -> Void) {
        var value = settings.displays[key] ?? DisplaySettings()
        let before = value
        mutate(&value)
        if before == value, settings.displays[key] != nil { return }
        settings.displays[key] = value
    }

    func preset(_ id: UUID) -> Preset? {
        settings.presets.first { $0.id == id }
    }

    func saveNow() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        persist()
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in self?.persist() }
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
