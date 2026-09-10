import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var automationEngine: AutomationEngine?
    private var commandServer: RemoteCommandServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller: BrightnessController = DDCBrightnessController()
        let settings = SettingsStore.shared
        let statusBar = StatusBarController(controller: controller, settings: settings)
        statusBarController = statusBar

        let store = statusBar.store
        let engine = AutomationEngine(target: store, settings: settings)
        store.automation = engine
        engine.start()
        automationEngine = engine

        let server = RemoteCommandServer { command in
            await store.handle(command)
        }
        server.start()
        commandServer = server
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let store = statusBarController?.store else { return }
        for url in urls {
            guard let command = URLCommands.parse(url) else { continue }
            Task { @MainActor in
                _ = await store.handle(command)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        automationEngine?.stop()
        commandServer?.stop()
        statusBarController?.shutdown()
    }
}
