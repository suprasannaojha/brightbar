import SwiftUI

@MainActor
struct SettingsRootView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var tabState: SettingsTabState
    let displaysProvider: () -> [ExternalDisplay]
    let actions: SettingsActions

    var body: some View {
        TabView(selection: $tabState.tab) {
            GeneralSettingsView(settings: settings, actions: actions)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            DisplaysSettingsView(
                settings: settings,
                displaysProvider: displaysProvider,
                actions: actions
            )
            .tabItem { Label("Displays", systemImage: "display") }
            .tag(SettingsTab.displays)

            KeyboardSettingsView(settings: settings, actions: actions)
                .tabItem { Label("Keyboard", systemImage: "keyboard") }
                .tag(SettingsTab.keyboard)

            AutomationSettingsView(settings: settings)
                .tabItem { Label("Automation", systemImage: "clock") }
                .tag(SettingsTab.automation)

            PresetsSettingsView(settings: settings, actions: actions)
                .tabItem { Label("Presets", systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.presets)

            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: SettingsMetrics.windowWidth, height: SettingsMetrics.windowHeight)
    }
}
