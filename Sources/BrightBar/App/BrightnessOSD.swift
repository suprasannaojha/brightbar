import AppKit
import Darwin
import ObjectiveC
import os

/// Native macOS brightness bezel, shown on a specific display via private `OSDManager`.
///
/// Loads `/System/Library/PrivateFrameworks/OSDUIHelper.framework` (and the
/// `OSD.framework` stub that actually ships today) with `Bundle.load` / `dlopen`.
/// Every lookup is guarded; failures are logged once and then skipped.
enum BrightnessOSD {
    private static let logger = Logger(subsystem: "com.brightbar.app", category: "osd")
    private static var didLogFailure = false
    private static var cache: Cache?

    private struct Cache {
        let manager: AnyObject
        let selector: Selector
        let show: ShowImageFn
    }

    /// `-[OSDManager showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:]`
    private typealias ShowImageFn = @convention(c) (
        AnyObject,
        Selector,
        Int64,
        CGDirectDisplayID,
        UInt32,
        UInt32,
        UInt32,
        UInt32,
        Bool
    ) -> Void

    static func showBrightness(on displayID: CGDirectDisplayID, value: Double) {
        guard let cache = loadIfNeeded() else { return }

        let filled: UInt32
        if value < 0 {
            filled = 0
        } else {
            filled = UInt32((max(0, value) / 100.0 * 16.0).rounded())
        }

        cache.show(
            cache.manager,
            cache.selector,
            1, // OSDGraphicBacklight
            displayID,
            0x1F4,
            1000,
            filled,
            16,
            false
        )
    }

    private static func loadIfNeeded() -> Cache? {
        if let cache { return cache }

        if NSClassFromString("OSDManager") == nil {
            loadFramework()
        }

        guard let cls = NSClassFromString("OSDManager") as? NSObject.Type else {
            logFailure("OSDManager class not found")
            return nil
        }

        let sharedSel = NSSelectorFromString("sharedManager")
        guard cls.responds(to: sharedSel),
              let manager = cls.perform(sharedSel)?.takeUnretainedValue() as? NSObject
        else {
            logFailure("OSDManager.sharedManager is unavailable")
            return nil
        }

        let selector = NSSelectorFromString(
            "showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:"
        )
        guard manager.responds(to: selector) else {
            logFailure("OSDManager showImage:onDisplayID:… selector is unavailable")
            return nil
        }
        let imp = manager.method(for: selector)

        let show = unsafeBitCast(imp, to: ShowImageFn.self)
        let loaded = Cache(manager: manager, selector: selector, show: show)
        cache = loaded
        return loaded
    }

    private static func loadFramework() {
        let paths = [
            "/System/Library/PrivateFrameworks/OSDUIHelper.framework",
            "/System/Library/PrivateFrameworks/OSD.framework",
        ]
        for path in paths {
            if let bundle = Bundle(path: path), bundle.load() {
                return
            }
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            if dlopen("\(path)/\(name)", RTLD_LAZY) != nil {
                return
            }
        }
    }

    private static func logFailure(_ message: String) {
        guard !didLogFailure else { return }
        didLogFailure = true
        logger.error("\(message, privacy: .public)")
    }
}
