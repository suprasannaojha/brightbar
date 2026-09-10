import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let store: BrightnessStore
    private let keyCoordinator: BrightnessKeyCoordinator
    private let popover = NSPopover()
    private let statusItem: NSStatusItem

    init(controller: BrightnessController) {
        let store = BrightnessStore(controller: controller)
        self.store = store
        self.keyCoordinator = BrightnessKeyCoordinator(store: store)
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configurePopover()
        configureStatusItem()
    }

    func shutdown() {
        keyCoordinator.shutdown()
        store.shutdown()
    }

    private func configurePopover() {
        let hostingController = NSHostingController(
            rootView: PopoverView(store: store, keyCoordinator: keyCoordinator)
        )
        // NSPopover sizes itself from `preferredContentSize`, not the view's intrinsic size.
        // Publishing both keeps the popover hugging the SwiftUI content as rows come and go.
        hostingController.sizingOptions = [.intrinsicContentSize, .preferredContentSize]
        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.animates = true
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: "BrightBar")
        image?.isTemplate = true
        button.image = image
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        // Default is left-click only; include right-click so we can show the context menu.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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
            store.refresh()
            keyCoordinator.handlePopoverOpened()
            // Accessory apps need an explicit activate so slider drags reach the popover.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let refreshItem = NSMenuItem(
            title: "Refresh Displays",
            action: #selector(refreshDisplays(_:)),
            keyEquivalent: ""
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        let keysItem = NSMenuItem(
            title: "Use Brightness Keys",
            action: #selector(toggleBrightnessKeys(_:)),
            keyEquivalent: ""
        )
        keysItem.target = self
        keysItem.state = keyCoordinator.brightnessKeysEnabled ? .on : .off
        menu.addItem(keysItem)

        if #available(macOS 13.0, *), isRunningFromAppBundle {
            let launchItem = NSMenuItem(
                title: "Launch at Login",
                action: #selector(toggleLaunchAtLogin(_:)),
                keyEquivalent: ""
            )
            launchItem.target = self
            launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(launchItem)
        }

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

    @objc private func refreshDisplays(_ sender: Any?) {
        store.refresh()
    }

    @objc private func toggleBrightnessKeys(_ sender: Any?) {
        keyCoordinator.setEnabled(!keyCoordinator.brightnessKeysEnabled)
    }

    @objc private func toggleLaunchAtLogin(_ sender: Any?) {
        if #available(macOS 13.0, *) {
            guard isRunningFromAppBundle else {
                NSLog("BrightBar: Launch at Login is only available when running from BrightBar.app")
                return
            }
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                NSLog("BrightBar: Launch at Login failed: %@", error.localizedDescription)
            }
        }
    }

    /// `SMAppService.mainApp` only works for a real `.app` bundle, not `swift run` / a bare binary.
    private var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}
