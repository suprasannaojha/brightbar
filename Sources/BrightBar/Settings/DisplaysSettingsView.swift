import SwiftUI

@MainActor
struct DisplaysSettingsView: View {
    @ObservedObject var settings: SettingsStore
    let displaysProvider: () -> [ExternalDisplay]
    let actions: SettingsActions

    @State private var selectedKey = ""

    private var items: [DisplayItem] {
        DisplayItem.build(connected: displaysProvider(), stored: settings.settings.displays)
    }

    private var itemIDs: [String] {
        items.map(\.id)
    }

    var body: some View {
        Form {
            if items.isEmpty {
                Section {
                    Text("No displays. Connect a monitor, or wait for a saved display to reconnect.")
                        .font(SettingsMetrics.captionFont)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    displayPicker
                }

                if let item = items.first(where: { $0.id == selectedKey }) {
                    displayEditor(item)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            ensureSelection()
        }
        .onChangeCompat(of: itemIDs) { _ in
            ensureSelection()
        }
    }

    @ViewBuilder
    private var displayPicker: some View {
        if items.count <= 3 {
            Picker("Display", selection: $selectedKey) {
                ForEach(items) { item in
                    Text(item.pickerTitle(friendlyName: settings.display(item.id).friendlyName))
                        .tag(item.id)
                }
            }
            .pickerStyle(.segmented)
        } else {
            Picker("Display", selection: $selectedKey) {
                ForEach(items) { item in
                    Text(item.pickerTitle(friendlyName: settings.display(item.id).friendlyName))
                        .tag(item.id)
                }
            }
            .pickerStyle(.menu)
        }
    }

    @ViewBuilder
    private func displayEditor(_ item: DisplayItem) -> some View {
        let key = item.id
        let connected = item.connected

        Section("Identity") {
            TextField(
                item.hardwareName,
                text: Binding(
                    get: { settings.display(key).friendlyName ?? "" },
                    set: { newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        settings.updateDisplay(key) { row in
                            row.friendlyName = trimmed.isEmpty ? nil : trimmed
                        }
                    }
                )
            )
            .textFieldStyle(.roundedBorder)

            Picker("Brightness mode", selection: settings.displayBinding(key, \.brightnessMode)) {
                ForEach(BrightnessMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        }

        if let connected {
            Section("Brightness") {
                LabeledSlider(
                    title: "Brightness",
                    value: Binding(
                        get: { settings.display(key).lastBrightness ?? 50 },
                        set: { newValue in
                            settings.updateDisplay(key) { row in
                                row.lastBrightness = newValue
                            }
                            actions.previewBrightness(connected, newValue)
                        }
                    ),
                    range: -50...100,
                    valueText: SettingsFormatting.percent
                )
            }
        }

        if settings.display(key).brightnessMode == .syncWithBuiltin {
            Section("Sync with built-in display") {
                LabeledSlider(
                    title: "Offset",
                    value: settings.displayBinding(key, \.syncOffset),
                    range: -50...50,
                    valueText: SettingsFormatting.signedPercent
                )

                LabeledSlider(
                    title: "Curve",
                    value: invertedCurveBinding(key),
                    range: 0.25...4,
                    valueText: { visual in
                        String(format: "%.2f", 4.25 - visual)
                    },
                    minLabel: "Darker",
                    maxLabel: "Brighter"
                )

                HStack {
                    Spacer(minLength: 0)
                    SyncCurvePreview(
                        curve: settings.display(key).syncCurve,
                        offset: settings.display(key).syncOffset
                    )
                    Spacer(minLength: 0)
                }
            }
        }

        Section {
            LabeledSlider(
                title: "Minimum",
                value: Binding(
                    get: { settings.display(key).minBrightness },
                    set: { newValue in
                        settings.updateDisplay(key) { row in
                            let cap = max(row.maxBrightness - 5, 0)
                            row.minBrightness = min(max(newValue, 0), cap)
                        }
                    }
                ),
                range: 0...max(settings.display(key).maxBrightness - 5, 0),
                valueText: SettingsFormatting.percent
            )

            LabeledSlider(
                title: "Maximum",
                value: Binding(
                    get: { settings.display(key).maxBrightness },
                    set: { newValue in
                        settings.updateDisplay(key) { row in
                            let floor = min(row.minBrightness + 5, 100)
                            row.maxBrightness = max(min(newValue, 100), floor)
                        }
                    }
                ),
                range: min(settings.display(key).minBrightness + 5, 100)...100,
                valueText: SettingsFormatting.percent
            )
        } header: {
            Text("Usable range")
        } footer: {
            Text("Some monitors are unusable below ~20%. The slider maps onto this range.")
                .font(SettingsMetrics.captionFont)
        }

        Section("Advanced") {
            Toggle("Force software dimming (skip DDC/CI)", isOn: settings.displayBinding(key, \.forceSoftwareDimming))
            Toggle("Show contrast slider in popover", isOn: settings.displayBinding(key, \.showContrast))

            let supportsAudio = connected?.capabilities.supportsAudio ?? true
            Toggle("Show volume slider in popover", isOn: settings.displayBinding(key, \.showVolume))
                .disabled(!supportsAudio)
            if let connected, !connected.capabilities.supportsAudio {
                Text("This display does not report audio over DDC/CI")
                    .font(SettingsMetrics.captionFont)
                    .foregroundStyle(.secondary)
            }
        }

        if !item.isConnected {
            Section {
                Button("Forget this display", role: .destructive) {
                    forget(key)
                }
            }
        }
    }

    /// Slider is Darker (left, curve 4) → Brighter (right, curve 0.25).
    private func invertedCurveBinding(_ key: String) -> Binding<Double> {
        Binding(
            get: { 4.25 - settings.display(key).syncCurve },
            set: { visual in
                let stored = min(max(4.25 - visual, 0.25), 4)
                settings.updateDisplay(key) { row in
                    row.syncCurve = stored
                }
            }
        )
    }

    private func ensureSelection() {
        if items.contains(where: { $0.id == selectedKey }) {
            return
        }
        selectedKey = items.first?.id ?? ""
    }

    private func forget(_ key: String) {
        settings.settings.displays.removeValue(forKey: key)
        ensureSelection()
    }
}

private struct DisplayItem: Identifiable, Hashable {
    var persistentKey: String
    var hardwareName: String
    var isConnected: Bool
    var connected: ExternalDisplay?

    var id: String { persistentKey }

    func pickerTitle(friendlyName: String?) -> String {
        let trimmed = friendlyName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = trimmed.isEmpty ? hardwareName : trimmed
        if isConnected {
            return base
        }
        return "\(base) (disconnected)"
    }

    static func build(connected: [ExternalDisplay], stored: [String: DisplaySettings]) -> [DisplayItem] {
        var items = connected.map { display in
            DisplayItem(
                persistentKey: display.persistentKey,
                hardwareName: display.name,
                isConnected: true,
                connected: display
            )
        }
        let connectedKeys = Set(items.map(\.persistentKey))
        for (key, storedSettings) in stored {
            if connectedKeys.contains(key) {
                continue
            }
            let name: String
            if let friendly = storedSettings.friendlyName, !friendly.isEmpty {
                name = friendly
            } else {
                name = key
            }
            items.append(
                DisplayItem(
                    persistentKey: key,
                    hardwareName: name,
                    isConnected: false,
                    connected: nil
                )
            )
        }
        items.sort { lhs, rhs in
            lhs.hardwareName.localizedCaseInsensitiveCompare(rhs.hardwareName) == .orderedAscending
        }
        return items
    }
}

/// Live plot of `y = x^curve + offset` (offset is percent, scaled by 1/100 for the 0…1 plot).
@MainActor
struct SyncCurvePreview: View {
    var curve: Double
    var offset: Double

    var body: some View {
        Canvas { context, size in
            let steps = 48
            var path = Path()
            for i in 0...steps {
                let x = Double(i) / Double(steps)
                let exponent = max(curve, 0.001)
                let y = pow(x, exponent) + offset / 100.0
                let yClamped = min(max(y, 0), 1)
                let point = CGPoint(
                    x: CGFloat(x) * size.width,
                    y: size.height - CGFloat(yClamped) * size.height
                )
                if i == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }

            var diagonal = Path()
            diagonal.move(to: CGPoint(x: 0, y: size.height))
            diagonal.addLine(to: CGPoint(x: size.width, y: 0))
            context.stroke(
                diagonal,
                with: .color(.secondary.opacity(0.22)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )
            context.stroke(path, with: .color(.accentColor), lineWidth: 1.8)
        }
        .frame(width: 120, height: 60)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .accessibilityLabel("Brightness curve preview")
    }
}
