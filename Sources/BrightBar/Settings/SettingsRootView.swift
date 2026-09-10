import SwiftUI

/// System Settings–style shell: a fixed sidebar of sections on the left, the selected
/// section's grouped form on the right. Always visible navigation — no tab overflow.
@MainActor
struct SettingsRootView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var tabState: SettingsTabState
    let displaysProvider: () -> [ExternalDisplay]
    let actions: SettingsActions

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $tabState.tab) {
                ForEach(SettingsTab.allCases) { tab in
                    SidebarRow(tab: tab)
                        .tag(tab)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(SettingsMetrics.sidebarWidth)
            .scrollDisabled(true)
            .modifier(HideSidebarToggle())
        } detail: {
            detail(for: tabState.tab)
                .navigationTitle(tabState.tab.title)
                .frame(minWidth: SettingsMetrics.detailMinWidth)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(
            minWidth: SettingsMetrics.windowWidth,
            minHeight: SettingsMetrics.windowMinHeight
        )
    }

    @ViewBuilder
    private func detail(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            GeneralSettingsView(settings: settings, actions: actions)
        case .displays:
            DisplaysSettingsView(settings: settings, displaysProvider: displaysProvider, actions: actions)
        case .keyboard:
            KeyboardSettingsView(settings: settings, actions: actions)
        case .automation:
            AutomationSettingsView(settings: settings)
        case .presets:
            PresetsSettingsView(settings: settings, actions: actions)
        case .about:
            AboutSettingsView()
        }
    }
}

/// The sidebar is fixed, so hide the collapse button where the API exists (macOS 14+).
private struct HideSidebarToggle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.toolbar(removing: .sidebarToggle)
        } else {
            content
        }
    }
}

/// Sidebar entry with a System Settings–style tinted icon tile.
private struct SidebarRow: View {
    let tab: SettingsTab

    var body: some View {
        Label {
            Text(tab.title)
        } icon: {
            Image(systemName: tab.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tab.tint.gradient)
                )
        }
        .padding(.vertical, 1)
    }
}

extension SettingsTab: CaseIterable, Identifiable {
    static var allCases: [SettingsTab] { [.general, .displays, .keyboard, .automation, .presets, .about] }

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .displays: return "Displays"
        case .keyboard: return "Keyboard"
        case .automation: return "Automation"
        case .presets: return "Presets"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .displays: return "display"
        case .keyboard: return "keyboard.fill"
        case .automation: return "clock.fill"
        case .presets: return "slider.horizontal.3"
        case .about: return "info"
        }
    }

    var tint: Color {
        switch self {
        case .general: return Color(.systemGray)
        case .displays: return .blue
        case .keyboard: return Color(nsColor: .systemIndigo)
        case .automation: return .orange
        case .presets: return .purple
        case .about: return Color(.systemGray)
        }
    }
}
