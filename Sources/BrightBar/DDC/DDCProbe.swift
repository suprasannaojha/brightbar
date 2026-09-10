import Foundation

/// CLI helper. The UI agent wires this to a `--probe` flag.
enum DDCProbe {
    static func runAndPrintReport() {
        print("BrightBar DDC probe")
        print("====================")

        if !IOAVServiceBridge.isAvailable {
            print("IOAVService symbols could not be loaded. DDC is unavailable on this Mac.")
            return
        }

        let matches = DisplayMatcher.matchExternalDisplays()
        if matches.isEmpty {
            print("No external displays found (or none exposed a DCPAVServiceProxy).")
            return
        }

        print("External AV services matched: \(matches.count)")
        print("")

        let controller = DDCBrightnessController()
        let viaController = controller.refreshDisplays()
        if viaController.isEmpty {
            print("DDCBrightnessController.refreshDisplays() returned no displays.")
        }

        for (index, match) in matches.enumerated() {
            let display = match.display
            let ident = match.identity
            print("\(index + 1). \(display.name)  (CGDirectDisplayID \(display.id))")
            if ident.hasNumericIdentity {
                print("   identity  vendor=\(ident.vendor) product=\(ident.product) serial=\(ident.serial) port=\(ident.portKey.isEmpty ? "-" : ident.portKey)")
            }
            if !ident.edidUUID.isEmpty {
                print("   EDID UUID \(ident.edidUUID)")
            }

            if let native = DDC.readBrightness(service: match.service.raw) {
                let percent = DDC.scaleToPercent(current: native.current, nativeMax: native.max)
                print("   DDC read  current=\(native.current) max=\(native.max)  →  \(percent)%")

                let controllerRead = controller.readBrightness(for: display)
                if let controllerRead {
                    print("   controller.readBrightness  \(controllerRead)%")
                } else {
                    print("   controller.readBrightness  (failed)")
                }

                // Non-destructive write: set brightness to the current value, then read back.
                let writeOK = controller.setBrightness(percent, for: display)
                let readback = controller.readBrightness(for: display)
                if writeOK, let readback {
                    let agree = abs(readback - percent) <= 1
                    print("   write \(percent)% (current value)  \(writeOK ? "ok" : "FAILED")  readback=\(readback)%  \(agree ? "match" : "mismatch")")
                } else {
                    print("   write \(percent)% (current value)  \(writeOK ? "ok" : "FAILED")  readback=\(readback.map { "\($0)%" } ?? "(failed)")")
                }
            } else {
                print("   DDC read  (no response)")
                print("   write+readback skipped (no baseline; not changing brightness)")
            }

            if let contrast = DDC.readContrast(service: match.service.raw) {
                print("   contrast  current=\(contrast.current) max=\(contrast.max)")
            }

            print("")
        }
    }
}
