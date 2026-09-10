import CoreGraphics
import Foundation
import os

/// DDC/CI brightness controller for Apple Silicon external displays.
final class DDCBrightnessController: BrightnessController {
    private let logger = Logger(subsystem: "com.brightbar.app", category: "ddc")
    private let i2cQueue = DispatchQueue(label: "com.brightbar.app.ddc")

    private var services: [CGDirectDisplayID: RetainedIOAVService] = [:]
    private var lastMax: [CGDirectDisplayID: UInt16] = [:]

    init() {}

    func refreshDisplays() -> [ExternalDisplay] {
        i2cQueue.sync {
            rebuildLocked()
        }
    }

    func readBrightness(for display: ExternalDisplay) -> Int? {
        i2cQueue.sync {
            readLocked(display)
        }
    }

    @discardableResult
    func setBrightness(_ value: Int, for display: ExternalDisplay) -> Bool {
        i2cQueue.sync {
            setLocked(value, for: display)
        }
    }

    // MARK: - Locked implementations (always called on `i2cQueue`)

    private func rebuildLocked() -> [ExternalDisplay] {
        let matches = DisplayMatcher.matchExternalDisplays().filter {
            CGDisplayIsBuiltin($0.display.id) == 0
        }
        var next: [CGDirectDisplayID: RetainedIOAVService] = [:]
        for match in matches {
            next[match.display.id] = match.service
        }
        services = next
        lastMax = lastMax.filter { next[$0.key] != nil }
        return matches.map(\.display).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func readLocked(_ display: ExternalDisplay) -> Int? {
        guard let service = liveServiceLocked(display) else { return nil }
        return withExtendedLifetime(service) {
            guard let result = DDC.readBrightness(service: service.raw) else {
                logger.error("Brightness read failed for \(display.name, privacy: .public)")
                return nil
            }
            lastMax[display.id] = result.max
            return DDC.scaleToPercent(current: result.current, nativeMax: result.max)
        }
    }

    private func setLocked(_ value: Int, for display: ExternalDisplay) -> Bool {
        let clamped = min(100, max(0, value))
        guard let service = liveServiceLocked(display) else { return false }
        return withExtendedLifetime(service) {
            let nativeMax = resolvedMaxLocked(display: display, service: service.raw)
            let native = DDC.nativeValue(percent: clamped, nativeMax: nativeMax)
            let ok = DDC.writeBrightness(service: service.raw, native: native)
            if !ok {
                logger.error("Brightness write \(clamped)% failed for \(display.name, privacy: .public)")
            }
            return ok
        }
    }

    /// Cached `IOAVService` objects become invalid when the display is unplugged.
    /// Skip I2C (return nil/false) instead of talking to a stale service.
    private func liveServiceLocked(_ display: ExternalDisplay) -> RetainedIOAVService? {
        guard let service = services[display.id] else {
            logger.error("No AV service cached for display \(display.id) (\(display.name, privacy: .public))")
            return nil
        }
        let stillExternal = CGDisplayIsOnline(display.id) != 0 && CGDisplayIsBuiltin(display.id) == 0
        guard stillExternal else {
            logger.info("Display \(display.id) is gone or is built-in; dropping cached AV service")
            services[display.id] = nil
            lastMax[display.id] = nil
            return nil
        }
        return service
    }

    private func resolvedMaxLocked(display: ExternalDisplay, service: IOAVService) -> UInt16 {
        if let cached = lastMax[display.id] { return cached }
        if let result = DDC.readBrightness(service: service) {
            lastMax[display.id] = result.max
            return result.max
        }
        logger.info("Assuming DDC max=100 for \(display.name, privacy: .public) after a failed read")
        lastMax[display.id] = 100
        return 100
    }
}
