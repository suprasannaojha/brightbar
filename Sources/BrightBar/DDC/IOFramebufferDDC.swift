// Experimental: untested on real hardware
//
// Classic Intel-Mac DDC/CI path using IOFramebuffer I2C
// (`IOFBCopyI2CInterfaceForBus` / `IOI2CInterfaceOpen` / `IOI2CSendRequest`
// with `kIOI2CDDCciReplyTransactionType`), as in ddcctl / MonitorControl.
//
// Displays are matched by iterating `IODisplayConnect` services and
// comparing `IODisplayCreateInfoDictionary` vendor / product / serial to the
// CoreGraphics display — `CGDisplayIOServicePort` is a no-op on modern macOS.
//
// Selected at runtime only when no `DCPAVServiceProxy` nodes exist in the
// IORegistry *and* at least one IOFramebuffer I2C interface is present.
// `#if arch(x86_64)` is not sufficient: the IOAVService symbols exist on both
// architectures. Apple Silicon with a DCP-attached panel always has
// DCPAVServiceProxy, so this path stays idle there.

import CoreGraphics
import Darwin
import Foundation
import IOKit
import IOKit.graphics
import IOKit.i2c
import os

/// Owns a retained `io_object_t` and releases it on deinit.
final class RetainedIOObject {
    let raw: io_object_t

    init?(consuming object: io_object_t) {
        guard object != 0 else { return nil }
        self.raw = object
    }

    deinit {
        if raw != 0 {
            IOObjectRelease(raw)
        }
    }
}

/// DDC/CI over IOFramebuffer I2C (Intel / pre-DCP). Experimental.
enum IOFramebufferDDC {
    private static let logger = Logger(subsystem: "com.brightbar.app", category: "ddc-intel")
    private static let i2cLock = NSLock()

    private static let writeAttempts = 3
    private static let readAttempts = 5
    private static let interWriteSleepUs: useconds_t = 10_000
    private static let retrySleepUs: useconds_t = 20_000
    /// 40 ms, expressed in nanoseconds (common IOI2C interpretation of minReplyDelay).
    private static let minReplyDelayNs: UInt64 = 40_000_000

    private static let ddcDestination: UInt32 = 0x6E
    private static let ddcReplyAddress: UInt32 = 0x6F

    struct Match {
        let displayID: CGDirectDisplayID
        let name: String
        let identity: DisplayIdentity
        let framebuffer: RetainedIOObject
    }

    /// True when this Mac should talk DDC through IOFramebuffer rather than IOAVService.
    static var shouldUse: Bool {
        !hasDCPAVServiceProxy && hasI2CInterfaces
    }

    static var hasDCPAVServiceProxy: Bool {
        hasAnyService(matching: "DCPAVServiceProxy")
    }

    static var hasI2CInterfaces: Bool {
        if hasAnyService(matching: "IOFramebufferI2CInterface") {
            return true
        }
        return anyFramebufferHasI2C()
    }

    static func matchExternalDisplays(excluding used: Set<CGDirectDisplayID>) -> [Match] {
        guard shouldUse else { return [] }

        let cgDisplays = DisplayMatcher.onlineExternalDisplayIDs().filter { id in
            CGDisplayIsBuiltin(id) == 0 && !used.contains(id)
        }
        guard !cgDisplays.isEmpty else { return [] }

        let candidates = collectFramebufferCandidates()
        if candidates.isEmpty {
            logger.info("IOFramebuffer DDC: no IODisplayConnect services with I2C")
            return []
        }

        var usedService = Set<Int>()
        var usedIDs = used
        var matches: [Match] = []

        var scored: [(score: Int, serviceIndex: Int, displayID: CGDirectDisplayID)] = []
        for (index, candidate) in candidates.enumerated() {
            for id in cgDisplays where !usedIDs.contains(id) {
                let score = matchScore(candidate: candidate, displayID: id)
                if score > 0 {
                    scored.append((score, index, id))
                }
            }
        }
        scored.sort { $0.score > $1.score }

        for item in scored {
            if usedService.contains(item.serviceIndex) { continue }
            if usedIDs.contains(item.displayID) { continue }
            guard let match = makeMatch(candidate: candidates[item.serviceIndex], displayID: item.displayID) else {
                continue
            }
            usedService.insert(item.serviceIndex)
            usedIDs.insert(item.displayID)
            matches.append(match)
        }

        if matches.isEmpty, candidates.count == 1, cgDisplays.count == 1,
           let match = makeMatch(candidate: candidates[0], displayID: cgDisplays[0]) {
            logger.info("IOFramebuffer DDC: 1:1 fallback for a single external display")
            return [match]
        }

        // Claimed framebuffers live in `RetainedIOObject`; release the rest.
        for (index, candidate) in candidates.enumerated() where !usedService.contains(index) {
            IOObjectRelease(candidate.framebuffer)
        }

        return matches
    }

    static func readVCP(framebuffer: io_service_t, code: UInt8) -> (current: UInt16, max: UInt16)? {
        i2cLock.lock()
        defer { i2cLock.unlock() }
        for attempt in 0..<readAttempts {
            if let result = readVCPOnce(framebuffer: framebuffer, code: code) {
                return result
            }
            usleep(retrySleepUs)
            logger.debug("IOFramebuffer DDC VCP 0x\(String(code, radix: 16), privacy: .public) read retry \(attempt + 1)")
        }
        logger.error("IOFramebuffer DDC VCP 0x\(String(code, radix: 16), privacy: .public) read failed after \(self.readAttempts) attempts")
        return nil
    }

    @discardableResult
    static func writeVCP(framebuffer: io_service_t, code: UInt8, value: UInt16) -> Bool {
        i2cLock.lock()
        defer { i2cLock.unlock() }
        let packet = writePacket(vcp: code, value: value)
        var lastOK = false
        for _ in 0..<writeAttempts {
            usleep(interWriteSleepUs)
            let kr = sendWrite(framebuffer: framebuffer, packet: packet)
            lastOK = (kr == kIOReturnSuccess)
            if !lastOK {
                logger.debug("IOFramebuffer DDC write VCP 0x\(String(code, radix: 16), privacy: .public) IOReturn 0x\(String(UInt32(bitPattern: kr), radix: 16), privacy: .public)")
                if DDC.shouldStopRetrying(kr) {
                    break
                }
            }
        }
        if !lastOK {
            logger.error("IOFramebuffer DDC write VCP 0x\(String(code, radix: 16), privacy: .public) failed")
        }
        return lastOK
    }

    // MARK: - Registry matching

    private struct FBCandidate {
        let framebuffer: io_service_t
        var vendor: UInt32 = 0
        var product: UInt32 = 0
        var serial: UInt32 = 0
        var alphanumericSerial: String = ""
        var productName: String = ""
        var unitNumber: UInt32?
    }

    private static func collectFramebufferCandidates() -> [FBCandidate] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iterator
        ) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var candidates: [FBCandidate] = []
        var connect = IOIteratorNext(iterator)
        while connect != 0 {
            defer {
                IOObjectRelease(connect)
                connect = IOIteratorNext(iterator)
            }

            guard let framebuffer = framebufferWithI2C(startingFrom: connect) else { continue }
            var candidate = FBCandidate(framebuffer: framebuffer)
            let dict = infoDictionary(for: framebuffer) ?? infoDictionary(for: connect)
            if let dict {
                applyInfoDictionary(dict, to: &candidate)
            }
            candidates.append(candidate)
        }
        return candidates
    }

    private static func framebufferWithI2C(startingFrom service: io_service_t) -> io_service_t? {
        var current = service
        var ownsCurrent = false
        for _ in 0..<10 {
            if hasI2C(current) {
                if !ownsCurrent {
                    let kr = IOObjectRetain(current)
                    if kr != KERN_SUCCESS {
                        return nil
                    }
                }
                return current
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 else {
                break
            }
            if ownsCurrent { IOObjectRelease(current) }
            current = parent
            ownsCurrent = true
        }
        if ownsCurrent { IOObjectRelease(current) }
        return nil
    }

    private static func hasI2C(_ framebuffer: io_service_t) -> Bool {
        var count: IOItemCount = 0
        let kr = IOFBGetI2CInterfaceCount(framebuffer, &count)
        return kr == kIOReturnSuccess && count > 0
    }

    private static func anyFramebufferHasI2C() -> Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOFramebuffer"),
            &iterator
        ) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            if hasI2C(service) { return true }
        }
        return false
    }

    private static func hasAnyService(matching className: String) -> Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching(className),
            &iterator
        ) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }
        let entry = IOIteratorNext(iterator)
        if entry != 0 {
            IOObjectRelease(entry)
            return true
        }
        return false
    }

    private static func infoDictionary(for service: io_service_t) -> NSDictionary? {
        let unmanaged = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))
        guard let unmanaged else { return nil }
        return unmanaged.takeRetainedValue() as NSDictionary
    }

    private static func applyInfoDictionary(_ dict: NSDictionary, to candidate: inout FBCandidate) {
        candidate.vendor = u32(dict[kDisplayVendorID]) ?? 0
        candidate.product = u32(dict[kDisplayProductID]) ?? 0
        candidate.serial = u32(dict[kDisplaySerialNumber]) ?? 0
        if let serial = dict["AlphanumericSerialNumber"] as? String {
            candidate.alphanumericSerial = serial
        } else if let serial = dict["DisplaySerialString"] as? String {
            candidate.alphanumericSerial = serial
        }
        candidate.productName = productName(from: dict)
        if let location = dict[kIODisplayLocationKey] as? String {
            candidate.unitNumber = unitNumber(from: location)
        }
    }

    private static func productName(from dict: NSDictionary) -> String {
        if let name = dict[kDisplayProductName] as? String, !name.isEmpty {
            return name
        }
        if let names = dict[kDisplayProductName] as? [String: String] {
            if let preferred = names["en_US"] ?? names.values.first, !preferred.isEmpty {
                return preferred
            }
        }
        if let names = dict[kDisplayProductName] as? NSDictionary {
            for key in ["en_US", "en"] {
                if let name = names[key] as? String, !name.isEmpty { return name }
            }
            if let name = names.allValues.first as? String, !name.isEmpty {
                return name
            }
        }
        return ""
    }

    private static func unitNumber(from location: String) -> UInt32? {
        guard let regex = try? NSRegularExpression(pattern: #"@([0-9]+)[^@]*$"#) else { return nil }
        let ns = location as NSString
        guard let match = regex.firstMatch(in: location, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else {
            return nil
        }
        let token = ns.substring(with: match.range(at: 1))
        return UInt32(token)
    }

    private static func matchScore(candidate: FBCandidate, displayID: CGDirectDisplayID) -> Int {
        let vendor = CGDisplayVendorNumber(displayID)
        let product = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        var score = 0
        if candidate.vendor != 0, candidate.vendor == vendor { score += 4 }
        if candidate.product != 0, candidate.product == product { score += 4 }
        if candidate.serial != 0, candidate.serial == serial { score += 5 }
        if let unit = candidate.unitNumber, unit == CGDisplayUnitNumber(displayID) {
            score += 2
        }
        return score
    }

    private static func makeMatch(candidate: FBCandidate, displayID: CGDirectDisplayID) -> Match? {
        guard CGDisplayIsBuiltin(displayID) == 0 else { return nil }
        guard let retained = RetainedIOObject(consuming: candidate.framebuffer) else { return nil }
        let alpha = candidate.alphanumericSerial.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = DisplayMatcher.identityFromCGDisplay(
            displayID,
            alphanumericSerial: alpha.isEmpty ? nil : alpha
        )
        let name = DisplayMatcher.displayName(productName: candidate.productName, id: displayID)
        return Match(displayID: displayID, name: name, identity: identity, framebuffer: retained)
    }

    private static func u32(_ value: Any?) -> UInt32? {
        switch value {
        case let v as UInt32: return v
        case let v as Int where v >= 0 && v <= Int(UInt32.max): return UInt32(v)
        case let v as Int64:
            guard v >= 0, v <= Int64(UInt32.max) else { return nil }
            return UInt32(v)
        case let v as NSNumber:
            let n = v.int64Value
            guard n >= 0, n <= Int64(UInt32.max) else { return nil }
            return UInt32(n)
        default:
            return nil
        }
    }

    // MARK: - I2C

    /// Classic DDC/CI Set VCP: `[0x51, 0x84, 0x03, vcp, hi, lo, checksum]`.
    private static func writePacket(vcp: UInt8, value: UInt16) -> [UInt8] {
        let hi = UInt8((value >> 8) & 0xFF)
        let lo = UInt8(value & 0xFF)
        let body: [UInt8] = [0x51, 0x84, 0x03, vcp, hi, lo]
        let checksum = body.reduce(UInt8(0x6E)) { $0 ^ $1 }
        return body + [checksum]
    }

    /// Classic DDC/CI Get VCP: `[0x51, 0x82, 0x01, vcp, checksum]`.
    private static func readRequestPacket(vcp: UInt8) -> [UInt8] {
        let body: [UInt8] = [0x51, 0x82, 0x01, vcp]
        let checksum = body.reduce(UInt8(0x6E)) { $0 ^ $1 }
        return body + [checksum]
    }

    private static func readVCPOnce(framebuffer: io_service_t, code: UInt8) -> (current: UInt16, max: UInt16)? {
        usleep(interWriteSleepUs)
        var send = readRequestPacket(vcp: code)
        var reply = [UInt8](repeating: 0, count: 12)
        let sendCount = UInt32(send.count)
        let replyCount = UInt32(reply.count)
        let kr = send.withUnsafeMutableBytes { sendRaw -> IOReturn in
            reply.withUnsafeMutableBytes { replyRaw -> IOReturn in
                guard let sendPtr = sendRaw.baseAddress, let replyPtr = replyRaw.baseAddress else {
                    return kIOReturnNoMemory
                }
                var request = IOI2CRequest()
                request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                request.sendAddress = ddcDestination
                request.sendBuffer = vm_address_t(bitPattern: sendPtr)
                request.sendBytes = sendCount
                request.replyTransactionType = IOOptionBits(kIOI2CDDCciReplyTransactionType)
                request.replyAddress = ddcReplyAddress
                request.replySubAddress = 0x51
                request.replyBuffer = vm_address_t(bitPattern: replyPtr)
                request.replyBytes = replyCount
                request.minReplyDelay = minReplyDelayNs
                return sendRequest(&request, framebuffer: framebuffer)
            }
        }
        guard kr == kIOReturnSuccess else { return nil }
        if reply.allSatisfy({ $0 == 0 }) { return nil }
        if let parsed = DDC.parseVCPReply(reply, expectedVCP: code) {
            return (current: parsed.current, max: parsed.max)
        }
        let hex = reply.map { String(format: "%02x", $0) }.joined(separator: " ")
        logger.debug("IOFramebuffer DDC unexpected reply: \(hex, privacy: .public)")
        return nil
    }

    private static func sendWrite(framebuffer: io_service_t, packet: [UInt8]) -> IOReturn {
        var packet = packet
        let count = UInt32(packet.count)
        return packet.withUnsafeMutableBytes { raw -> IOReturn in
            guard let ptr = raw.baseAddress else { return kIOReturnNoMemory }
            var request = IOI2CRequest()
            request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
            request.sendAddress = ddcDestination
            request.sendBuffer = vm_address_t(bitPattern: ptr)
            request.sendBytes = count
            request.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
            request.replyBytes = 0
            return sendRequest(&request, framebuffer: framebuffer)
        }
    }

    private static func sendRequest(_ request: inout IOI2CRequest, framebuffer: io_service_t) -> IOReturn {
        var busCount: IOItemCount = 0
        let countKR = IOFBGetI2CInterfaceCount(framebuffer, &busCount)
        guard countKR == kIOReturnSuccess, busCount > 0 else {
            return countKR == kIOReturnSuccess ? kIOReturnNoDevice : countKR
        }

        var lastKR: IOReturn = kIOReturnNoDevice
        for bus: IOOptionBits in 0..<busCount {
            var interface: io_service_t = 0
            let copyKR = IOFBCopyI2CInterfaceForBus(framebuffer, bus, &interface)
            guard copyKR == kIOReturnSuccess, interface != 0 else {
                lastKR = copyKR
                continue
            }
            defer { IOObjectRelease(interface) }

            var connect: IOI2CConnectRef?
            let openKR = IOI2CInterfaceOpen(interface, 0, &connect)
            guard openKR == kIOReturnSuccess, let connect else {
                lastKR = openKR
                continue
            }
            defer { _ = IOI2CInterfaceClose(connect, 0) }

            let sendKR = IOI2CSendRequest(connect, 0, &request)
            if sendKR != kIOReturnSuccess {
                lastKR = sendKR
                if DDC.shouldStopRetrying(sendKR) { return sendKR }
                continue
            }
            if request.result == kIOReturnSuccess {
                return kIOReturnSuccess
            }
            lastKR = request.result
            if DDC.shouldStopRetrying(request.result) {
                return request.result
            }
        }
        return lastKR
    }
}
