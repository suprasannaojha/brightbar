import AppKit

if let code = CLI.run(arguments: CommandLine.arguments) {
    exit(code)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
