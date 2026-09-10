import CoreGraphics
import Foundation

/// Dims a display by scaling its gamma/transfer table. Level 0 is a no-op;
/// 1.0 is maximum software dimming (tables multiplied by 0.15 so the screen
/// never goes fully black). Gamma set by this process is reverted on exit;
/// `clear` / `clearAll` still restore it explicitly.
@MainActor
final class SoftwareDimmer {
    private struct GammaTable {
        var red: [Float]
        var green: [Float]
        var blue: [Float]
        var sampleCount: UInt32
    }

    private enum Origin {
        case table(GammaTable)
        case formula
    }

    private let tableCapacity: UInt32 = 256
    private var origins: [CGDirectDisplayID: Origin] = [:]
    private var levels: [CGDirectDisplayID: Double] = [:]

    /// - Parameter level: 0.0 (no dimming) ... 1.0 (max software dimming).
    func setLevel(_ level: Double, for displayID: CGDirectDisplayID) {
        let clamped = min(max(level, 0), 1)
        if clamped <= 0 {
            clear(for: displayID)
            return
        }
        levels[displayID] = clamped
        apply(level: clamped, to: displayID)
    }

    func clear(for displayID: CGDirectDisplayID) {
        if case .table(let table) = origins[displayID] {
            _ = writeTable(table, to: displayID)
        }
        origins.removeValue(forKey: displayID)
        levels.removeValue(forKey: displayID)
        if !hasActiveDim {
            CGDisplayRestoreColorSyncSettings()
        }
    }

    func clearAll() {
        for (displayID, origin) in origins {
            if case .table(let table) = origin {
                _ = writeTable(table, to: displayID)
            }
        }
        origins.removeAll()
        levels.removeAll()
        CGDisplayRestoreColorSyncSettings()
    }

    /// Re-applies stored levels. Call after display reconfiguration; CoreGraphics
    /// can reset gamma tables on those events.
    func reapplyAll() {
        for (displayID, level) in levels where level > 0 {
            apply(level: level, to: displayID)
        }
    }

    private var hasActiveDim: Bool {
        levels.contains { $0.value > 0 }
    }

    private func apply(level: Double, to displayID: CGDirectDisplayID) {
        let factor = Float(1.0 - level * 0.85)

        if origins[displayID] == nil {
            if let table = captureTable(for: displayID) {
                origins[displayID] = .table(table)
            } else {
                origins[displayID] = .formula
            }
        }

        if case .table(let table) = origins[displayID] {
            let dimmed = scaled(table, by: factor)
            if writeTable(dimmed, to: displayID) {
                return
            }
        }

        _ = CGSetDisplayTransferByFormula(
            displayID,
            0, factor, 1,
            0, factor, 1,
            0, factor, 1
        )
    }

    private func captureTable(for displayID: CGDirectDisplayID) -> GammaTable? {
        var red = [Float](repeating: 0, count: Int(tableCapacity))
        var green = [Float](repeating: 0, count: Int(tableCapacity))
        var blue = [Float](repeating: 0, count: Int(tableCapacity))
        var sampleCount: UInt32 = 0

        let status = red.withUnsafeMutableBufferPointer { redBuffer in
            green.withUnsafeMutableBufferPointer { greenBuffer in
                blue.withUnsafeMutableBufferPointer { blueBuffer in
                    guard
                        let redPointer = redBuffer.baseAddress,
                        let greenPointer = greenBuffer.baseAddress,
                        let bluePointer = blueBuffer.baseAddress
                    else {
                        return CGError.failure
                    }
                    return CGGetDisplayTransferByTable(
                        displayID,
                        tableCapacity,
                        redPointer,
                        greenPointer,
                        bluePointer,
                        &sampleCount
                    )
                }
            }
        }

        guard status == .success, sampleCount > 0 else { return nil }
        return GammaTable(red: red, green: green, blue: blue, sampleCount: sampleCount)
    }

    private func scaled(_ table: GammaTable, by factor: Float) -> GammaTable {
        let count = min(
            Int(table.sampleCount),
            table.red.count,
            table.green.count,
            table.blue.count
        )
        var dimmed = table
        for index in 0..<count {
            dimmed.red[index] *= factor
            dimmed.green[index] *= factor
            dimmed.blue[index] *= factor
        }
        return dimmed
    }

    @discardableResult
    private func writeTable(_ table: GammaTable, to displayID: CGDirectDisplayID) -> Bool {
        guard table.sampleCount > 0 else { return false }
        var red = table.red
        var green = table.green
        var blue = table.blue
        let status = red.withUnsafeMutableBufferPointer { redBuffer in
            green.withUnsafeMutableBufferPointer { greenBuffer in
                blue.withUnsafeMutableBufferPointer { blueBuffer in
                    guard
                        let redPointer = redBuffer.baseAddress,
                        let greenPointer = greenBuffer.baseAddress,
                        let bluePointer = blueBuffer.baseAddress
                    else {
                        return CGError.failure
                    }
                    return CGSetDisplayTransferByTable(
                        displayID,
                        table.sampleCount,
                        redPointer,
                        greenPointer,
                        bluePointer
                    )
                }
            }
        }
        return status == .success
    }
}
