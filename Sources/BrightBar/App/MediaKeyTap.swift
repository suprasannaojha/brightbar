import AppKit
import CoreGraphics

/// Session event tap for the keyboard brightness keys (`NX_SYSDEFINED`).
///
/// Installed on the main run loop. The C callback is therefore already on the
/// main actor; keep the handler fast (no I/O). Hardware DDC writes are
/// debounced off-thread by `BrightnessStore`.
@MainActor
final class MediaKeyTap {
    /// macOS brightness has 16 ticks; `100 / 16 = 6.25`. The store is integer, so 6.
    static let standardStep: Double = 6
    /// Shift+Option: 1% steps, matching the system brightness-key convention.
    static let fineStep: Double = 1

    enum Direction {
        case up
        case down
    }

    var shouldHandleBrightnessKey: () -> ExternalDisplay? = { nil }
    var onBrightnessKey: (ExternalDisplay, Direction, NSEvent.ModifierFlags) -> Void = { _, _, _ in }

    private var port: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var isRunning: Bool {
        guard let port else { return false }
        return CGEvent.tapIsEnabled(tap: port)
    }

    static func step(for modifiers: NSEvent.ModifierFlags) -> Double {
        if modifiers.contains(.shift), modifiers.contains(.option) {
            return fineStep
        }
        return standardStep
    }

    /// Returns `false` if the tap could not be created (typically missing Accessibility).
    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        stop()

        let mask = CGEventMask(1 << 14 /* NX_SYSDEFINED */)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mediaKeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        port = tap
        runLoopSource = source
        return true
    }

    func stop() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(port)
        self.port = nil
        self.runLoopSource = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.type == .systemDefined,
              nsEvent.subtype.rawValue == 8 // NX_SUBTYPE_AUX_CONTROL_BUTTONS
        else {
            return Unmanaged.passUnretained(event)
        }

        let data1 = nsEvent.data1
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyFlags = data1 & 0xFFFF
        let keyDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
        let isRepeat = (keyFlags & 0x1) == 1

        let direction: Direction
        switch keyCode {
        case 2: // NX_KEYTYPE_BRIGHTNESS_UP
            direction = .up
        case 3: // NX_KEYTYPE_BRIGHTNESS_DOWN
            direction = .down
        default:
            return Unmanaged.passUnretained(event)
        }

        guard let display = shouldHandleBrightnessKey() else {
            return Unmanaged.passUnretained(event)
        }

        // Repeats arrive as extra key-down events (`isRepeat`). Swallow up and down
        // so macOS does not also change the built-in panel.
        if keyDown || isRepeat {
            onBrightnessKey(display, direction, nsEvent.modifierFlags)
        }
        return nil
    }
}

/// C callback. The tap is added to the main run loop, so this is on the main actor.
private func mediaKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    _ = proxy
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    return MainActor.assumeIsolated {
        Unmanaged<MediaKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
            .handle(type: type, event: event)
    }
}
