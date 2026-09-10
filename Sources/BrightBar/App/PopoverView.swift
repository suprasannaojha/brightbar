import AppKit
import SwiftUI

/// Popover content, styled after the Display module in macOS Control Center:
/// a thick capsule slider with the glyph inside the fill, name + value on one line.
struct PopoverView: View {
    @ObservedObject var store: BrightnessStore
    @ObservedObject var keyCoordinator: BrightnessKeyCoordinator

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
        let isUnsupported = store.unsupported.contains(display.id)
        let value = store.brightness[display.id] ?? 0
        let range: ClosedRange<Double> = isUnsupported
            ? BrightnessStore.minimumLevel...0
            : BrightnessStore.minimumLevel...BrightnessStore.maximumLevel

        let caption: String?
        if isUnsupported {
            caption = "No DDC/CI response · software dimming only"
        } else if value < 0 {
            caption = "Software dimming"
        } else {
            caption = nil
        }

        return sliderRow(
            title: display.name,
            value: Binding(
                get: { store.brightness[display.id] ?? 0 },
                set: { store.setBrightness($0, for: display) }
            ),
            range: range,
            caption: caption
        )
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
            Divider().opacity(0.6)
            HStack {
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Scanning…")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("BrightBar")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
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

    private let height: CGFloat = 24
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let span = max(range.upperBound - range.lowerBound, 1)
            let fraction = min(max((value - range.lowerBound) / span, 0), 1)
            // Fill never shrinks below a full circle so the glyph always sits on it;
            // same mapping as `update(with:)` so the fill edge tracks the pointer.
            let fillWidth = height + (totalWidth - height) * fraction

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.10))

                Capsule(style: .continuous)
                    .fill(Color.white)
                    .frame(width: fillWidth)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)

                Image(systemName: value < 0 ? "moon.fill" : "sun.max.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.72))
                    .frame(width: height, height: height)
            }
            .contentShape(Capsule(style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { gesture in
                        isDragging = true
                        update(with: gesture.location.x, width: totalWidth, span: span)
                    }
                    .onEnded { gesture in
                        update(with: gesture.location.x, width: totalWidth, span: span)
                        isDragging = false
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
