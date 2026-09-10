import SwiftUI

enum SettingsMetrics {
    static let windowWidth: CGFloat = 560
    static let windowHeight: CGFloat = 420
    static let titleFont = Font.system(size: 13, weight: .semibold)
    static let captionFont = Font.system(size: 11)
}

enum SettingsFormatting {
    /// Percent label using U+2212 for negatives (no plus sign).
    static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "0%" }
        let n = Int(value.rounded())
        if n < 0 {
            return "\u{2212}\(abs(n))%"
        }
        return "\(n)%"
    }

    /// Offset-style percent: −12% / 0% / +12%.
    static func signedPercent(_ value: Double) -> String {
        guard value.isFinite else { return "0%" }
        let n = Int(value.rounded())
        if n < 0 {
            return "\u{2212}\(abs(n))%"
        }
        if n > 0 {
            return "+\(n)%"
        }
        return "0%"
    }

    static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s == 0 {
            return "Instant"
        }
        if s < 60 {
            return "\(s) s"
        }
        let minutes = s / 60
        let remainder = s % 60
        if remainder == 0 {
            return minutes == 1 ? "1 min" : "\(minutes) min"
        }
        return "\(minutes) min \(remainder) s"
    }

    static func sunOffset(_ minutes: Int, event: String) -> String {
        if minutes == 0 {
            return "At \(event)"
        }
        if minutes < 0 {
            return "\(abs(minutes)) min before \(event)"
        }
        return "\(minutes) min after \(event)"
    }
}

@MainActor
extension SettingsStore {
    func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { self.settings[keyPath: keyPath] = $0 }
        )
    }

    func displayBinding<Value>(_ key: String, _ keyPath: WritableKeyPath<DisplaySettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.display(key)[keyPath: keyPath] },
            set: { newValue in
                self.updateDisplay(key) { row in
                    row[keyPath: keyPath] = newValue
                }
            }
        )
    }
}

@MainActor
struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double?
    var valueText: (Double) -> String
    var minLabel: String?
    var maxLabel: String?
    var caption: String?

    init(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double? = nil,
        valueText: @escaping (Double) -> String,
        minLabel: String? = nil,
        maxLabel: String? = nil,
        caption: String? = nil
    ) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.valueText = valueText
        self.minLabel = minLabel
        self.maxLabel = maxLabel
        self.caption = caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer(minLength: 8)
                Text(valueText(value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if let minLabel, let maxLabel {
                HStack(spacing: 8) {
                    Text(minLabel)
                        .font(SettingsMetrics.captionFont)
                        .foregroundStyle(.secondary)
                    slider
                    Text(maxLabel)
                        .font(SettingsMetrics.captionFont)
                        .foregroundStyle(.secondary)
                }
            } else {
                slider
            }

            if let caption {
                Text(caption)
                    .font(SettingsMetrics.captionFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var slider: some View {
        if let step {
            Slider(value: $value, in: range, step: step)
        } else {
            Slider(value: $value, in: range)
        }
    }
}

extension View {
    @ViewBuilder
    func onChangeCompat<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        if #available(macOS 14.0, *) {
            onChange(of: value) { _, newValue in
                action(newValue)
            }
        } else {
            onChange(of: value, perform: action)
        }
    }
}
