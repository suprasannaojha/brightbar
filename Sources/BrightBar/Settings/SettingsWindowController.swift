import AppKit
import SwiftUI

enum SettingsTab: Hashable {
    case general
    case displays
    case keyboard
    case automation
    case presets
    case about
}

struct SettingsActions {
    var isLaunchAtLoginEnabled: () -> Bool
    var setLaunchAtLogin: (Bool) -> Void
    var isAccessibilityTrusted: () -> Bool
    var requestAccessibility: () -> Void
    var applyPreset: (Preset) -> Void
    var previewBrightness: (ExternalDisplay, Double) -> Void
    var copyDiagnostics: () -> Void
    var refreshDisplays: () -> Void
}

@MainActor
final class SettingsTabState: ObservableObject {
    @Published var tab: SettingsTab = .general
}

@MainActor
final class SettingsWindowController: NSObject {
    private let settings: SettingsStore
    private let displaysProvider: () -> [ExternalDisplay]
    private let actions: SettingsActions
    private let tabState = SettingsTabState()

    private var window: NSWindow?
    private var didCenter = false

    init(
        settings: SettingsStore,
        displaysProvider: @escaping () -> [ExternalDisplay],
        actions: SettingsActions
    ) {
        self.settings = settings
        self.displaysProvider = displaysProvider
        self.actions = actions
        super.init()
    }

    func show(tab: SettingsTab? = nil) {
        if let tab {
            tabState.tab = tab
        }

        let window = ensureWindow()
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        activateApplication()
        window.makeKey()

        if !didCenter {
            window.center()
            didCenter = true
        }
    }

    private func ensureWindow() -> NSWindow {
        if let window {
            return window
        }

        let root = SettingsRootView(
            settings: settings,
            tabState: tabState,
            displaysProvider: displaysProvider,
            actions: actions
        )
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsMetrics.windowWidth, height: SettingsMetrics.windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BrightBar Settings"
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.contentMinSize = NSSize(width: SettingsMetrics.windowWidth, height: 400)
        window.contentMaxSize = NSSize(width: SettingsMetrics.windowWidth, height: 900)
        window.collectionBehavior = [.moveToActiveSpace]
        self.window = window
        return window
    }

    private func activateApplication() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
