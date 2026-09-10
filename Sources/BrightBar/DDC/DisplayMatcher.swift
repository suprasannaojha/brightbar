import AppKit
import CoreGraphics
import Foundation
import IOKit
import os

/// An external display paired with the IOAVService that talks DDC on its I2C bus.
struct MatchedExternalDisplay {
    let display: ExternalDisplay
    let service: RetainedIOAVService
    let identity: IORegistryIdentity
}

struct IORegistryIdentity: Equatable {
    var vendor: UInt32 = 0
    var product: UInt32 = 0
    var serial: UInt32 = 0
    var productName: String = ""
    var manufacturerID: String = ""
    var alphanumericSerial: String = ""
    var edidUUID: String = ""
    var portKey: String = ""

    var hasNumericIdentity: Bool { vendor != 0 || product != 0 }

    func coreIdentity(fallbackDisplayID: CGDirectDisplayID) -> DisplayIdentity {
        let alpha = alphanumericSerial.trimmingCharacters(in: .whitespacesAndNewlines)
        return DisplayIdentity(
            vendor: vendor != 0 ? vendor : CGDisplayVendorNumber(fallbackDisplayID),
            product: product != 0 ? product : CGDisplayModelNumber(fallbackDisplayID),
            serial: serial != 0 ? serial : CGDisplaySerialNumber(fallbackDisplayID),
            alphanumericSerial: alpha.isEmpty ? nil : alpha
        )
    }
}

/// Maps `DCPAVServiceProxy` IORegistry entries onto `CGDirectDisplayID`s.
///
/// On Apple Silicon the DDC channel (`DCPAVServiceProxy`) and the framebuffer
/// identity (`IOMobileFramebufferShim` / `AppleCLCD2` → `DisplayAttributes`) live
/// in *sibling* subtrees under the same `dispextN` / `disp0` node. Walking
/// parents from the AV service therefore often finds nothing; we combine:
///
/// 1. Parent-chain walk (as a first try, plus `IORegistryEntrySearchCFProperty`).
/// 2. Depth-first IOService walk pairing each AV service with the most recently
///    seen framebuffer identity (MonitorControl / Arm64DDC).
/// 3. Port-key correlation (`dispext0` ↔ `dcpext0`).
/// 4. Vendor / model / serial scoring against CoreGraphics.
/// 5. 1:1 fallback when there is exactly one external CG display and one
///    external AV service.
enum DisplayMatcher {
    private static let logger = Logger(subsystem: "com.brightbar.app", category: "ddc")
    private static let framebufferClasses: Set<String> = [
        "IOMobileFramebufferShim",
        "AppleCLCD2"
    ]

    static func matchExternalDisplays() -> [MatchedExternalDisplay] {
        guard IOAVServiceBridge.isAvailable else {
            logger.error("IOAVService symbols are unavailable; cannot talk DDC")
            return []
        }

        let cgDisplays = onlineExternalCGDisplays()
        let candidates = collectAVCandidates()
        if candidates.isEmpty {
            logger.info("No external DCPAVServiceProxy entries found")
            return []
        }

        var usedServiceIndices = Set<Int>()
        var usedDisplayIDs = Set<CGDirectDisplayID>()
        var matches: [MatchedExternalDisplay] = []

        // Score every (AV service, CG display) pair and pick greedily.
        var scored: [(score: Int, serviceIndex: Int, displayID: CGDirectDisplayID)] = []
        for (index, candidate) in candidates.enumerated() {
            for cg in cgDisplays {
                let score = matchScore(identity: candidate.identity, displayID: cg.id)
                if score > 0 {
                    scored.append((score, index, cg.id))
                }
            }
        }
        scored.sort { $0.score > $1.score }

        for item in scored {
            if usedServiceIndices.contains(item.serviceIndex) { continue }
            if usedDisplayIDs.contains(item.displayID) { continue }
            guard let match = makeMatch(
                candidate: candidates[item.serviceIndex],
                displayID: item.displayID
            ) else { continue }
            usedServiceIndices.insert(item.serviceIndex)
            usedDisplayIDs.insert(item.displayID)
            matches.append(match)
        }

        // 1:1 fallback only when there is exactly one external CG display and one
        // external AV service. Pairing leftovers after a partial match would silently
        // attach the wrong monitor when 2+ externals are present.
        if matches.isEmpty, candidates.count == 1, cgDisplays.count == 1,
           let match = makeMatch(candidate: candidates[0], displayID: cgDisplays[0].id) {
            logger.info("1:1 fallback: single external display ↔ single external AV service")
            matches.append(match)
        }

        return matches
    }

    // MARK: - CG displays

    private struct CGDisplayInfo {
        let id: CGDirectDisplayID
        let vendor: UInt32
        let product: UInt32
        let serial: UInt32
    }

    private static func onlineExternalCGDisplays() -> [CGDisplayInfo] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return (0..<Int(count)).compactMap { index in
            let id = ids[index]
            guard CGDisplayIsBuiltin(id) == 0 else { return nil }
            return CGDisplayInfo(
                id: id,
                vendor: CGDisplayVendorNumber(id),
                product: CGDisplayModelNumber(id),
                serial: CGDisplaySerialNumber(id)
            )
        }
    }

    // MARK: - IORegistry collection

    private struct AVCandidate {
        let service: RetainedIOAVService
        var identity: IORegistryIdentity
    }

    /// Collect external AV services and attach the best identity we can find.
    private static func collectAVCandidates() -> [AVCandidate] {
        var lastFramebuffer = IORegistryIdentity()
        var framebuffers: [IORegistryIdentity] = []
        var candidates: [AVCandidate] = []

        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return [] }
        defer { IOObjectRelease(root) }

        var iterator: io_iterator_t = 0
        let options = IOOptionBits(kIORegistryIterateRecursively)
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, options, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }

            let className = ioClassName(entry) ?? ""

            if framebufferClasses.contains(className) {
                // New port: replace, do not merge across `disp0` / `dispextN`.
                let ident = identityFromFramebuffer(entry)
                // Never let the built-in panel's identity become the "last" framebuffer
                // for an external DCPAVServiceProxy.
                if ident.portKey != "disp0" {
                    lastFramebuffer = ident
                    if lastFramebuffer.hasNumericIdentity || !lastFramebuffer.productName.isEmpty || !lastFramebuffer.edidUUID.isEmpty {
                        framebuffers.append(lastFramebuffer)
                    }
                }
            }

            // Some trees expose DisplayAttributes on a non-framebuffer node first.
            if let attrs = cfProperty(entry, "DisplayAttributes") as? [String: Any],
               let fromAttrs = identityFromProductAttributes(attrs) {
                var ident = fromAttrs
                ident.portKey = portKey(from: registryPath(entry)) ?? ident.portKey
                if ident.portKey != "disp0", ident.hasNumericIdentity {
                    merge(from: ident, into: &lastFramebuffer)
                    if lastFramebuffer.vendor == 0 {
                        lastFramebuffer = ident
                    }
                }
            }

            guard className == "DCPAVServiceProxy" else { continue }
            let location = cfProperty(entry, "Location") as? String
            guard location == "External" else { continue }
            guard let av = RetainedIOAVService(entry) else {
                logger.error("IOAVServiceCreateWithService failed for an External DCPAVServiceProxy")
                continue
            }

            var identity = identityByWalkingParents(from: entry)
            if !identity.hasNumericIdentity, lastFramebuffer.portKey != "disp0" {
                identity = lastFramebuffer
            }
            if identity.portKey.isEmpty {
                identity.portKey = portKey(from: registryPath(entry)) ?? ""
            }

            // If the associated framebuffer still has no identity, try port-key pairing.
            if !identity.hasNumericIdentity, !identity.portKey.isEmpty {
                if let fb = framebuffers.last(where: { $0.portKey == identity.portKey }) {
                    identity = fb
                    identity.portKey = portKey(from: registryPath(entry)) ?? identity.portKey
                }
            }

            candidates.append(AVCandidate(service: av, identity: identity))
        }

        return candidates
    }

    private static func identityByWalkingParents(from service: io_registry_entry_t) -> IORegistryIdentity {
        var identity = IORegistryIdentity()
        identity.portKey = portKey(from: registryPath(service)) ?? ""

        // Direct / parent search for the usual identity keys.
        if let uuid = searchProperty(service, "EDID UUID", parents: true) as? String {
            identity.edidUUID = uuid
        }
        if let attrs = searchProperty(service, "DisplayAttributes", parents: true) as? [String: Any],
           let fromAttrs = identityFromProductAttributes(attrs) {
            merge(from: fromAttrs, into: &identity)
        }

        var current = service
        var ownsCurrent = false
        for _ in 0..<16 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 else {
                break
            }
            if ownsCurrent { IOObjectRelease(current) }
            current = parent
            ownsCurrent = true

            let className = ioClassName(current) ?? ""
            if framebufferClasses.contains(className) {
                merge(from: identityFromFramebuffer(current), into: &identity)
            }
            if let attrs = cfProperty(current, "DisplayAttributes") as? [String: Any],
               let fromAttrs = identityFromProductAttributes(attrs) {
                merge(from: fromAttrs, into: &identity)
            }
            if identity.edidUUID.isEmpty, let uuid = cfProperty(current, "EDID UUID") as? String {
                identity.edidUUID = uuid
            }
        }
        if ownsCurrent { IOObjectRelease(current) }
        return identity
    }

    private static func identityFromFramebuffer(_ entry: io_registry_entry_t) -> IORegistryIdentity {
        var identity = IORegistryIdentity()
        identity.portKey = portKey(from: registryPath(entry)) ?? ""
        if let uuid = cfProperty(entry, "EDID UUID") as? String {
            identity.edidUUID = uuid
        }
        if let attrs = cfProperty(entry, "DisplayAttributes") as? [String: Any],
           let fromAttrs = identityFromProductAttributes(attrs) {
            merge(from: fromAttrs, into: &identity)
        }
        return identity
    }

    private static func identityFromProductAttributes(_ displayAttributes: [String: Any]) -> IORegistryIdentity? {
        guard let product = displayAttributes["ProductAttributes"] as? [String: Any] else { return nil }
        var identity = IORegistryIdentity()
        identity.vendor = u32(product["LegacyManufacturerID"]) ?? 0
        identity.product = u32(product["ProductID"]) ?? 0
        identity.serial = u32(product["SerialNumber"]) ?? 0
        identity.productName = product["ProductName"] as? String ?? ""
        identity.manufacturerID = product["ManufacturerID"] as? String ?? ""
        identity.alphanumericSerial = product["AlphanumericSerialNumber"] as? String ?? ""
        // Adapter / MST nodes often have a huge ProductID that does not fit UInt32
        // and no ProductName — skip those so they don't steal the last-identity slot.
        // Skip adapter / MST stubs that have a vendor id but no product and no name.
        if identity.productName.isEmpty && identity.product == 0 {
            return nil
        }
        return identity
    }

    // MARK: - Matching

    private static func matchScore(identity: IORegistryIdentity, displayID: CGDirectDisplayID) -> Int {
        let vendor = CGDisplayVendorNumber(displayID)
        let product = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        var score = 0
        if identity.vendor != 0, identity.vendor == vendor { score += 4 }
        if identity.product != 0 {
            if identity.product == product { score += 4 }
            else if byteSwap16(identity.product) == product { score += 3 }
        }
        if identity.serial != 0, identity.serial == serial { score += 5 }
        return score
    }

    private static func makeMatch(candidate: AVCandidate, displayID: CGDirectDisplayID) -> MatchedExternalDisplay? {
        guard CGDisplayIsBuiltin(displayID) == 0 else { return nil }
        let name = displayName(productName: candidate.identity.productName, id: displayID)
        let display = ExternalDisplay(
            id: displayID,
            name: name,
            identity: candidate.identity.coreIdentity(fallbackDisplayID: displayID),
            capabilities: DisplayCapabilities()
        )
        return MatchedExternalDisplay(display: display, service: candidate.service, identity: candidate.identity)
    }

    /// Online non-built-in CoreGraphics displays.
    static func onlineExternalDisplayIDs() -> [CGDirectDisplayID] {
        onlineExternalCGDisplays().map(\.id)
    }

    static func identityFromCGDisplay(_ id: CGDirectDisplayID, alphanumericSerial: String? = nil) -> DisplayIdentity {
        let trimmed = alphanumericSerial?.trimmingCharacters(in: .whitespacesAndNewlines)
        return DisplayIdentity(
            vendor: CGDisplayVendorNumber(id),
            product: CGDisplayModelNumber(id),
            serial: CGDisplaySerialNumber(id),
            alphanumericSerial: (trimmed?.isEmpty == false) ? trimmed : nil
        )
    }

    static func displayName(productName: String?, id: CGDirectDisplayID) -> String {
        if let productName, !productName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return productName
        }
        if let screenName = nsScreenName(for: id), !screenName.isEmpty {
            return screenName
        }
        return "Display \(id)"
    }

    private static func nsScreenName(for id: CGDirectDisplayID) -> String? {
        // AppKit is not safe off the main thread; matching often runs on the DDC queue.
        // Do not `DispatchQueue.main.sync` here — `refreshDisplays()` uses `i2cQueue.sync`
        // and can already be running on the main thread (e.g. `--probe`).
        guard Thread.isMainThread else { return nil }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first { screen in
            if let number = screen.deviceDescription[key] as? NSNumber {
                return number.uint32Value == id
            }
            if let value = screen.deviceDescription[key] as? CGDirectDisplayID {
                return value == id
            }
            return false
        }?.localizedName
    }

    // MARK: - IORegistry helpers

    private static func ioClassName(_ object: io_object_t) -> String? {
        var name = [CChar](repeating: 0, count: 128)
        guard IOObjectGetClass(object, &name) == KERN_SUCCESS else { return nil }
        return String(cString: name)
    }

    private static func registryPath(_ entry: io_registry_entry_t) -> String {
        var path = [CChar](repeating: 0, count: 512)
        guard IORegistryEntryGetPath(entry, kIOServicePlane, &path) == KERN_SUCCESS else { return "" }
        return String(cString: path)
    }

    /// Correlate `dispext0` framebuffers with `dcpext0` DCP nodes (and `disp0` with the built-in DCP).
    private static func portKey(from path: String) -> String? {
        let lower = path.lowercased()
        if let regex = try? NSRegularExpression(pattern: #"(?:dcp|disp)ext(\d+)"#),
           let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let numRange = Range(match.range(at: 1), in: lower) {
            return "ext\(lower[numRange])"
        }
        if lower.contains("dispext") { return nil }
        if lower.contains("disp0") || (lower.contains("iop-dcp-nub") && !lower.contains("dcpext")) {
            return "disp0"
        }
        return nil
    }

    private static func cfProperty(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        guard let unmanaged = IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        return unmanaged.takeRetainedValue() as Any
    }

    private static func searchProperty(_ entry: io_registry_entry_t, _ key: String, parents: Bool) -> Any? {
        var options = IOOptionBits(kIORegistryIterateRecursively)
        if parents {
            options |= IOOptionBits(kIORegistryIterateParents)
        }
        guard let unmanaged = IORegistryEntrySearchCFProperty(
            entry, kIOServicePlane, key as CFString, kCFAllocatorDefault, options
        ) else { return nil }
        // SearchCFProperty returns +1.
        return unmanaged as Any
    }

    private static func merge(from src: IORegistryIdentity, into dest: inout IORegistryIdentity) {
        if dest.vendor == 0 { dest.vendor = src.vendor }
        if dest.product == 0 { dest.product = src.product }
        if dest.serial == 0 { dest.serial = src.serial }
        if dest.productName.isEmpty { dest.productName = src.productName }
        if dest.manufacturerID.isEmpty { dest.manufacturerID = src.manufacturerID }
        if dest.alphanumericSerial.isEmpty { dest.alphanumericSerial = src.alphanumericSerial }
        if dest.edidUUID.isEmpty { dest.edidUUID = src.edidUUID }
        if dest.portKey.isEmpty { dest.portKey = src.portKey }
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

    private static func byteSwap16(_ value: UInt32) -> UInt32 {
        let v = UInt16(truncatingIfNeeded: value)
        return UInt32((v << 8) | (v >> 8))
    }
}
