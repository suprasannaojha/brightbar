import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    let store: BrightnessStore
    private let settings: SettingsStore
    private let keyCoordinator: BrightnessKeyCoordinator
    private let hotkeyManager: HotkeyManager
    private let popover = NSPopover()
    private let statusItem: NSStatusItem
    private var scrollMonitor: StatusItemScrollMonitor?
    private var cancellables = Set<AnyCancellable>()

    private static let hasLaunchedBeforeKey = "com.brightbar.hasLaunchedBefore"
    private let forceIconVisibleThisSession: Bool
    private var displaysEmptyForIcon = false
    private var temporarilyVisible = false
    private var temporaryRevealDuration: TimeInterval = 20
    private var hideAfterRevealWorkItem: DispatchWorkItem?
    private var settingsWindowController: SettingsWindowController?

    init(controller: BrightnessController, settings: SettingsStore) {
        let store = BrightnessStore(controller: controller, settings: settings)
        self.store = store
        self.settings = settings
        self.keyCoordinator = MediaKeyCoordinator(target: store, settings: settings)
        self.hotkeyManager = HotkeyManager(target: store, settings: settings)
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let defaults = UserDefaults.standard
        let isFirstLaunch = defaults.object(forKey: Self.hasLaunchedBeforeKey) == nil
        self.forceIconVisibleThisSession = isFirstLaunch
        if isFirstLaunch {
            defaults.set(true, forKey: Self.hasLaunchedBeforeKey)
        }

        super.init()
        configurePopover()
        configureStatusItem()
        observeAppearance()
        observeIconVisibility()
        hotkeyManager.start()
        if let button = statusItem.button {
            scrollMonitor = StatusItemScrollMonitor(button: button, target: store, settings: settings)
        }
    }

    func openSettings(tab: SettingsTab? = nil) {
        let window = makeSettingsWindowIfNeeded()
        window.show(tab: tab)
        if popover.isShown {
            let animates = popover.animates
            popover.animates = false
            popover.performClose(nil)
            popover.animates = animates
        }
        updateIconVisibility()
    }

    /// Shows the menu bar icon and popover, then hides again `seconds` after the popover closes.
    func revealTemporarily(seconds: TimeInterval = 20) {
        temporaryRevealDuration = seconds
        temporarilyVisible = true
        hideAfterRevealWorkItem?.cancel()
        hideAfterRevealWorkItem = nil
        updateIconVisibility()
        DispatchQueue.main.async { [weak self] in
            self?.showPopover()
        }
    }

    func shutdown() {
        hideAfterRevealWorkItem?.cancel()
        hideAfterRevealWorkItem = nil
        hotkeyManager.stop()
        scrollMonitor?.invalidate()
        scrollMonitor = nil
        keyCoordinator.shutdown()
        store.shutdown()
    }

    private func configurePopover() {
        let hostingController = NSHostingController(
            rootView: PopoverView(
                store: store,
                keyCoordinator: keyCoordinator,
                settings: settings,
                openSettings: { [weak self] in
                    self?.openSettings()
                }
            )
        )
        // NSPopover sizes itself from `preferredContentSize`, not the view's intrinsic size.
        // Publishing both keeps the popover hugging the SwiftUI content as rows come and go.
        hostingController.sizingOptions = [.intrinsicContentSize, .preferredContentSize]
        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        // Default is left-click only; include right-click so we can show the context menu.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusItemAppearance()
    }

    private func observeAppearance() {
        Publishers.CombineLatest3(store.$brightness, store.$displays, settings.$settings)
            .sink { [weak self] _, _, _ in
                self?.updateStatusItemAppearance()
            }
            .store(in: &cancellables)
    }

    private func observeIconVisibility() {
        store.$displays
            .map(\.isEmpty)
            .removeDuplicates()
            .debounce(for: .seconds(1.5), scheduler: RunLoop.main)
            .sink { [weak self] isEmpty in
                self?.displaysEmptyForIcon = isEmpty
                self?.updateIconVisibility()
            }
            .store(in: &cancellables)

        settings.$settings
            .map(\.hideIconWhenNoDisplays)
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updateIconVisibility()
            }
            .store(in: &cancellables)
    }

    private func updateIconVisibility() {
        let hideBecauseEmpty = displaysEmptyForIcon
            && settings.settings.hideIconWhenNoDisplays
            && !forceIconVisibleThisSession
        let keepVisible = temporarilyVisible
            || popover.isShown
            || (settingsWindowController?.isPresented ?? false)
        statusItem.isVisible = !hideBecauseEmpty || keepVisible
    }

    private func makeSettingsWindowIfNeeded() -> SettingsWindowController {
        if let settingsWindowController {
            return settingsWindowController
        }
        let controller = SettingsWindowController(
            settings: settings,
            displaysProvider: { [weak self] in self?.store.displays ?? [] },
            actions: makeSettingsActions()
        )
        controller.onVisibilityChange = { [weak self] in
            self?.updateIconVisibility()
        }
        settingsWindowController = controller
        return controller
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem.button else { return }
        let average = averageLevel
        let symbolName: String
        if settings.settings.iconReflectsBrightness {
            if average < 34 {
                symbolName = "sun.min"
            } else if average <= 66 {
                symbolName = "sun.max"
            } else {
                symbolName = "sun.max.fill"
            }
        } else {
            symbolName = "sun.max.fill"
        }
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "BrightBar")
        image?.isTemplate = true
        button.image = image

        if settings.settings.showPercentInMenuBar {
            let percent = average.isFinite ? Int(average.rounded()) : 0
            button.title = String(format: "  %d%%", percent)
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    private var averageLevel: Double {
        let values = store.displays.compactMap { store.brightness[$0.id] }
        guard !values.isEmpty else { return 50 }
        return values.reduce(0, +) / Double(values.count)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        let isRightClick = event.type == .rightMouseUp || event.modifierFlags.contains(.control)
        if isRightClick {
            if popover.isShown {
                popover.performClose(nil)
            }
            showContextMenu(from: sender)
        } else {
            togglePopover(relativeTo: sender)
        }
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { return }
        store.refresh()
        keyCoordinator.handlePopoverOpened()
        // Accessory apps need an explicit activate so slider drags reach the popover.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsMenu(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let refreshItem = NSMenuItem(
            title: "Refresh Displays",
            action: #selector(refreshDisplays(_:)),
            keyEquivalent: ""
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        if !settings.settings.presets.isEmpty {
            let presetsMenu = NSMenu()
            for preset in settings.settings.presets {
                let item = NSMenuItem(
                    title: preset.name,
                    action: #selector(applyPresetMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = preset.id.uuidString
                presetsMenu.addItem(item)
            }
            let presetsItem = NSMenuItem(title: "Apply Preset", action: nil, keyEquivalent: "")
            presetsItem.submenu = presetsMenu
            menu.addItem(presetsItem)
        }

        let keysItem = NSMenuItem(
            title: "Use Brightness Keys",
            action: #selector(toggleBrightnessKeys(_:)),
            keyEquivalent: ""
        )
        keysItem.target = self
        keysItem.state = keyCoordinator.brightnessKeysEnabled ? .on : .off
        menu.addItem(keysItem)

        if isRunningFromAppBundle {
            let launchItem = NSMenuItem(
                title: "Launch at Login",
                action: #selector(toggleLaunchAtLogin(_:)),
                keyEquivalent: ""
            )
            launchItem.target = self
            launchItem.state = isLaunchAtLoginEnabled ? .on : .off
            menu.addItem(launchItem)
        }

        let diagnosticsItem = NSMenuItem(
            title: "Copy Diagnostics",
            action: #selector(copyDiagnosticsMenu(_:)),
            keyEquivalent: ""
        )
        diagnosticsItem.target = self
        menu.addItem(diagnosticsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit BrightBar",
            action: #selector(quit(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    }

    @objc private func openSettingsMenu(_ sender: Any?) {
        openSettings()
    }

    @objc private func refreshDisplays(_ sender: Any?) {
        store.refresh()
    }

    @objc private func applyPresetMenu(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let id = UUID(uuidString: idString),
              let preset = settings.settings.presets.first(where: { $0.id == id })
        else { return }
        store.applyPreset(preset)
    }

    @objc private func toggleBrightnessKeys(_ sender: Any?) {
        keyCoordinator.setBrightnessKeysEnabled(!keyCoordinator.brightnessKeysEnabled)
    }

    @objc private func toggleLaunchAtLogin(_ sender: Any?) {
        setLaunchAtLogin(!isLaunchAtLoginEnabled)
    }

    @objc private func copyDiagnosticsMenu(_ sender: Any?) {
        copyDiagnostics()
    }

    /// `SMAppService.mainApp` only works for a real `.app` bundle, not `swift run` / a bare binary.
    private var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    private var isLaunchAtLoginEnabled: Bool {
        guard isRunningFromAppBundle else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard isRunningFromAppBundle else {
            NSLog("BrightBar: Launch at Login is only available when running from BrightBar.app")
            return
        }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("BrightBar: Launch at Login failed: %@", error.localizedDescription)
        }
    }

    func copyDiagnostics() {
        DispatchQueue.global(qos: .userInitiated).async {
            let report = DDCProbe.report()
            Task { @MainActor in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
            }
        }
    }

    private func makeSettingsActions() -> SettingsActions {
        SettingsActions(
            isLaunchAtLoginEnabled: { [weak self] in
                self?.isLaunchAtLoginEnabled ?? false
            },
            setLaunchAtLogin: { [weak self] enabled in
                self?.setLaunchAtLogin(enabled)
            },
            isAccessibilityTrusted: {
                AccessibilityPermission.isTrusted
            },
            requestAccessibility: {
                AccessibilityPermission.requestPrompt()
                if !AccessibilityPermission.isTrusted {
                    AccessibilityPermission.openSystemSettings()
                }
            },
            applyPreset: { [weak self] preset in
                self?.store.applyPreset(preset)
            },
            previewBrightness: { [weak self] display, level in
                self?.store.setLevel(level, for: display, source: .user)
            },
            copyDiagnostics: { [weak self] in
                self?.copyDiagnostics()
            },
            refreshDisplays: { [weak self] in
                self?.store.refresh()
            }
        )
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func scheduleHideAfterTemporaryReveal() {
        hideAfterRevealWorkItem?.cancel()
        guard temporarilyVisible else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.temporarilyVisible = false
            self.updateIconVisibility()
        }
        hideAfterRevealWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + temporaryRevealDuration, execute: work)
    }
}

extension StatusBarController: NSPopoverDelegate {
    func popoverDidShow(_ notification: Notification) {
        hideAfterRevealWorkItem?.cancel()
        hideAfterRevealWorkItem = nil
        updateIconVisibility()
    }

    func popoverDidClose(_ notification: Notification) {
        updateIconVisibility()
        scheduleHideAfterTemporaryReveal()
    }
}
