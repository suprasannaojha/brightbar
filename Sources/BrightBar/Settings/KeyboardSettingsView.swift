import AppKit
import SwiftUI

@MainActor
struct KeyboardSettingsView: View {
    @ObservedObject var settings: SettingsStore
    let actions: SettingsActions

    @State private var accessibilityTrusted = false

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Use keyboard brightness keys (F1/F2)",
                    isOn: settings.binding(\.brightnessKeysEnabled)
                )
                accessibilityRow
            }

            Section {
                Toggle(
                    "Use volume/mute keys for monitor audio",
                    isOn: settings.binding(\.volumeKeysEnabled)
                )
                Toggle(
                    "Scroll on the menu bar icon to adjust brightness",
                    isOn: settings.binding(\.scrollWheelOnMenuBarIcon)
                )
                LabeledSlider(
                    title: "Step",
                    value: settings.binding(\.hotkeys.step),
                    range: 1...20,
                    step: 1,
                    valueText: { "\(Int($0.rounded()))%" }
                )
            }

            Section("Global shortcuts") {
                ForEach(Self.hotkeyRows) { row in
                    HStack {
                        Text(row.title)
                        Spacer(minLength: 12)
                        HotkeyRecorderView(hotkey: hotkeyBinding(row.keyPath))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshAccessibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAccessibility()
        }
    }

    @ViewBuilder
    private var accessibilityRow: some View {
        if accessibilityTrusted {
            Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(SettingsMetrics.captionFont)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(
                    "Accessibility access is required for brightness keys.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .font(SettingsMetrics.captionFont)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Grant Access…") {
                    actions.requestAccessibility()
                    refreshAccessibility()
                }
            }
        }
    }

    private func refreshAccessibility() {
        accessibilityTrusted = actions.isAccessibilityTrusted()
    }

    private func hotkeyBinding(_ keyPath: WritableKeyPath<HotkeyBindings, Hotkey?>) -> Binding<Hotkey?> {
        Binding(
            get: { settings.settings.hotkeys[keyPath: keyPath] },
            set: { newValue in
                settings.settings.hotkeys[keyPath: keyPath] = newValue
            }
        )
    }

    private static let hotkeyRows: [HotkeyRow] = [
        HotkeyRow(id: "brightnessUp", title: "Brightness up", keyPath: \.brightnessUp),
        HotkeyRow(id: "brightnessDown", title: "Brightness down", keyPath: \.brightnessDown),
        HotkeyRow(id: "allBrightnessUp", title: "All displays up", keyPath: \.allBrightnessUp),
        HotkeyRow(id: "allBrightnessDown", title: "All displays down", keyPath: \.allBrightnessDown),
        HotkeyRow(id: "volumeUp", title: "Volume up", keyPath: \.volumeUp),
        HotkeyRow(id: "volumeDown", title: "Volume down", keyPath: \.volumeDown),
        HotkeyRow(id: "toggleMute", title: "Toggle mute", keyPath: \.toggleMute),
    ]
}

private struct HotkeyRow: Identifiable {
    var id: String
    var title: String
    var keyPath: WritableKeyPath<HotkeyBindings, Hotkey?>
}
