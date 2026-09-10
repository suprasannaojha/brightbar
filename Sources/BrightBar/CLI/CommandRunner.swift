import Foundation

enum DisplaySelector {
    /// Resolves `--display` to one or more connected displays.
    /// Priority: `all`, 1-based index, `CGDirectDisplayID`, exact name, unique substring.
    static func resolve(_ selector: String?, in displays: [ExternalDisplay]) -> Result<[ExternalDisplay], RemoteReply> {
        let raw = selector?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty || raw.caseInsensitiveCompare("all") == .orderedSame {
            if displays.isEmpty {
                return .failure(.failure(code: 2, message: "No external displays found."))
            }
            return .success(displays)
        }

        if let number = UInt32(raw) {
            if number >= 1, number <= UInt32(displays.count) {
                return .success([displays[Int(number) - 1]])
            }
            if let match = displays.first(where: { $0.id == number }) {
                return .success([match])
            }
            return .failure(.failure(code: 2, message: "Display '\(raw)' not found."))
        }

        let exact = displays.filter { $0.name.caseInsensitiveCompare(raw) == .orderedSame }
        if !exact.isEmpty {
            return .success(exact)
        }

        let substring = displays.filter {
            $0.name.range(of: raw, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        if substring.isEmpty {
            return .failure(.failure(code: 2, message: "Display '\(raw)' not found."))
        }
        if substring.count > 1 {
            let names = substring.map(\.name).joined(separator: ", ")
            return .failure(.failure(code: 2, message: "Display '\(raw)' is ambiguous: \(names)."))
        }
        return .success(substring)
    }
}

enum CLIFormat {
    static func list(_ items: [DisplayInfoPayload], json: Bool) -> String {
        if json {
            return prettyJSON(items) ?? "[]"
        }
        if items.isEmpty {
            return "No external displays."
        }

        let indexH = "#"
        let nameH = "NAME"
        let idH = "ID"
        let keyH = "KEY"
        let capsH = "CAPABILITIES"
        let brightH = "BRIGHTNESS"

        let indexW = max(indexH.count, items.map { String($0.index).count }.max() ?? 0)
        let nameW = max(nameH.count, items.map(\.name.count).max() ?? 0)
        let idW = max(idH.count, items.map { String($0.id).count }.max() ?? 0)
        let keyW = max(keyH.count, items.map(\.persistentKey.count).max() ?? 0)
        let capsW = max(capsH.count, items.map { $0.capabilities.joined(separator: " ").count }.max() ?? 0)

        var lines: [String] = []
        lines.append(
            pad(indexH, indexW) + "  " +
            pad(nameH, nameW) + "  " +
            pad(idH, idW) + "  " +
            pad(keyH, keyW) + "  " +
            pad(capsH, capsW) + "  " +
            brightH
        )
        for item in items {
            let caps = item.capabilities.isEmpty ? "-" : item.capabilities.joined(separator: " ")
            lines.append(
                pad(String(item.index), indexW) + "  " +
                pad(item.name, nameW) + "  " +
                pad(String(item.id), idW) + "  " +
                pad(item.persistentKey, keyW) + "  " +
                pad(caps, capsW) + "  " +
                brightnessText(item.brightness)
            )
        }
        return lines.joined(separator: "\n")
    }

    static func get(_ items: [PropertyReadPayload], json: Bool, label: Bool) -> String {
        if json {
            return getJSON(items)
        }
        if items.isEmpty { return "" }
        if label {
            return items.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
        }
        return items.map(\.value).joined(separator: "\n")
    }

    static func capabilityTags(_ caps: DisplayCapabilities) -> [String] {
        var tags: [String] = []
        if caps.supportsDDC { tags.append("ddc") }
        if caps.supportsNativeBrightness { tags.append("native") }
        if caps.supportsContrast { tags.append("contrast") }
        if caps.supportsAudio { tags.append("audio") }
        return tags
    }

    private static func brightnessText(_ value: Int?) -> String {
        if let value { return String(value) }
        return "n/a"
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        if text.count >= width { return text }
        return text + String(repeating: " ", count: width - text.count)
    }

    private static func prettyJSON<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func getJSON(_ items: [PropertyReadPayload]) -> String {
        let objects: [[String: Any]] = items.map { item in
            var object: [String: Any] = [
                "name": item.name,
                "id": Int(item.id),
                "property": item.property,
            ]
            switch item.property {
            case RemoteCommand.Property.mute.rawValue:
                object["value"] = (item.value == "muted")
            case RemoteCommand.Property.input.rawValue:
                object["value"] = item.value
                if let code = item.code {
                    object["code"] = Int(code)
                }
            default:
                if let number = Int(item.value) {
                    object["value"] = number
                } else {
                    object["value"] = item.value
                }
            }
            return object
        }
        guard JSONSerialization.isValidJSONObject(objects),
              let data = try? JSONSerialization.data(
                withJSONObject: objects,
                options: [.prettyPrinted, .sortedKeys]
              ),
              let text = String(data: data, encoding: .utf8)
        else { return "[]" }
        return text
    }
}

enum DirectCommandRunner {
    static func run(_ command: RemoteCommand) -> RemoteReply {
        if command.action == .probe {
            return .success(payload: DDCProbe.report())
        }

        let controller = DDCBrightnessController()
        let displays = controller.refreshDisplays()

        switch command.action {
        case .list:
            return list(displays: displays, controller: controller)
        case .get:
            return get(command, displays: displays, controller: controller)
        case .set:
            return set(command, displays: displays, controller: controller, allowSoftwareDimming: false)
        case .mute:
            return mute(command, displays: displays, controller: controller)
        case .input:
            return input(command, displays: displays, controller: controller)
        case .power:
            return power(command, displays: displays, controller: controller)
        case .preset:
            return preset(command, displays: displays, controller: controller)
        case .probe:
            return .success(payload: DDCProbe.report())
        }
    }

    static func list(displays: [ExternalDisplay], controller: BrightnessController) -> RemoteReply {
        var items: [DisplayInfoPayload] = []
        items.reserveCapacity(displays.count)
        for (index, display) in displays.enumerated() {
            items.append(
                DisplayInfoPayload(
                    index: index + 1,
                    name: display.name,
                    id: display.id,
                    persistentKey: display.persistentKey,
                    capabilities: CLIFormat.capabilityTags(display.capabilities),
                    brightness: controller.readBrightness(for: display)
                )
            )
        }
        return .success(payload: PayloadJSON.encode(items))
    }

    static func get(
        _ command: RemoteCommand,
        displays: [ExternalDisplay],
        controller: BrightnessController
    ) -> RemoteReply {
        switch DisplaySelector.resolve(command.display, in: displays) {
        case .failure(let reply):
            return reply
        case .success(let selected):
            let property = command.property ?? .brightness
            var items: [PropertyReadPayload] = []
            for display in selected {
                guard let item = read(property, on: display, controller: controller) else {
                    return .failure(code: 3, message: "Failed to read \(property.rawValue) from \(display.name).")
                }
                items.append(item)
            }
            return .success(payload: PayloadJSON.encode(items))
        }
    }

    static func set(
        _ command: RemoteCommand,
        displays: [ExternalDisplay],
        controller: BrightnessController,
        allowSoftwareDimming: Bool
    ) -> RemoteReply {
        let property = command.property ?? .brightness
        guard property == .brightness || property == .contrast || property == .volume else {
            return .failure(code: 1, message: "Cannot set \(property.rawValue).")
        }
        guard let requested = command.value else {
            return .failure(code: 1, message: "Missing value.")
        }

        switch DisplaySelector.resolve(command.display, in: displays) {
        case .failure(let reply):
            return reply
        case .success(let selected):
            var warning = ""
            var failed: [String] = []
            for display in selected {
                let current: Int?
                if command.relative {
                    current = readNumeric(property, on: display, controller: controller)
                    if current == nil {
                        return .failure(code: 3, message: "Failed to read \(property.rawValue) from \(display.name).")
                    }
                } else {
                    current = nil
                }

                var target = command.relative ? (current ?? 0) + Int(requested.rounded()) : Int(requested.rounded())
                if property == .brightness {
                    if target < 0 && !allowSoftwareDimming {
                        warning = "Software dimming requires the BrightBar app; clamping brightness to 0."
                        target = 0
                    }
                    let lo = allowSoftwareDimming ? -50 : 0
                    target = min(100, max(lo, target))
                } else {
                    target = min(100, max(0, target))
                }

                let ok: Bool
                switch property {
                case .brightness:
                    ok = controller.setBrightness(target, for: display)
                case .contrast:
                    ok = controller.setContrast(target, for: display)
                case .volume:
                    ok = controller.setVolume(target, for: display)
                case .mute, .input:
                    ok = false
                }
                if !ok {
                    failed.append(display.name)
                }
            }
            if !failed.isEmpty {
                return .failure(
                    code: 3,
                    message: "Failed to set \(property.rawValue) on \(failed.joined(separator: ", "))."
                )
            }
            return .success(message: warning)
        }
    }

    static func mute(
        _ command: RemoteCommand,
        displays: [ExternalDisplay],
        controller: BrightnessController
    ) -> RemoteReply {
        let op = command.mute ?? .toggle
        switch DisplaySelector.resolve(command.display, in: displays) {
        case .failure(let reply):
            return reply
        case .success(let selected):
            var failed: [String] = []
            for display in selected {
                let muted: Bool
                switch op {
                case .on:
                    muted = true
                case .off:
                    muted = false
                case .toggle:
                    guard let current = controller.readMute(for: display) else {
                        return .failure(code: 3, message: "Failed to read mute from \(display.name).")
                    }
                    muted = !current
                }
                if !controller.setMute(muted, for: display) {
                    failed.append(display.name)
                }
            }
            if !failed.isEmpty {
                return .failure(code: 3, message: "Failed to set mute on \(failed.joined(separator: ", ")).")
            }
            return .success()
        }
    }

    static func input(
        _ command: RemoteCommand,
        displays: [ExternalDisplay],
        controller: BrightnessController
    ) -> RemoteReply {
        guard let raw = command.input, let code = InputSourceParser.parse(raw) else {
            return .failure(code: 1, message: "Unknown input source '\(command.input ?? "")'.")
        }
        switch DisplaySelector.resolve(command.display, in: displays) {
        case .failure(let reply):
            return reply
        case .success(let selected):
            var failed: [String] = []
            for display in selected {
                if !controller.setInputSource(code, for: display) {
                    failed.append(display.name)
                }
            }
            if !failed.isEmpty {
                return .failure(code: 3, message: "Failed to set input on \(failed.joined(separator: ", ")).")
            }
            return .success()
        }
    }

    static func power(
        _ command: RemoteCommand,
        displays: [ExternalDisplay],
        controller: BrightnessController
    ) -> RemoteReply {
        guard let op = command.power else {
            return .failure(code: 1, message: "Missing power mode.")
        }
        switch DisplaySelector.resolve(command.display, in: displays) {
        case .failure(let reply):
            return reply
        case .success(let selected):
            var failed: [String] = []
            for display in selected {
                if !controller.setPowerMode(op.mode, for: display) {
                    failed.append(display.name)
                }
            }
            if !failed.isEmpty {
                return .failure(code: 3, message: "Failed to set power on \(failed.joined(separator: ", ")).")
            }
            return .success()
        }
    }

    static func preset(
        _ command: RemoteCommand,
        displays: [ExternalDisplay],
        controller: BrightnessController
    ) -> RemoteReply {
        guard let name = command.preset, !name.isEmpty else {
            return .failure(code: 1, message: "Missing preset name.")
        }
        let settings = loadAppSettings()
        guard let found = settings.presets.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return .failure(code: 1, message: "Preset '\(name)' not found.")
        }
        switch DisplaySelector.resolve(command.display, in: displays) {
        case .failure(let reply):
            return reply
        case .success(let selected):
            return applyPreset(found, to: selected, controller: controller)
        }
    }

    private static func applyPreset(
        _ found: Preset,
        to displays: [ExternalDisplay],
        controller: BrightnessController
    ) -> RemoteReply {
        var warning = ""
        var failed: [String] = []
        for display in displays {
            var brightness = Int(found.brightness.rounded())
            if brightness < 0 {
                warning = "Software dimming requires the BrightBar app; clamping brightness to 0."
                brightness = 0
            }
            brightness = min(100, max(0, brightness))
            if !controller.setBrightness(brightness, for: display) {
                failed.append(display.name)
                continue
            }
            if let contrast = found.contrast {
                let value = min(100, max(0, Int(contrast.rounded())))
                if !controller.setContrast(value, for: display) {
                    failed.append(display.name)
                }
            }
        }
        if !failed.isEmpty {
            return .failure(code: 3, message: "Failed to apply preset on \(failed.joined(separator: ", ")).")
        }
        return .success(message: warning)
    }

    private static func read(
        _ property: RemoteCommand.Property,
        on display: ExternalDisplay,
        controller: BrightnessController
    ) -> PropertyReadPayload? {
        switch property {
        case .brightness:
            guard let value = controller.readBrightness(for: display) else { return nil }
            return PropertyReadPayload(name: display.name, id: display.id, property: property.rawValue, value: String(value), code: nil)
        case .contrast:
            guard let value = controller.readContrast(for: display) else { return nil }
            return PropertyReadPayload(name: display.name, id: display.id, property: property.rawValue, value: String(value), code: nil)
        case .volume:
            guard let value = controller.readVolume(for: display) else { return nil }
            return PropertyReadPayload(name: display.name, id: display.id, property: property.rawValue, value: String(value), code: nil)
        case .mute:
            guard let muted = controller.readMute(for: display) else { return nil }
            return PropertyReadPayload(
                name: display.name,
                id: display.id,
                property: property.rawValue,
                value: muted ? "muted" : "unmuted",
                code: nil
            )
        case .input:
            guard let code = controller.readInputSource(for: display) else { return nil }
            return PropertyReadPayload(
                name: display.name,
                id: display.id,
                property: property.rawValue,
                value: InputSourceParser.describe(code),
                code: code
            )
        }
    }

    private static func readNumeric(
        _ property: RemoteCommand.Property,
        on display: ExternalDisplay,
        controller: BrightnessController
    ) -> Int? {
        switch property {
        case .brightness: return controller.readBrightness(for: display)
        case .contrast: return controller.readContrast(for: display)
        case .volume: return controller.readVolume(for: display)
        case .mute, .input: return nil
        }
    }

    /// Reads the same UserDefaults blob as `SettingsStore` without hopping to the main actor.
    private static func loadAppSettings() -> AppSettings {
        let key = "com.brightbar.settings.v1"
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            return decoded
        }
        return AppSettings()
    }
}
