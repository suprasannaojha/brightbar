import Foundation

/// CLI helper. The UI agent wires this to a `--probe` flag and a "Copy Diagnostics" action.
enum DDCProbe {
    static func runAndPrintReport() {
        print(report())
    }

    static func report() -> String {
        var lines: [String] = []
        lines.append("BrightBar DDC probe")
        lines.append("====================")
        lines.append("IOAVService symbols: \(IOAVServiceBridge.isAvailable ? "available" : "unavailable")")
        lines.append("DCPAVServiceProxy in registry: \(IOFramebufferDDC.hasDCPAVServiceProxy ? "yes" : "no")")
        lines.append("IOFramebuffer I2C interfaces: \(IOFramebufferDDC.hasI2CInterfaces ? "yes" : "no")")
        lines.append("IOFramebuffer DDC path: \(IOFramebufferDDC.shouldUse ? "selected (experimental)" : "idle")")
        lines.append("DisplayServices: \(DisplayServicesBridge.isAvailable ? "available" : "unavailable")")
        lines.append("")

        let controller = DDCBrightnessController()
        let displays = controller.refreshDisplays()
        let avByID = Dictionary(
            DisplayMatcher.matchExternalDisplays().map { ($0.display.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        if displays.isEmpty {
            lines.append("No external displays found.")
            return lines.joined(separator: "\n")
        }

        lines.append("External displays: \(displays.count)")
        lines.append("")

        for (index, display) in displays.enumerated() {
            lines.append("\(index + 1). \(display.name)  (CGDirectDisplayID \(display.id))")

            let ident = display.identity
            let alpha = ident.alphanumericSerial ?? "-"
            lines.append("   identity  vendor=\(ident.vendor) product=\(ident.product) serial=\(ident.serial) alphanumeric=\(alpha)")
            lines.append("   persistentKey \(ident.persistentKey)")

            if let registry = avByID[display.id]?.identity {
                if !registry.portKey.isEmpty {
                    lines.append("   registry  port=\(registry.portKey)")
                }
                if !registry.edidUUID.isEmpty {
                    lines.append("   EDID UUID \(registry.edidUUID)")
                }
            }

            let caps = display.capabilities
            lines.append("   capabilities  ddc=\(caps.supportsDDC) contrast=\(caps.supportsContrast) audio=\(caps.supportsAudio) nativeBrightness=\(caps.supportsNativeBrightness)")
            let backend = controller.backend(for: display)?.probeName ?? "unknown"
            lines.append("   backend  \(backend)")

            if let native = controller.readVCP(.brightness, for: display) {
                let percent = DDC.scaleToPercent(current: native.current, nativeMax: native.max)
                lines.append("   brightness  current=\(native.current) max=\(native.max)  →  \(percent)%")
            } else if let percent = controller.readBrightness(for: display) {
                lines.append("   brightness  \(percent)%  (DisplayServices)")
            } else {
                lines.append("   brightness  (no response)")
            }

            if let contrast = controller.readVCP(.contrast, for: display) {
                lines.append("   contrast  current=\(contrast.current) max=\(contrast.max)")
            } else {
                lines.append("   contrast  (no response)")
            }

            if let volume = controller.readVCP(.volume, for: display) {
                lines.append("   volume  current=\(volume.current) max=\(volume.max)")
            } else {
                lines.append("   volume  (no response)")
            }

            if let muted = controller.readMute(for: display) {
                lines.append("   mute  \(muted ? "muted (1)" : "unmuted (2)")")
            } else {
                lines.append("   mute  (no response)")
            }

            if let result = controller.readVCP(.inputSource, for: display) {
                let code = result.current & 0xFF
                if let known = InputSource(rawValue: code) {
                    lines.append("   input source  raw=\(result.current)  code=\(code)  \(known.displayName)")
                } else {
                    lines.append("   input source  raw=\(result.current)  code=\(code)  (unknown)")
                }
            } else {
                lines.append("   input source  (no response)")
            }

            // Non-destructive write: set brightness to the current value, then read back.
            if let percent = controller.readBrightness(for: display) {
                let writeOK = controller.setBrightness(percent, for: display)
                let readback = controller.readBrightness(for: display)
                if writeOK, let readback {
                    let agree = abs(readback - percent) <= 1
                    lines.append("   write \(percent)% (current value)  \(writeOK ? "ok" : "FAILED")  readback=\(readback)%  \(agree ? "match" : "mismatch")")
                } else {
                    lines.append("   write \(percent)% (current value)  \(writeOK ? "ok" : "FAILED")  readback=\(readback.map { "\($0)%" } ?? "(failed)")")
                }
            } else {
                lines.append("   write+readback skipped (no baseline; not changing brightness)")
            }

            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}
