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

    var onVisibilityChange: (() -> Void)?
    private(set) var isPresented = false

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

        if !didCenter {
            positionOnActiveScreen(window)
            didCenter = true
        }

        activateApplication()
        window.makeKeyAndOrderFront(nil)
        window.makeKey()
        isPresented = true
        onVisibilityChange?()
    }

    /// Centre on the screen the user is looking at (the one under the cursor — i.e. where the
    /// menu bar icon was clicked), slightly above centre like System Settings, instead of on
    /// whatever screen AppKit considers "main".
    private func positionOnActiveScreen(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else {
            window.center()
            return
        }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + visible.height * 0.08
        )
        window.setFrameOrigin(origin)
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

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsMetrics.windowWidth, height: SettingsMetrics.windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "BrightBar"
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: SettingsMetrics.windowWidth, height: SettingsMetrics.windowHeight))
        window.contentMinSize = NSSize(width: SettingsMetrics.windowWidth, height: SettingsMetrics.windowMinHeight)
        window.contentMaxSize = NSSize(width: 1000, height: 900)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        window.isMovableByWindowBackground = false
        window.delegate = self
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

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        isPresented = false
        onVisibilityChange?()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        isPresented = false
        onVisibilityChange?()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        isPresented = true
        onVisibilityChange?()
    }
}
