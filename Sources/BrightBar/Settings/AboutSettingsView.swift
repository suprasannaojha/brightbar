import AppKit
import SwiftUI

@MainActor
struct AboutSettingsView: View {
    private let githubURL = "https://github.com/suprasannaojha/brightbar"
    private let issuesURL = "https://github.com/suprasannaojha/brightbar/issues"

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.yellow)
                        .symbolRenderingMode(.hierarchical)
                        .padding(.top, 8)

                    Text("BrightBar")
                        .font(.system(size: 18, weight: .semibold))

                    Text(versionString)
                        .font(SettingsMetrics.captionFont)
                        .foregroundStyle(.secondary)

                    Text("Menu-bar brightness, contrast, and volume control for external displays via DDC/CI.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)

                    HStack(spacing: 16) {
                        Button("GitHub") {
                            open(githubURL)
                        }
                        .buttonStyle(.link)

                        Button("Report an issue") {
                            open(issuesURL)
                        }
                        .buttonStyle(.link)
                    }
                    .padding(.top, 4)

                    Text("Released under the MIT License.")
                        .font(SettingsMetrics.captionFont)
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 8)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        if let version = info?["CFBundleShortVersionString"] as? String, !version.isEmpty {
            return version
        }
        return "1.0"
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
