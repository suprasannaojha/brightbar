import CoreGraphics
import Foundation

/// Bridge to Apple's private `DisplayServices.framework`, which exposes brightness for the
/// built-in panel and Apple/LG "native" displays (Studio Display, Pro Display XDR, UltraFine).
///
/// Everything is resolved lazily with `dlsym`; every call fails gracefully (nil/false) when a
/// symbol is unavailable. Safe to call from any thread.
enum DisplayServicesBridge {
    private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChangeFn = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias BrightnessChangedFn = @convention(c) (CGDirectDisplayID, Int) -> Void

    private static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    }()

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    private static let getBrightness = symbol("DisplayServicesGetBrightness", as: GetBrightnessFn.self)
    private static let setBrightness = symbol("DisplayServicesSetBrightness", as: SetBrightnessFn.self)
    private static let canChangeBrightness = symbol("DisplayServicesCanChangeBrightness", as: CanChangeFn.self)
    private static let brightnessChanged = symbol("DisplayServicesBrightnessChanged", as: BrightnessChangedFn.self)

    static var isAvailable: Bool { getBrightness != nil && setBrightness != nil }

    /// True when macOS itself can drive this display's backlight (built-in or Apple/LG native display).
    static func canControl(_ displayID: CGDirectDisplayID) -> Bool {
        canChangeBrightness?(displayID) ?? false
    }

    /// Brightness 0.0...1.0, or nil when unavailable.
    static func brightness(of displayID: CGDirectDisplayID) -> Float? {
        guard let getBrightness else { return nil }
        var value: Float = 0
        guard getBrightness(displayID, &value) == 0 else { return nil }
        return min(max(value, 0), 1)
    }

    /// Set brightness 0.0...1.0. Returns true on success.
    @discardableResult
    static func setBrightness(_ value: Float, of displayID: CGDirectDisplayID) -> Bool {
        guard let setBrightness else { return false }
        let clamped = min(max(value, 0), 1)
        let ok = setBrightness(displayID, clamped) == 0
        if ok {
            // Lets the system HUD/Control Center pick up the new value.
            brightnessChanged?(displayID, Int(clamped * 65536))
        }
        return ok
    }

    /// The first built-in display that is currently online, if any.
    static func builtinDisplayID() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }
}
