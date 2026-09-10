import AppKit
import SwiftUI

@MainActor
struct GeneralSettingsView: View {
    @ObservedObject var settings: SettingsStore
    let actions: SettingsActions

    @State private var launchAtLogin = false
    @State private var cliInstalled = false
    @State private var cliMessage: String?

    private func installCLI() {
        do {
            try CLIInstaller.install()
            cliMessage = nil
        } catch {
            cliMessage = error.localizedDescription
        }
        cliInstalled = CLIInstaller.isInstalled
    }

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { launchAtLogin },
                        set: { newValue in
                            actions.setLaunchAtLogin(newValue)
                            launchAtLogin = actions.isLaunchAtLoginEnabled()
                        }
                    )
                )
            }

            Section("Menu Bar") {
                Toggle("Menu bar icon reflects brightness", isOn: settings.binding(\.iconReflectsBrightness))
                Toggle("Show percentage in menu bar", isOn: settings.binding(\.showPercentInMenuBar))
                Toggle("Show on-screen indicator", isOn: settings.binding(\.showOSD))
            }

            Section("Behaviour") {
                Toggle("Restore brightness on wake", isOn: settings.binding(\.restoreOnWake))
                Toggle(
                    "Restore brightness when a display reconnects",
                    isOn: settings.binding(\.restoreOnReconnect)
                )
            }

            Section("Command Line") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cliInstalled ? "`brightbar` command installed" : "Install the `brightbar` command")
                        Text(cliMessage ?? CLIInstaller.linkPath)
                            .font(.caption)
                            .foregroundStyle(cliMessage == nil ? Color.secondary : Color.red)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button(cliInstalled ? "Reinstall" : "Install") { installCLI() }
                }
            }

            Section("Diagnostics") {
                Button("Copy diagnostics report") {
                    actions.copyDiagnostics()
                }
                Button("Rescan displays") {
                    actions.refreshDisplays()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = actions.isLaunchAtLoginEnabled()
            cliInstalled = CLIInstaller.isInstalled
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin = actions.isLaunchAtLoginEnabled()
        }
    }
}
