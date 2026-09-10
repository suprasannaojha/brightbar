import AppKit
import CoreGraphics

/// Cursor → display mapping shared by media keys, hotkeys, and the menu-bar scroll wheel.
enum InputDisplayLookup {
    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[key] as? NSNumber {
            return number.uint32Value
        }
        return screen.deviceDescription[key] as? CGDirectDisplayID
    }

    static func screenUnderCursor() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
    }

    static func hasBuiltinDisplay() -> Bool {
        NSScreen.screens.contains { screen in
            guard let id = displayID(for: screen) else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
    }

    /// External display under the cursor. Built-in → nil. Clamshell (no built-in) → first external.
    static func mediaKeyDisplay(from displays: [ExternalDisplay]) -> ExternalDisplay? {
        if let screen = screenUnderCursor(),
           let id = displayID(for: screen) {
            return displays.first { $0.id == id }
        }
        if !hasBuiltinDisplay() {
            return displays.first
        }
        return nil
    }

    /// Volume media keys: cursor must be on an external that actually has DDC audio.
    static func mediaKeyVolumeDisplay(from displays: [ExternalDisplay]) -> ExternalDisplay? {
        guard let display = mediaKeyDisplay(from: displays), display.capabilities.supportsAudio else {
            return nil
        }
        return display
    }

    /// Cursor external, or first external if the cursor is on the built-in / unresolved.
    static func hotkeyDisplay(from displays: [ExternalDisplay]) -> ExternalDisplay? {
        mediaKeyDisplay(from: displays) ?? displays.first
    }

    static func volumeHotkeyDisplay(from displays: [ExternalDisplay]) -> ExternalDisplay? {
        if let display = hotkeyDisplay(from: displays), display.capabilities.supportsAudio {
            return display
        }
        return displays.first { $0.capabilities.supportsAudio }
    }
}
