import Foundation

enum CLI {
    static let usageText = """
    BrightBar — control external display brightness

    Usage:
      brightbar <command> [options]

    Commands:
      list                         List external displays
      get [property]               Read brightness, contrast, volume, mute, or input
      set <value>                  Set a property (default: brightness)
      mute [on|off|toggle]        Mute or unmute (default: toggle)
      input <name|code>           Switch input source
      power <on|standby|off>      Set power mode
      preset <name>               Apply a named preset
      probe                        Print a DDC diagnostics report
      help                         Show this help

    Options:
      --display <sel>              Display index, id, name substring, or "all"
      --property <name>          brightness, contrast, or volume (for set)
      --json                       JSON output (list, get)
      -h, --help                   Show this help
      --version                    Print version

    Values:
      set 40                       Absolute brightness 0...100
      set -20                      Software dimming (-50...0; requires running app)
      set +10                      Relative step; +-10 decreases brightness
      set --property contrast 50   Contrast / volume are 0...100

    Install the `brightbar` command: BrightBar → Settings → General, or run: ln -s /Applications/BrightBar.app/Contents/MacOS/BrightBar /usr/local/bin/brightbar
    """

    /// Returns nil when this process should start the GUI. Otherwise an exit code.
    static func run(arguments: [String]) -> Int32? {
        let rest = stripLaunchArgs(Array(arguments.dropFirst()))
        if rest.isEmpty { return nil }

        let parsed = parse(rest)
        if let error = parsed.error {
            return usageError(error)
        }
        if parsed.help {
            print(usageText)
            return 0
        }
        if parsed.version && parsed.command == nil && !parsed.probe {
            print("BrightBar \(version)")
            return 0
        }

        let commandName = parsed.command?.lowercased()
        if parsed.probe && commandName == nil {
            return emit(DirectCommandRunner.run(RemoteCommand(action: .probe)), json: false, command: RemoteCommand(action: .probe))
        }

        guard let commandName else {
            return usageError("Missing command.")
        }

        switch commandName {
        case "help":
            print(usageText)
            return 0
        case "selftest-urls":
            return runURLSelfTest()
        case "list", "get", "set", "mute", "input", "power", "preset", "probe":
            break
        default:
            return usageError("Unknown command '\(commandName)'.")
        }

        switch buildCommand(name: commandName, parsed: parsed) {
        case .failure(let reply):
            if reply.code == 1 {
                return usageError(reply.message)
            }
            if !reply.message.isEmpty {
                StandardError.write(reply.message)
            }
            return reply.code == 0 ? 3 : reply.code
        case .success(let command):
            return execute(command, json: parsed.json)
        }
    }

    private static var version: String {
        if let value = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !value.isEmpty {
            return value
        }
        return "1.0.0"
    }

    // MARK: - Dispatch

    private static func execute(_ command: RemoteCommand, json: Bool) -> Int32 {
        if command.action == .probe {
            return emit(DirectCommandRunner.run(command), json: json, command: command)
        }

        if let remote = RemoteIPC.send(command) {
            return emit(remote, json: json, command: command)
        }

        let reply = DirectCommandRunner.run(command)
        return emit(reply, json: json, command: command)
    }

    private static func emit(_ reply: RemoteReply, json: Bool, command: RemoteCommand) -> Int32 {
        if !reply.message.isEmpty {
            StandardError.write(reply.message)
        }
        if !reply.ok {
            if reply.code == 1 {
                StandardError.write(usageText)
            }
            return reply.code == 0 ? Int32(3) : reply.code
        }

        let text: String
        switch command.action {
        case .list:
            if let items = PayloadJSON.decodeList(reply.payload) {
                text = CLIFormat.list(items, json: json)
            } else {
                text = reply.payload
            }
        case .get:
            if let items = PayloadJSON.decodeGet(reply.payload) {
                text = CLIFormat.get(items, json: json, label: command.targetsAllDisplays)
            } else {
                text = reply.payload
            }
        case .probe:
            text = reply.payload
        case .set, .mute, .input, .power, .preset:
            text = reply.payload
        }

        if !text.isEmpty {
            print(text, terminator: text.hasSuffix("\n") ? "" : "\n")
        }
        return 0
    }

    private static func usageError(_ message: String) -> Int32 {
        StandardError.write(message)
        StandardError.write(usageText)
        return 1
    }

    // MARK: - Build RemoteCommand

    private static func buildCommand(name: String, parsed: Parsed) -> Result<RemoteCommand, RemoteReply> {
        let display = parsed.display
        switch name {
        case "list":
            return .success(RemoteCommand(action: .list, display: display))
        case "probe":
            return .success(RemoteCommand(action: .probe))
        case "get":
            let raw = parsed.positionals.first ?? parsed.property
            let property: RemoteCommand.Property
            if let raw {
                guard let parsedProperty = parseGetProperty(raw) else {
                    return .failure(.failure(code: 1, message: "Unknown property '\(raw)'."))
                }
                property = parsedProperty
            } else {
                property = .brightness
            }
            return .success(RemoteCommand(action: .get, display: display, property: property))
        case "set":
            guard let raw = parsed.positionals.first else {
                return .failure(.failure(code: 1, message: "Missing value. Usage: set <value>"))
            }
            let property: RemoteCommand.Property
            if let name = parsed.property {
                guard let parsedProperty = parseSetProperty(name) else {
                    return .failure(.failure(code: 1, message: "Unknown property '\(name)'."))
                }
                property = parsedProperty
            } else {
                property = .brightness
            }
            guard let parsedValue = parseSetValue(raw, property: property) else {
                return .failure(.failure(code: 1, message: "Invalid value '\(raw)'."))
            }
            if let rangeError = validateSetValue(parsedValue.value, relative: parsedValue.relative, property: property) {
                return .failure(.failure(code: 1, message: rangeError))
            }
            return .success(RemoteCommand(
                action: .set,
                display: display,
                property: property,
                value: parsedValue.value,
                relative: parsedValue.relative
            ))
        case "mute":
            let op: RemoteCommand.MuteOp
            if let raw = parsed.positionals.first?.lowercased() {
                switch raw {
                case "on", "mute", "muted": op = .on
                case "off", "unmute", "unmuted": op = .off
                case "toggle": op = .toggle
                default:
                    return .failure(.failure(code: 1, message: "Unknown mute state '\(raw)'. Use on, off, or toggle."))
                }
            } else {
                op = .toggle
            }
            return .success(RemoteCommand(action: .mute, display: display, mute: op))
        case "input":
            let joined = parsed.positionals.joined(separator: " ")
            guard !joined.isEmpty else {
                return .failure(.failure(code: 1, message: "Missing input. Usage: input <name|code>"))
            }
            if InputSourceParser.parse(joined) == nil {
                return .failure(.failure(code: 1, message: "Unknown input source '\(joined)'."))
            }
            return .success(RemoteCommand(action: .input, display: display, input: joined))
        case "power":
            guard let raw = parsed.positionals.first?.lowercased() else {
                return .failure(.failure(code: 1, message: "Missing power mode. Usage: power <on|standby|off>"))
            }
            let op: RemoteCommand.PowerOp
            switch raw {
            case "on": op = .on
            case "standby": op = .standby
            case "off": op = .off
            default:
                return .failure(.failure(code: 1, message: "Unknown power mode '\(raw)'. Use on, standby, or off."))
            }
            return .success(RemoteCommand(action: .power, display: display, power: op))
        case "preset":
            let name = parsed.positionals.joined(separator: " ")
            guard !name.isEmpty else {
                return .failure(.failure(code: 1, message: "Missing preset name. Usage: preset <name>"))
            }
            return .success(RemoteCommand(action: .preset, display: display, preset: name))
        default:
            return .failure(.failure(code: 1, message: "Unknown command '\(name)'."))
        }
    }

    private static func parseGetProperty(_ raw: String) -> RemoteCommand.Property? {
        switch raw.lowercased() {
        case "brightness": return .brightness
        case "contrast": return .contrast
        case "volume": return .volume
        case "mute": return .mute
        case "input": return .input
        default: return nil
        }
    }

    private static func parseSetProperty(_ raw: String) -> RemoteCommand.Property? {
        switch raw.lowercased() {
        case "brightness": return .brightness
        case "contrast": return .contrast
        case "volume": return .volume
        default: return nil
        }
    }

    /// `+10` / `+-10` are relative. A leading minus on brightness is absolute software dimming.
    static func parseSetValue(_ raw: String, property: RemoteCommand.Property) -> (value: Double, relative: Bool)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        if trimmed.hasPrefix("+-") {
            guard let magnitude = Double(String(trimmed.dropFirst(2))) else { return nil }
            return (-magnitude, true)
        }
        if trimmed.hasPrefix("+") {
            guard let value = Double(trimmed) else { return nil }
            return (value, true)
        }
        guard let value = Double(trimmed) else { return nil }
        if value < 0 && property != .brightness {
            return (value, true)
        }
        return (value, false)
    }

    private static func validateSetValue(_ value: Double, relative: Bool, property: RemoteCommand.Property) -> String? {
        if relative {
            if value < -100 || value > 100 {
                return "Relative step must be between -100 and 100."
            }
            return nil
        }
        switch property {
        case .brightness:
            if value < -50 || value > 100 {
                return "Brightness must be between -50 and 100."
            }
        case .contrast, .volume:
            if value < 0 || value > 100 {
                return "\(property.rawValue.capitalized) must be between 0 and 100."
            }
        case .mute, .input:
            break
        }
        return nil
    }

    // MARK: - Args

    private struct Parsed {
        var command: String?
        var positionals: [String] = []
        var display: String?
        var property: String?
        var json = false
        var help = false
        var version = false
        var probe = false
        var error: String?
    }

    private static func parse(_ args: [String]) -> Parsed {
        var parsed = Parsed()
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--" {
                parsed.positionals.append(contentsOf: args[(index + 1)...])
                break
            }
            if arg == "--json" {
                parsed.json = true
                index += 1
                continue
            }
            if arg == "--help" || arg == "-h" {
                parsed.help = true
                index += 1
                continue
            }
            if arg == "--version" {
                parsed.version = true
                index += 1
                continue
            }
            if arg == "--probe" {
                parsed.probe = true
                index += 1
                continue
            }
            if arg == "--display" {
                guard let value = flagValue(args, index: index) else {
                    parsed.error = "Missing value for --display."
                    return parsed
                }
                parsed.display = value
                index += 2
                continue
            }
            if arg.hasPrefix("--display=") {
                let value = String(arg.dropFirst("--display=".count))
                if value.isEmpty {
                    parsed.error = "Missing value for --display."
                    return parsed
                }
                parsed.display = value
                index += 1
                continue
            }
            if arg == "--property" {
                guard let value = flagValue(args, index: index) else {
                    parsed.error = "Missing value for --property."
                    return parsed
                }
                parsed.property = value
                index += 2
                continue
            }
            if arg.hasPrefix("--property=") {
                let value = String(arg.dropFirst("--property=".count))
                if value.isEmpty {
                    parsed.error = "Missing value for --property."
                    return parsed
                }
                parsed.property = value
                index += 1
                continue
            }
            if arg.hasPrefix("-"), !isSignedNumber(arg) {
                parsed.error = "Unknown option: \(arg)"
                return parsed
            }
            if parsed.command == nil {
                parsed.command = arg
            } else {
                parsed.positionals.append(arg)
            }
            index += 1
        }
        return parsed
    }

    private static func flagValue(_ args: [String], index: Int) -> String? {
        let next = index + 1
        guard next < args.count else { return nil }
        let value = args[next]
        if value.hasPrefix("--") { return nil }
        if value.hasPrefix("-"), !isSignedNumber(value) { return nil }
        return value
    }

    private static func isSignedNumber(_ value: String) -> Bool {
        if value.hasPrefix("+-") {
            return Double(value.dropFirst(2)) != nil
        }
        if value.hasPrefix("+") || value.hasPrefix("-") {
            return Double(value) != nil
        }
        return false
    }

    /// Drops AppKit / Launch Services arguments so the GUI still starts under Xcode.
    private static func stripLaunchArgs(_ args: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg.hasPrefix("-psn_") {
                index += 1
                continue
            }
            if arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") || arg.hasPrefix("-_NS") {
                index += 1
                if index < args.count, !args[index].hasPrefix("-") {
                    index += 1
                }
                continue
            }
            result.append(arg)
            index += 1
        }
        return result
    }

    // MARK: - Hidden self-test

    static func runURLSelfTest() -> Int32 {
        var failures = 0

        func expect(_ urlString: String, _ check: (RemoteCommand) -> Bool) {
            guard let url = URL(string: urlString), let command = URLCommands.parse(url), check(command) else {
                StandardError.write("FAIL \(urlString)")
                failures += 1
                return
            }
            print("OK \(urlString)")
        }

        func expectNil(_ urlString: String) {
            guard let url = URL(string: urlString) else {
                StandardError.write("FAIL (bad url) \(urlString)")
                failures += 1
                return
            }
            if URLCommands.parse(url) != nil {
                StandardError.write("FAIL expected nil \(urlString)")
                failures += 1
                return
            }
            print("OK nil \(urlString)")
        }

        expect("brightbar://set?brightness=40") { command in
            command.action == .set && command.property == .brightness && command.value == 40 && !command.relative
        }
        expect("brightbar://set?brightness=40&display=1") { command in
            command.display == "1" && command.value == 40
        }
        expect("brightbar://set?contrast=50") { command in
            command.property == .contrast && command.value == 50 && !command.relative
        }
        expect("brightbar://set?volume=30") { command in
            command.property == .volume && command.value == 30
        }
        expect("brightbar://adjust?brightness=%2B10") { command in
            command.action == .set && command.relative && command.value == 10 && command.property == .brightness
        }
        expect("brightbar://adjust?brightness=-10") { command in
            command.action == .set && command.relative && command.value == -10
        }
        expect("brightbar://adjust?brightness=+10") { command in
            command.action == .set && command.relative && command.value == 10
        }
        expect("brightbar://preset/Night") { command in
            command.action == .preset && command.preset == "Night"
        }
        expect("brightbar://preset?name=Night") { command in
            command.action == .preset && command.preset == "Night"
        }
        expect("brightbar://input?source=hdmi1") { command in
            command.action == .input && command.input == "hdmi1"
        }
        expect("brightbar://input?source=hdmi1&display=Dell") { command in
            command.input == "hdmi1" && command.display == "Dell"
        }
        expect("brightbar://mute?state=toggle") { command in
            command.action == .mute && command.mute == .toggle
        }
        expect("brightbar://power?state=off") { command in
            command.action == .power && command.power == .off
        }

        var plusAdjust = URLComponents()
        plusAdjust.scheme = "brightbar"
        plusAdjust.host = "adjust"
        plusAdjust.queryItems = [URLQueryItem(name: "brightness", value: "+10")]
        if let url = plusAdjust.url, let command = URLCommands.parse(url), command.relative, command.value == 10 {
            print("OK URLComponents adjust +10")
        } else {
            StandardError.write("FAIL URLComponents adjust +10")
            failures += 1
        }

        expectNil("https://example.com/set?brightness=40")
        expectNil("brightbar://unknown")
        expectNil("brightbar://set")
        expectNil("brightbar://preset")
        expectNil("brightbar://input")
        expectNil("brightbar://power")

        return failures == 0 ? 0 : 1
    }
}

enum StandardError {
    static func write(_ message: String) {
        let line = message.hasSuffix("\n") ? message : message + "\n"
        guard let data = line.data(using: .utf8) else { return }
        try? FileHandle.standardError.write(contentsOf: data)
    }
}
