import SwiftUI

@MainActor
struct AutomationSettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Enabled", isOn: settings.binding(\.schedule.enabled))
                Toggle(
                    "Use my location for sunrise/sunset",
                    isOn: settings.binding(\.schedule.useLocation)
                )

                if !settings.settings.schedule.useLocation {
                    DecimalTextField(
                        title: "Latitude",
                        value: settings.binding(\.schedule.latitude)
                    )
                    DecimalTextField(
                        title: "Longitude",
                        value: settings.binding(\.schedule.longitude)
                    )
                }

                LabeledSlider(
                    title: "Ramp duration",
                    value: settings.binding(\.schedule.rampDurationSeconds),
                    range: 0...600,
                    step: 1,
                    valueText: SettingsFormatting.duration
                )
            } header: {
                Text("Schedule")
            } footer: {
                Text("Sync with built-in display and the schedule can both be on. Schedule events set the manual brightness level.")
                    .font(SettingsMetrics.captionFont)
            }

            Section {
                ForEach($settings.settings.schedule.entries) { $entry in
                    ScheduleEntryRow(
                        entry: $entry,
                        presets: settings.settings.presets,
                        onDelete: {
                            let id = entry.id
                            settings.settings.schedule.entries.removeAll { $0.id == id }
                        }
                    )
                }

                Button("+ Add") {
                    settings.settings.schedule.entries.append(
                        ScheduleEntry(
                            trigger: .time(hour: 21, minute: 0),
                            brightness: 50
                        )
                    )
                }
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
private struct ScheduleEntryRow: View {
    @Binding var entry: ScheduleEntry
    var presets: [Preset]
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Enabled", isOn: $entry.enabled)
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete event")
            }

            Picker("Trigger", selection: triggerKind) {
                Text("Time").tag(TriggerKind.time)
                Text("Sunrise").tag(TriggerKind.sunrise)
                Text("Sunset").tag(TriggerKind.sunset)
            }

            switch entry.trigger {
            case .time:
                DatePicker(
                    "Time",
                    selection: timeBinding,
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.field)
            case .sunrise(let minutes):
                Stepper(value: sunOffsetBinding, in: -120...120) {
                    Text(SettingsFormatting.sunOffset(minutes, event: "sunrise"))
                }
            case .sunset(let minutes):
                Stepper(value: sunOffsetBinding, in: -120...120) {
                    Text(SettingsFormatting.sunOffset(minutes, event: "sunset"))
                }
            }

            Picker("Action", selection: actionChoice) {
                Text("Brightness").tag(ActionChoice.brightness)
                ForEach(presets) { preset in
                    Text(preset.name).tag(ActionChoice.preset(preset.id))
                }
                if let id = entry.presetID, presets.contains(where: { $0.id == id }) == false {
                    Text("Missing preset").tag(ActionChoice.preset(id))
                }
            }

            if entry.presetID == nil {
                LabeledSlider(
                    title: "Brightness",
                    value: brightnessBinding,
                    range: -50...100,
                    valueText: SettingsFormatting.percent
                )
            }
        }
        .padding(.vertical, 4)
    }

    private var triggerKind: Binding<TriggerKind> {
        Binding(
            get: {
                switch entry.trigger {
                case .time: return .time
                case .sunrise: return .sunrise
                case .sunset: return .sunset
                }
            },
            set: { kind in
                let previousOffset: Int
                switch entry.trigger {
                case .time: previousOffset = 0
                case .sunrise(let minutes), .sunset(let minutes): previousOffset = minutes
                }
                switch kind {
                case .time:
                    if case .time = entry.trigger { return }
                    entry.trigger = .time(hour: 9, minute: 0)
                case .sunrise:
                    entry.trigger = .sunrise(offsetMinutes: previousOffset)
                case .sunset:
                    entry.trigger = .sunset(offsetMinutes: previousOffset)
                }
            }
        )
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                if case .time(let hour, let minute) = entry.trigger {
                    return Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? Date()
                }
                return Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                entry.trigger = .time(hour: components.hour ?? 0, minute: components.minute ?? 0)
            }
        )
    }

    private var sunOffsetBinding: Binding<Int> {
        Binding(
            get: {
                switch entry.trigger {
                case .sunrise(let minutes), .sunset(let minutes):
                    return minutes
                case .time:
                    return 0
                }
            },
            set: { minutes in
                switch entry.trigger {
                case .sunrise:
                    entry.trigger = .sunrise(offsetMinutes: minutes)
                case .sunset:
                    entry.trigger = .sunset(offsetMinutes: minutes)
                case .time:
                    break
                }
            }
        )
    }

    private var actionChoice: Binding<ActionChoice> {
        Binding(
            get: {
                if let id = entry.presetID {
                    return .preset(id)
                }
                return .brightness
            },
            set: { choice in
                switch choice {
                case .brightness:
                    entry.presetID = nil
                    if entry.brightness == nil {
                        entry.brightness = 50
                    }
                case .preset(let id):
                    entry.presetID = id
                }
            }
        )
    }

    private var brightnessBinding: Binding<Double> {
        Binding(
            get: { entry.brightness ?? 50 },
            set: { entry.brightness = $0 }
        )
    }
}

@MainActor
private struct DecimalTextField: View {
    let title: String
    @Binding var value: Double?
    @State private var text = ""

    var body: some View {
        TextField(title, text: $text)
            .onAppear {
                text = Self.string(from: value)
            }
            .onChangeCompat(of: text) { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    value = nil
                    return
                }
                if let parsed = Double(trimmed) {
                    value = parsed
                }
            }
    }

    private static func string(from value: Double?) -> String {
        guard let value else { return "" }
        return String(value)
    }
}

private enum TriggerKind: Hashable {
    case time
    case sunrise
    case sunset
}

private enum ActionChoice: Hashable {
    case brightness
    case preset(UUID)
}
