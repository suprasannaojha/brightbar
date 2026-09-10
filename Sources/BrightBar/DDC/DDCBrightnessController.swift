import CoreGraphics
import Darwin
import Foundation
import os

/// How BrightBar is talking to a given external display.
enum DisplayControlBackend: Equatable {
    case ioAVService
    case ioFramebuffer
    case displayServices

    var probeName: String {
        switch self {
        case .ioAVService: return "IOAVService"
        case .ioFramebuffer: return "IOFramebuffer"
        case .displayServices: return "DisplayServices"
        }
    }
}

/// Composite brightness controller: DDC over IOAVService (Apple Silicon),
/// DDC over IOFramebuffer I2C (Intel, experimental), and DisplayServices for
/// Apple / LG UltraFine panels that have no DDC.
final class DDCBrightnessController: BrightnessController {
    private let logger = Logger(subsystem: "com.brightbar.app", category: "ddc")
    private let i2cQueue = DispatchQueue(label: "com.brightbar.app.ddc")
    private let probeGapUs: useconds_t = 20_000

    private enum Handle {
        case ioAVService(RetainedIOAVService)
        case ioFramebuffer(RetainedIOObject)
        case displayServices
    }

    private var handles: [CGDirectDisplayID: Handle] = [:]
    /// Per-(display, VCP code) native max, so percent writes can skip a read.
    private var lastMax: [CGDirectDisplayID: [UInt8: UInt16]] = [:]

    init() {}

    func refreshDisplays() -> [ExternalDisplay] {
        i2cQueue.sync {
            rebuildLocked()
        }
    }

    func readBrightness(for display: ExternalDisplay) -> Int? {
        i2cQueue.sync {
            readBrightnessLocked(display)
        }
    }

    @discardableResult
    func setBrightness(_ value: Int, for display: ExternalDisplay) -> Bool {
        i2cQueue.sync {
            setBrightnessLocked(value, for: display)
        }
    }

    func readVCP(_ code: VCPCode, for display: ExternalDisplay) -> (current: UInt16, max: UInt16)? {
        i2cQueue.sync {
            readVCPLocked(code, for: display)
        }
    }

    @discardableResult
    func writeVCP(_ code: VCPCode, value: UInt16, for display: ExternalDisplay) -> Bool {
        i2cQueue.sync {
            writeVCPLocked(code, value: value, for: display)
        }
    }

    func backend(for display: ExternalDisplay) -> DisplayControlBackend? {
        i2cQueue.sync {
            backendKindLocked(display.id)
        }
    }

    // MARK: - Locked implementations (always called on `i2cQueue`)

    private func rebuildLocked() -> [ExternalDisplay] {
        var nextHandles: [CGDirectDisplayID: Handle] = [:]
        var displays: [ExternalDisplay] = []
        var used = Set<CGDirectDisplayID>()

        let avMatches = DisplayMatcher.matchExternalDisplays().filter {
            CGDisplayIsBuiltin($0.display.id) == 0
        }
        for match in avMatches {
            let id = match.display.id
            var handle = Handle.ioAVService(match.service)
            let capabilities = probeCapabilitiesLocked(id: id, handle: handle)
            if !capabilities.supportsDDC && capabilities.supportsNativeBrightness {
                logger.info("Display \(id) has an AV service but no DDC; using DisplayServices")
                handle = .displayServices
            }
            let display = ExternalDisplay(
                id: id,
                name: match.display.name,
                identity: match.display.identity,
                capabilities: capabilities
            )
            nextHandles[id] = handle
            displays.append(display)
            used.insert(id)
        }

        if IOFramebufferDDC.shouldUse {
            let fbMatches = IOFramebufferDDC.matchExternalDisplays(excluding: used)
            for match in fbMatches {
                let id = match.displayID
                var handle = Handle.ioFramebuffer(match.framebuffer)
                let capabilities = probeCapabilitiesLocked(id: id, handle: handle)
                if !capabilities.supportsDDC && capabilities.supportsNativeBrightness {
                    logger.info("Display \(id) has IOFramebuffer I2C but no DDC; using DisplayServices")
                    handle = .displayServices
                } else if !capabilities.supportsDDC && !capabilities.supportsNativeBrightness {
                    logger.info("Skipping IOFramebuffer display \(id): no DDC and no native brightness")
                    continue
                }
                let display = ExternalDisplay(
                    id: id,
                    name: match.name,
                    identity: match.identity,
                    capabilities: capabilities
                )
                nextHandles[id] = handle
                displays.append(display)
                used.insert(id)
            }
        }

        for id in DisplayMatcher.onlineExternalDisplayIDs() where !used.contains(id) {
            guard CGDisplayIsBuiltin(id) == 0 else { continue }
            guard DisplayServicesBridge.canControl(id) else { continue }
            let name = DisplayMatcher.displayName(productName: nil, id: id)
            let identity = DisplayMatcher.identityFromCGDisplay(id)
            let capabilities = DisplayCapabilities(
                supportsDDC: false,
                supportsNativeBrightness: true,
                supportsAudio: false,
                supportsContrast: false
            )
            let display = ExternalDisplay(
                id: id,
                name: name,
                identity: identity,
                capabilities: capabilities
            )
            nextHandles[id] = .displayServices
            displays.append(display)
            logger.info("Added native-brightness display \(id) (\(name, privacy: .public))")
        }

        handles = nextHandles
        lastMax = lastMax.filter { nextHandles[$0.key] != nil }
        return displays.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func probeCapabilitiesLocked(id: CGDirectDisplayID, handle: Handle) -> DisplayCapabilities {
        var caps = DisplayCapabilities()
        caps.supportsNativeBrightness = DisplayServicesBridge.canControl(id)
        switch handle {
        case .displayServices:
            return caps
        case .ioAVService, .ioFramebuffer:
            break
        }

        let brightness = readRawVCPLocked(handle: handle, code: VCPCode.brightness.rawValue)
        usleep(probeGapUs)
        let contrast = readRawVCPLocked(handle: handle, code: VCPCode.contrast.rawValue)
        usleep(probeGapUs)
        let volume = readRawVCPLocked(handle: handle, code: VCPCode.volume.rawValue)

        if let brightness {
            cacheMaxLocked(id: id, code: VCPCode.brightness.rawValue, max: brightness.max)
        }
        if let contrast {
            cacheMaxLocked(id: id, code: VCPCode.contrast.rawValue, max: contrast.max)
        }
        if let volume {
            cacheMaxLocked(id: id, code: VCPCode.volume.rawValue, max: volume.max)
        }

        caps.supportsDDC = brightness != nil || contrast != nil || volume != nil
        caps.supportsContrast = contrast != nil
        caps.supportsAudio = volume != nil
        return caps
    }

    private func readBrightnessLocked(_ display: ExternalDisplay) -> Int? {
        guard let handle = liveHandleLocked(display) else { return nil }
        switch handle {
        case .displayServices:
            return nativeBrightnessPercent(of: display.id)
        case .ioAVService, .ioFramebuffer:
            if let result = readRawVCPLocked(handle: handle, code: VCPCode.brightness.rawValue) {
                cacheMaxLocked(id: display.id, code: VCPCode.brightness.rawValue, max: result.max)
                return DDC.scaleToPercent(current: result.current, nativeMax: result.max)
            }
            if DisplayServicesBridge.canControl(display.id) {
                return nativeBrightnessPercent(of: display.id)
            }
            logger.error("Brightness read failed for \(display.name, privacy: .public)")
            return nil
        }
    }

    private func setBrightnessLocked(_ value: Int, for display: ExternalDisplay) -> Bool {
        let clamped = min(100, max(0, value))
        guard let handle = liveHandleLocked(display) else { return false }
        switch handle {
        case .displayServices:
            return setNativeBrightness(clamped, of: display.id)
        case .ioAVService, .ioFramebuffer:
            let nativeMax = resolvedMaxLocked(display: display, handle: handle, code: VCPCode.brightness)
            let native = DDC.nativeValue(percent: clamped, nativeMax: nativeMax)
            let ok = writeRawVCPLocked(handle: handle, code: VCPCode.brightness.rawValue, value: native)
            if !ok {
                if DisplayServicesBridge.canControl(display.id) {
                    return setNativeBrightness(clamped, of: display.id)
                }
                logger.error("Brightness write \(clamped)% failed for \(display.name, privacy: .public)")
            }
            return ok
        }
    }

    private func readVCPLocked(_ code: VCPCode, for display: ExternalDisplay) -> (current: UInt16, max: UInt16)? {
        guard let handle = liveHandleLocked(display) else { return nil }
        switch handle {
        case .displayServices:
            return nil
        case .ioAVService, .ioFramebuffer:
            guard let result = readRawVCPLocked(handle: handle, code: code.rawValue) else {
                return nil
            }
            cacheMaxLocked(id: display.id, code: code.rawValue, max: result.max)
            return result
        }
    }

    private func writeVCPLocked(_ code: VCPCode, value: UInt16, for display: ExternalDisplay) -> Bool {
        guard let handle = liveHandleLocked(display) else { return false }
        switch handle {
        case .displayServices:
            return false
        case .ioAVService, .ioFramebuffer:
            return writeRawVCPLocked(handle: handle, code: code.rawValue, value: value)
        }
    }

    private func readRawVCPLocked(handle: Handle, code: UInt8) -> (current: UInt16, max: UInt16)? {
        switch handle {
        case .ioAVService(let service):
            return withExtendedLifetime(service) {
                DDC.readVCP(service: service.raw, code: code)
            }
        case .ioFramebuffer(let framebuffer):
            return withExtendedLifetime(framebuffer) {
                IOFramebufferDDC.readVCP(framebuffer: framebuffer.raw, code: code)
            }
        case .displayServices:
            return nil
        }
    }

    private func writeRawVCPLocked(handle: Handle, code: UInt8, value: UInt16) -> Bool {
        switch handle {
        case .ioAVService(let service):
            return withExtendedLifetime(service) {
                DDC.writeVCP(service: service.raw, code: code, value: value)
            }
        case .ioFramebuffer(let framebuffer):
            return withExtendedLifetime(framebuffer) {
                IOFramebufferDDC.writeVCP(framebuffer: framebuffer.raw, code: code, value: value)
            }
        case .displayServices:
            return false
        }
    }

    private func liveHandleLocked(_ display: ExternalDisplay) -> Handle? {
        guard let handle = handles[display.id] else {
            logger.error("No control backend cached for display \(display.id) (\(display.name, privacy: .public))")
            return nil
        }
        let stillExternal = CGDisplayIsOnline(display.id) != 0 && CGDisplayIsBuiltin(display.id) == 0
        guard stillExternal else {
            logger.info("Display \(display.id) is gone or is built-in; dropping cached backend")
            handles[display.id] = nil
            lastMax[display.id] = nil
            return nil
        }
        return handle
    }

    private func resolvedMaxLocked(display: ExternalDisplay, handle: Handle, code: VCPCode) -> UInt16 {
        if let cached = lastMax[display.id]?[code.rawValue] { return cached }
        if let result = readRawVCPLocked(handle: handle, code: code.rawValue) {
            cacheMaxLocked(id: display.id, code: code.rawValue, max: result.max)
            return result.max
        }
        logger.info("Assuming DDC max=100 for \(display.name, privacy: .public) VCP 0x\(String(code.rawValue, radix: 16), privacy: .public) after a failed read")
        cacheMaxLocked(id: display.id, code: code.rawValue, max: 100)
        return 100
    }

    private func cacheMaxLocked(id: CGDirectDisplayID, code: UInt8, max: UInt16) {
        var byCode = lastMax[id] ?? [:]
        byCode[code] = max
        lastMax[id] = byCode
    }

    private func backendKindLocked(_ id: CGDirectDisplayID) -> DisplayControlBackend? {
        switch handles[id] {
        case .ioAVService: return .ioAVService
        case .ioFramebuffer: return .ioFramebuffer
        case .displayServices: return .displayServices
        case nil: return nil
        }
    }

    private func nativeBrightnessPercent(of id: CGDirectDisplayID) -> Int? {
        guard let value = DisplayServicesBridge.brightness(of: id) else { return nil }
        return Int((Double(value) * 100.0).rounded())
    }

    private func setNativeBrightness(_ percent: Int, of id: CGDirectDisplayID) -> Bool {
        let clamped = min(100, max(0, percent))
        return DisplayServicesBridge.setBrightness(Float(clamped) / 100.0, of: id)
    }
}
