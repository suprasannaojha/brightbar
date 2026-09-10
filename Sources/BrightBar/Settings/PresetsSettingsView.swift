import SwiftUI

@MainActor
struct PresetsSettingsView: View {
    @ObservedObject var settings: SettingsStore
    let actions: SettingsActions

    var body: some View {
        Form {
            Section {
                ForEach($settings.settings.presets) { $preset in
                    PresetEditorRow(
                        preset: $preset,
                        onApply: { actions.applyPreset(preset) },
                        onDelete: {
                            let id = preset.id
                            settings.settings.presets.removeAll { $0.id == id }
                            for index in settings.settings.schedule.entries.indices {
                                if settings.settings.schedule.entries[index].presetID == id {
                                    settings.settings.schedule.entries[index].presetID = nil
                                    if settings.settings.schedule.entries[index].brightness == nil {
                                        settings.settings.schedule.entries[index].brightness = 50
                                    }
                                }
                            }
                        }
                    )
                }

                Button("+ Add preset") {
                    settings.settings.presets.append(
                        Preset(name: "New Preset", brightness: 50, contrast: nil, hotkey: nil)
                    )
                }
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
private struct PresetEditorRow: View {
    @Binding var preset: Preset
    var onApply: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Name", text: $preset.name)
                Spacer(minLength: 8)
                Button("Apply", action: onApply)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete preset")
            }

            LabeledSlider(
                title: "Brightness",
                value: $preset.brightness,
                range: -50...100,
                valueText: SettingsFormatting.percent
            )

            Toggle("Contrast", isOn: contrastEnabled)
            if preset.contrast != nil {
                LabeledSlider(
                    title: "Contrast",
                    value: contrastValue,
                    range: 0...100,
                    valueText: SettingsFormatting.percent
                )
            }

            HStack {
                Text("Hotkey")
                Spacer(minLength: 12)
                HotkeyRecorderView(hotkey: $preset.hotkey)
            }
        }
        .padding(.vertical, 4)
    }

    private var contrastEnabled: Binding<Bool> {
        Binding(
            get: { preset.contrast != nil },
            set: { enabled in
                preset.contrast = enabled ? (preset.contrast ?? 50) : nil
            }
        )
    }

    private var contrastValue: Binding<Double> {
        Binding(
            get: { preset.contrast ?? 50 },
            set: { preset.contrast = $0 }
        )
    }
}
