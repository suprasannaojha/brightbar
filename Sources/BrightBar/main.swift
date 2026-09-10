import AppKit

if CommandLine.arguments.contains("--probe") {
    DDCProbe.runAndPrintReport()
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
