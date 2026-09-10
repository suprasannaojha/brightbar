import Darwin
import Foundation
import IOKit
import os

/// DDC/CI over the Apple Silicon `IOAVService` I2C bridge.
///
/// Packet layout matches `m1ddc` and MonitorControl's Arm64DDC:
/// the DDC source address `0x51` is passed as the I2C data-address argument
/// to `IOAVServiceWriteI2C` / `IOAVServiceReadI2C`, not as the first payload byte.
enum DDC {
    /// DDC/CI 7-bit I2C address of the monitor (0x6E when shifted).
    static let chipAddress: UInt32 = 0x37
    /// DDC/CI source / sub-address used as the I2C offset.
    static let dataAddress: UInt32 = 0x51

    enum VCP {
        /// Luminance (brightness).
        static let brightness: UInt8 = 0x10
        /// Contrast. Exposed for probe / future UI; brightness is the priority.
        static let contrast: UInt8 = 0x12
    }

    struct VCPResult {
        let current: UInt16
        let max: UInt16
    }

    private static let logger = Logger(subsystem: "com.brightbar.app", category: "ddc")

    private static let writeAttempts = 3
    private static let readAttempts = 5
    private static let interWriteSleepUs: useconds_t = 10_000
    private static let postWriteReadSleepUs: useconds_t = 40_000
    private static let retrySleepUs: useconds_t = 20_000
    /// Serializes I2C so a read/write pair cannot interleave with another client
    /// (store refresh on a global queue vs debounced writes on `hardwareQueue`).
    private static let i2cLock = NSLock()

    // MARK: - Public VCP helpers

    static func readVCP(service: IOAVService, code: UInt8) -> VCPResult? {
        i2cLock.lock()
        defer { i2cLock.unlock() }
        for attempt in 0..<readAttempts {
            if let result = readVCPOnce(service: service, code: code) {
                return result
            }
            usleep(retrySleepUs)
            logger.debug("DDC VCP 0x\(String(code, radix: 16), privacy: .public) read retry \(attempt + 1)")
        }
        logger.error("DDC VCP 0x\(String(code, radix: 16), privacy: .public) read failed after \(self.readAttempts) attempts")
        return nil
    }

    @discardableResult
    static func writeVCP(service: IOAVService, code: UInt8, value: UInt16) -> Bool {
        i2cLock.lock()
        defer { i2cLock.unlock() }
        let packet = writePacket(vcp: code, value: value)
        var lastOK = false
        for _ in 0..<writeAttempts {
            usleep(interWriteSleepUs)
            let kr = packet.withUnsafeBytes { raw -> IOReturn in
                guard let ptr = raw.baseAddress else { return kIOReturnNoMemory }
                return IOAVServiceBridge.writeI2C(
                    service,
                    chipAddress: chipAddress,
                    dataAddress: dataAddress,
                    inputBuffer: ptr,
                    inputBufferSize: UInt32(packet.count)
                )
            }
            lastOK = (kr == kIOReturnSuccess)
            if !lastOK {
                logger.debug("DDC write VCP 0x\(String(code, radix: 16), privacy: .public) IOReturn 0x\(String(UInt32(bitPattern: kr), radix: 16), privacy: .public)")
                // A missing / unplugged display will not recover by spinning retries.
                if kr == kIOReturnNotAttached || kr == kIOReturnNotFound
                    || kr == kIOReturnOffline || kr == kIOReturnNoDevice {
                    break
                }
            }
        }
        if !lastOK {
            logger.error("DDC write VCP 0x\(String(code, radix: 16), privacy: .public) failed")
        }
        return lastOK
    }

    static func readBrightness(service: IOAVService) -> VCPResult? {
        readVCP(service: service, code: VCP.brightness)
    }

    static func writeBrightness(service: IOAVService, native: UInt16) -> Bool {
        writeVCP(service: service, code: VCP.brightness, value: native)
    }

    static func readContrast(service: IOAVService) -> VCPResult? {
        readVCP(service: service, code: VCP.contrast)
    }

    /// Scale a native DDC reading onto 0...100 using the monitor's reported max.
    static func scaleToPercent(current: UInt16, nativeMax: UInt16) -> Int {
        let ceiling = nativeMax == 0 ? 100 : Int(nativeMax)
        let percent = Int((Double(current) / Double(ceiling) * 100.0).rounded())
        return Swift.min(100, Swift.max(0, percent))
    }

    /// Convert a 0...100 slider value to a native DDC register value.
    static func nativeValue(percent: Int, nativeMax: UInt16) -> UInt16 {
        let clamped = Swift.min(100, Swift.max(0, percent))
        let ceiling = nativeMax == 0 ? UInt32(100) : UInt32(nativeMax)
        let scaled = (UInt32(clamped) * ceiling + 50) / 100
        return UInt16(clamping: min(scaled, ceiling))
    }

    // MARK: - Packets

    /// Set VCP: `[0x84, 0x03, vcp, hi, lo, checksum]`
    /// checksum = `0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ vcp ^ hi ^ lo`
    private static func writePacket(vcp: UInt8, value: UInt16) -> [UInt8] {
        let hi = UInt8((value >> 8) & 0xFF)
        let lo = UInt8(value & 0xFF)
        let body: [UInt8] = [0x84, 0x03, vcp, hi, lo]
        let checksum = body.reduce(UInt8(0x6E ^ 0x51)) { $0 ^ $1 }
        return body + [checksum]
    }

    /// Get VCP request: `[0x82, 0x01, vcp, checksum]` written at I2C offset 0x51.
    /// checksum = `0x6E ^ 0x51 ^ 0x82 ^ 0x01 ^ vcp` (DDC/CI: include the source address).
    /// Some stacks omit 0x51 from the XOR; `readVCPOnce` tries that as a fallback.
    private static func readRequestPacket(vcp: UInt8, includeSourceInChecksum: Bool) -> [UInt8] {
        let body: [UInt8] = [0x82, 0x01, vcp]
        let seed: UInt8 = includeSourceInChecksum ? (0x6E ^ 0x51) : 0x6E
        let checksum = body.reduce(seed) { $0 ^ $1 }
        return body + [checksum]
    }

    private static func sendI2C(_ service: IOAVService, _ packet: [UInt8]) -> IOReturn {
        packet.withUnsafeBytes { raw -> IOReturn in
            guard let ptr = raw.baseAddress else { return kIOReturnNoMemory }
            return IOAVServiceBridge.writeI2C(
                service,
                chipAddress: chipAddress,
                dataAddress: dataAddress,
                inputBuffer: ptr,
                inputBufferSize: UInt32(packet.count)
            )
        }
    }

    private static func readVCPOnce(service: IOAVService, code: UInt8) -> VCPResult? {
        // DDC/CI includes source address 0x51 in the checksum. m1ddc's
        // prepareDDCRead omits it; try the spec packet first, then that variant.
        for includeSource in [true, false] {
            let request = readRequestPacket(vcp: code, includeSourceInChecksum: includeSource)
            var wroteOK = false
            for _ in 0..<2 {
                usleep(interWriteSleepUs)
                if sendI2C(service, request) == kIOReturnSuccess {
                    wroteOK = true
                }
            }
            guard wroteOK else { continue }

            usleep(postWriteReadSleepUs)

            if let result = readReply(service: service, vcp: code, offset: dataAddress, length: 12) {
                return result
            }
            if let result = readReply(service: service, vcp: code, offset: 0, length: 11) {
                return result
            }
        }
        return nil
    }

    private static func readReply(
        service: IOAVService,
        vcp: UInt8,
        offset: UInt32,
        length: Int
    ) -> VCPResult? {
        var buffer = [UInt8](repeating: 0, count: length)
        let kr = buffer.withUnsafeMutableBytes { raw -> IOReturn in
            guard let ptr = raw.baseAddress else { return kIOReturnNoMemory }
            return IOAVServiceBridge.readI2C(
                service,
                chipAddress: chipAddress,
                offset: offset,
                outputBuffer: ptr,
                outputBufferSize: UInt32(length)
            )
        }
        guard kr == kIOReturnSuccess else {
            logger.debug("DDC readI2C offset 0x\(String(offset, radix: 16), privacy: .public) failed: 0x\(String(UInt32(bitPattern: kr), radix: 16), privacy: .public)")
            return nil
        }

        if buffer.allSatisfy({ $0 == 0 }) {
            return nil
        }

        guard let parsed = parseVCPReply(buffer, expectedVCP: vcp) else {
            let hex = buffer.map { String(format: "%02x", $0) }.joined(separator: " ")
            logger.debug("DDC unexpected reply (offset 0x\(String(offset, radix: 16), privacy: .public)): \(hex, privacy: .public)")
            return nil
        }
        return parsed
    }

    /// Get-VCP Feature Reply. Layout (12-byte buffer, also works for 11-byte):
    ///   [2] = 0x02 (opcode), [4] = VCP code,
    ///   max = (reply[6] << 8) | reply[7],
    ///   current = (reply[8] << 8) | reply[9]
    private static func parseVCPReply(_ reply: [UInt8], expectedVCP: UInt8) -> VCPResult? {
        let candidates: [[UInt8]] = {
            var list: [[UInt8]] = [reply]
            if reply.count > 1, reply[0] == 0x00 {
                list.append(Array(reply.dropFirst()))
            }
            return list
        }()

        for bytes in candidates where bytes.count >= 10 {
            // Standard DDC/CI Get VCP reply.
            if bytes.count > 4, bytes[2] == 0x02, bytes[4] == expectedVCP {
                let maxValue = (UInt16(bytes[6]) << 8) | UInt16(bytes[7])
                let current = (UInt16(bytes[8]) << 8) | UInt16(bytes[9])
                if checksumLooksPlausible(bytes) || maxValue > 0 {
                    return VCPResult(current: current, max: maxValue == 0 ? 100 : maxValue)
                }
            }
        }
        return nil
    }

    /// Reply checksum seed 0x50 over the first 10 bytes, compared to byte 10.
    /// A mismatch is logged but does not reject a structurally valid reply —
    /// some panels (including certain AOC units) compute this incorrectly.
    private static func checksumLooksPlausible(_ reply: [UInt8]) -> Bool {
        guard reply.count >= 11 else { return false }
        var chk: UInt8 = 0x50
        for i in 0..<10 {
            chk ^= reply[i]
        }
        return chk == reply[10]
    }
}
