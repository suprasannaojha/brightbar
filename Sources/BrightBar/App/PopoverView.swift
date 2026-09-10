import AppKit
import SwiftUI

/// Popover content, styled after the Display module in macOS Control Center:
/// a thick capsule slider with the glyph inside the fill, name + value on one line.
struct PopoverView: View {
    @ObservedObject var store: BrightnessStore
    @ObservedObject var keyCoordinator: BrightnessKeyCoordinator
    @ObservedObject var settings: SettingsStore
    var openSettings: () -> Void

    private let width: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if store.displays.isEmpty {
                emptyState
            } else {
                if store.displays.count > 1 {
                    allDisplaysRow
                }
                ForEach(store.displays) { display in
                    displayRow(display)
                }
            }

            if keyCoordinator.needsAccessibilityPermission {
                accessibilityBanner
            }

            footer
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            store.refresh()
            keyCoordinator.handlePopoverOpened()
        }
    }

    // MARK: Rows

    private var allDisplaysRow: some View {
        let range = BrightnessStore.minimumLevel...BrightnessStore.maximumLevel
        let value = masterBrightness
        return sliderRow(
            title: "All Displays",
            value: Binding(get: { masterBrightness }, set: { store.setAll($0) }),
            range: range,
            caption: value < 0 ? "Software dimming" : nil
        )
    }

    private func displayRow(_ display: ExternalDisplay) -> some View {
        let softwareOnly = store.isSoftwareOnly(display)
        let value = store.brightness[display.id] ?? 0
        let range: ClosedRange<Double> = softwareOnly
            ? BrightnessStore.minimumLevel...0
            : BrightnessStore.minimumLevel...BrightnessStore.maximumLevel
        let ds = settings.display(display.persistentKey)

        let caption: String?
        if ds.forceSoftwareDimming {
            caption = "Software dimming only"
        } else if softwareOnly {
            caption = "No DDC/CI response · software dimming only"
        } else if value < 0 {
            caption = "Software dimming"
        } else {
            caption = nil
        }

        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(display.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if display.capabilities.supportsDDC, store.inputSource[display.id] != nil {
                    inputMenu(for: display)
                }
                Spacer(minLength: 8)
                Text(percentLabel(value))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            CapsuleSlider(
                value: Binding(
                    get: { store.brightness[display.id] ?? 0 },
                    set: { store.setBrightness($0, for: display) }
                ),
                range: range
            )
            .accessibilityLabel(display.name)
            .accessibilityValue(percentLabel(value))

            if let caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            if ds.showContrast, display.capabilities.supportsContrast {
                compactSliderRow(
                    title: "Contrast",
                    value: Binding(
                        get: { store.contrast[display.id] ?? 0 },
                        set: { store.setContrast($0, for: display) }
                    ),
                    systemImage: "circle.lefthalf.filled"
                )
            }

            if ds.showVolume, display.capabilities.supportsAudio {
                let isMuted = store.muted[display.id] ?? false
                compactSliderRow(
                    title: "Volume",
                    value: Binding(
                        get: { store.volume[display.id] ?? 0 },
                        set: { store.setVolume($0, for: display) }
                    ),
                    systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    fillDimmed: isMuted,
                    onGlyphTap: { store.toggleMute(for: display) }
                )
            }
        }
    }

    private func inputMenu(for display: ExternalDisplay) -> some View {
        let code = store.inputSource[display.id]
        let title = code.flatMap { InputSource(rawValue: $0)?.displayName } ?? "Input"
        return Menu {
            ForEach(InputSource.common) { source in
                Button(source.displayName) {
                    store.setInputSource(source.rawValue, for: display)
                }
            }
        } label: {
            HStack(spacing: 2) {
                Text(title)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .foregroundStyle(.secondary)
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        caption: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(percentLabel(value.wrappedValue))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            CapsuleSlider(value: value, range: range)
                .accessibilityLabel(title)
                .accessibilityValue(percentLabel(value.wrappedValue))

            if let caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func compactSliderRow(
        title: String,
        value: Binding<Double>,
        systemImage: String,
        fillDimmed: Bool = false,
        onGlyphTap: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                Text(percentLabel(value.wrappedValue))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            CapsuleSlider(
                value: value,
                range: 0...100,
                height: 18,
                systemImage: systemImage,
                fillDimmed: fillDimmed,
                onGlyphTap: onGlyphTap
            )
            .accessibilityLabel(title)
            .accessibilityValue(percentLabel(value.wrappedValue))
        }
    }

    // MARK: Empty / footer

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)
            Text("No External Displays")
                .font(.system(size: 13, weight: .semibold))
            Text("Connect a monitor that supports DDC/CI. The built-in display isn’t controlled here.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private var accessibilityBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Allow Accessibility access to use the brightness keys.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button("Open Settings") {
                AccessibilityPermission.openSystemSettings()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize()
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if !settings.settings.presets.isEmpty {
                presetChips
            }
            Divider().opacity(0.6)
            HStack {
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Scanning…")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else {
                    Button(action: openSettings) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Settings")
                    .accessibilityLabel("Settings")
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
    }

    private var presetChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(settings.settings.presets) { preset in
                    Button(preset.name) {
                        store.applyPreset(preset)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.quaternary)
                    )
                }
            }
        }
    }

    // MARK: Helpers

    private func percentLabel(_ percent: Double) -> String {
        let n = Int(percent.rounded())
        return n < 0 ? "−\(abs(n))%" : "\(n)%"
    }

    private var masterBrightness: Double {
        let values = store.displays.compactMap { store.brightness[$0.id] }
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}

/// Control Center style slider: rounded track, solid fill, glyph inside the fill.
/// Integer-stepped, no tick marks. Click or drag anywhere on the track.
private struct CapsuleSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var height: CGFloat = 24
    var systemImage: String? = nil
    var fillDimmed: Bool = false
    var onGlyphTap: (() -> Void)? = nil

    @State private var isDragging = false
    @State private var hasMoved = false

    var body: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let span = max(range.upperBound - range.lowerBound, 1)
            let fraction = min(max((value - range.lowerBound) / span, 0), 1)
            // Fill never shrinks below a full circle so the glyph always sits on it;
            // same mapping as `update(with:)` so the fill edge tracks the pointer.
            let fillWidth = height + (totalWidth - height) * fraction
            let glyphName = systemImage ?? (value < 0 ? "moon.fill" : "sun.max.fill")
            let glyphSize: CGFloat = height >= 22 ? 11 : 9

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.10))

                Capsule(style: .continuous)
                    .fill(Color.white.opacity(fillDimmed ? 0.42 : 1))
                    .frame(width: fillWidth)
                    .shadow(color: .black.opacity(fillDimmed ? 0.08 : 0.18), radius: 1, y: 0.5)

                Image(systemName: glyphName)
                    .font(.system(size: glyphSize, weight: .bold))
                    .foregroundStyle(Color.black.opacity(fillDimmed ? 0.45 : 0.72))
                    .frame(width: height, height: height)
            }
            .contentShape(Capsule(style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { gesture in
                        isDragging = true
                        if onGlyphTap != nil, !hasMoved {
                            let moved = abs(gesture.translation.width) > 3
                                || abs(gesture.translation.height) > 3
                            if !moved { return }
                            hasMoved = true
                        }
                        update(with: gesture.location.x, width: totalWidth, span: span)
                    }
                    .onEnded { gesture in
                        if let onGlyphTap, !hasMoved, gesture.startLocation.x <= height {
                            onGlyphTap()
                        } else {
                            update(with: gesture.location.x, width: totalWidth, span: span)
                        }
                        isDragging = false
                        hasMoved = false
                    }
            )
            .animation(isDragging ? nil : .easeOut(duration: 0.12), value: value)
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityAdjustableAction { direction in
            let step: Double = direction == .increment ? 5 : -5
            value = min(max(value + step, range.lowerBound), range.upperBound)
        }
    }

    private func update(with x: CGFloat, width: CGFloat, span: Double) {
        guard width > 0 else { return }
        // Map the pointer so the glyph circle's centre corresponds to the range minimum.
        let usable = max(width - height, 1)
        let fraction = min(max((x - height / 2) / usable, 0), 1)
        let newValue = (range.lowerBound + Double(fraction) * span).rounded()
        if newValue != value {
            value = newValue
        }
    }
}
