import AppKit
import SwiftUI

extension Hotkey {
    /// Modifier glyphs (⌃⌥⇧⌘) plus a readable key name.
    var displayString: String {
        Self.modifierSymbols(for: carbonModifiers) + Self.keyName(for: keyCode)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let relevant = flags.intersection([.command, .shift, .option, .control])
        var mask: UInt32 = 0
        if relevant.contains(.command) { mask |= 0x0100 }
        if relevant.contains(.shift) { mask |= 0x0200 }
        if relevant.contains(.option) { mask |= 0x0800 }
        if relevant.contains(.control) { mask |= 0x1000 }
        return mask
    }

    static func modifierSymbols(for carbonModifiers: UInt32) -> String {
        var symbols = ""
        if carbonModifiers & 0x1000 != 0 { symbols += "⌃" }
        if carbonModifiers & 0x0800 != 0 { symbols += "⌥" }
        if carbonModifiers & 0x0200 != 0 { symbols += "⇧" }
        if carbonModifiers & 0x0100 != 0 { symbols += "⌘" }
        return symbols
    }

    static func keyName(for keyCode: UInt32) -> String {
        if let name = namedKeys[keyCode] {
            return name
        }
        return "Key \(keyCode)"
    }

    /// ANSI / ISO virtual key codes (HIToolbox) → display names.
    private static let namedKeys: [UInt32: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G",
        0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B",
        0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T",
        0x1F: "O", 0x20: "U", 0x22: "I", 0x23: "P", 0x25: "L", 0x26: "J",
        0x28: "K", 0x2D: "N", 0x2E: "M",
        0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5",
        0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9", 0x1D: "0",
        0x18: "=", 0x1B: "-", 0x21: "[", 0x1E: "]", 0x2A: "\\",
        0x29: ";", 0x27: "'", 0x2B: ",", 0x2F: ".", 0x2C: "/", 0x32: "`",
        0x24: "Return", 0x30: "Tab", 0x31: "Space", 0x33: "Delete",
        0x35: "Escape", 0x47: "Clear", 0x4C: "Enter",
        0x72: "Help", 0x73: "Home", 0x74: "Page Up", 0x75: "Forward Delete",
        0x77: "End", 0x79: "Page Down",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5",
        0x61: "F6", 0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10",
        0x67: "F11", 0x6F: "F12", 0x69: "F13", 0x6B: "F14", 0x71: "F15",
        0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",
        0x41: "Keypad .", 0x43: "Keypad *", 0x45: "Keypad +",
        0x4B: "Keypad /", 0x4E: "Keypad -", 0x51: "Keypad =",
        0x52: "Keypad 0", 0x53: "Keypad 1", 0x54: "Keypad 2", 0x55: "Keypad 3",
        0x56: "Keypad 4", 0x57: "Keypad 5", 0x58: "Keypad 6", 0x59: "Keypad 7",
        0x5B: "Keypad 8", 0x5C: "Keypad 9",
        0x48: "Volume Up", 0x49: "Volume Down", 0x4A: "Mute",
    ]
}

@MainActor
private final class HotkeyMonitor: ObservableObject {
    private var monitor: Any?

    func start(_ handler: @escaping (NSEvent) -> NSEvent?) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

/// Button that records a global shortcut. Requires ⌘, ⌃, or ⌥ (Shift alone is ignored).
@MainActor
struct HotkeyRecorderView: View {
    @Binding var hotkey: Hotkey?
    @State private var isRecording = false
    @StateObject private var monitor = HotkeyMonitor()

    var body: some View {
        HStack(spacing: 6) {
            Button(action: startRecording) {
                Text(isRecording ? "Type shortcut…" : (hotkey?.displayString ?? "None"))
                    .lineLimit(1)
                    .frame(minWidth: 128)
            }
            .buttonStyle(.bordered)
            .help(isRecording ? "Press a key combination, or Escape to cancel" : "Click to record a shortcut")

            if hotkey != nil {
                Button(action: clear) {
                    Text("×")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func clear() {
        hotkey = nil
        stopRecording()
    }

    private func startRecording() {
        if isRecording {
            return
        }
        isRecording = true

        let hotkeyBinding = $hotkey
        let recordingBinding = $isRecording

        monitor.start { event in
            Self.handleKeyDown(
                event,
                hotkey: hotkeyBinding,
                isRecording: recordingBinding,
                stop: { [monitor] in
                    monitor.stop()
                }
            )
        }
    }

    private func stopRecording() {
        isRecording = false
        monitor.stop()
    }

    /// Returns `nil` to consume the event while recording.
    private static func handleKeyDown(
        _ event: NSEvent,
        hotkey: Binding<Hotkey?>,
        isRecording: Binding<Bool>,
        stop: @escaping () -> Void
    ) -> NSEvent? {
        let keyCode = UInt32(event.keyCode)

        // Escape cancels.
        if keyCode == 0x35 {
            isRecording.wrappedValue = false
            stop()
            return nil
        }

        // Ignore modifier-only key-downs.
        let modifierKeyCodes: Set<UInt32> = [0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F]
        if modifierKeyCodes.contains(keyCode) {
            return nil
        }

        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let hasRequiredModifier = flags.contains(.command) || flags.contains(.control) || flags.contains(.option)
        if !hasRequiredModifier {
            return nil
        }

        hotkey.wrappedValue = Hotkey(
            keyCode: keyCode,
            carbonModifiers: Hotkey.carbonModifiers(from: flags)
        )
        isRecording.wrappedValue = false
        stop()
        return nil
    }
}
