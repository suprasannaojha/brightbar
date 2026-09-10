import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller: BrightnessController = DDCBrightnessController()
        statusBarController = StatusBarController(controller: controller)
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBarController?.shutdown()
    }
}
