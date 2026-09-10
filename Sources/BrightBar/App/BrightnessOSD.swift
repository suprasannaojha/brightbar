import AppKit
import Darwin
import ObjectiveC
import os

/// Native macOS brightness/volume bezel, shown on a specific display via private `OSDManager`.
///
/// Loads `/System/Library/PrivateFrameworks/OSDUIHelper.framework` (and the
/// `OSD.framework` stub that actually ships today) with `Bundle.load` / `dlopen`.
/// Every lookup is guarded; failures are logged once and then skipped.
///
/// Image ids match MonitorControl's `OSDImage`: brightness = 1, speaker = 3, speakerMuted = 4.
@MainActor
enum BrightnessOSD {
    private static let logger = Logger(subsystem: "com.brightbar.app", category: "input")
    private static var didLogFailure = false
    private static var cache: Cache?

    /// MonitorControl `OSDImage` raw values.
    private enum Image {
        static let brightness: Int64 = 1 // OSDGraphicBacklight
        static let speaker: Int64 = 3 // OSDGraphicSpeaker
        static let speakerMuted: Int64 = 4 // OSDGraphicSpeakerMuted
    }

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
        let filled: UInt32
        if value < 0 {
            filled = 0
        } else {
            filled = chicletCount(value)
        }
        show(image: Image.brightness, on: displayID, filled: filled)
    }

    static func showVolume(on displayID: CGDirectDisplayID, value: Double, muted: Bool) {
        let filled = muted ? 0 : chicletCount(value)
        show(image: muted ? Image.speakerMuted : Image.speaker, on: displayID, filled: filled)
    }

    private static func chicletCount(_ value: Double) -> UInt32 {
        UInt32((max(0, min(100, value)) / 100.0 * 16.0).rounded())
    }

    private static func show(image: Int64, on displayID: CGDirectDisplayID, filled: UInt32) {
        guard let cache = loadIfNeeded() else { return }

        cache.show(
            cache.manager,
            cache.selector,
            image,
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
