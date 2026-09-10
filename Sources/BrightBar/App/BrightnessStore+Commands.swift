import Foundation

@MainActor
extension BrightnessStore {
    func handle(_ command: RemoteCommand) async -> RemoteReply {
        switch command.action {
        case .list:
            return listReply()
        case .get:
            return getReply(command)
        case .set:
            return setReply(command)
        case .mute:
            return muteReply(command)
        case .input:
            return inputReply(command)
        case .power:
            return powerReply(command)
        case .preset:
            return presetReply(command)
        case .probe:
            return await probeReply()
        }
    }

    private func listReply() -> RemoteReply {
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
                    brightness: brightness[display.id].map { Int($0.rounded()) }
                )
            )
        }
        return .success(payload: PayloadJSON.encode(items))
    }

    private func getReply(_ command: RemoteCommand) -> RemoteReply {
        switch DisplaySelector.resolve(command.display, in: displays) {
        case .failure(let reply):
            return reply
        case .success(let selected):
            let property = command.property ?? .brightness
            var items: [PropertyReadPayload] = []
            for display in selected {
                guard let item = read(property, on: display) else {
                    return .failure(code: 3, message: "Failed to read \(property.rawValue) from \(display.name).")
                }
                items.append(item)
            }
            return .success(payload: PayloadJSON.encode(items))
        }
    }

    private func setReply(_ command: RemoteCommand) -> RemoteReply {
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
            for display in selected {
                let current: Double?
                if command.relative {
                    current = numericValue(property, on: display)
                    if current == nil {
                        return .failure(code: 3, message: "Failed to read \(property.rawValue) from \(display.name).")
                    }
                } else {
                    current = nil
                }

                var target = command.relative ? (current ?? 0) + requested : requested
                switch property {
                case .brightness:
                    target = min(Self.maximumLevel, max(Self.minimumLevel, target))
                    setLevel(target, for: display, source: .user)
                case .contrast:
                    target = min(100, max(0, target))
                    setContrast(target, for: display)
                case .volume:
                    target = min(100, max(0, target))
                    setVolume(target, for: display)
                case .mute, .input:
                    break
                }
            }
            return .success()
        }
    }

    private func muteReply(_ command: RemoteCommand) -> RemoteReply {
        let op = command.mute ?? .toggle
        switch DisplaySelector.resolve(command.display, in: displays) {
        case .failure(let reply):
            return reply
        case .success(let selected):
            for display in selected {
                switch op {
                case .on:
                    setMuted(true, for: display)
                case .off:
                    setMuted(false, for: display)
                case .toggle:
                    toggleMute(for: display)
                }
            }
            return .success()
        }
    }

    private func inputReply(_ command: RemoteCommand) -> RemoteReply {
        guard let raw = command.input, let code = InputSourceParser.parse(raw) else {
            return .failure(code: 1, message: "Unknown input source '\(command.input ?? "")'.")
        }
        switch DisplaySelector.resolve(command.display, in: displays) {
        case .failure(let reply):
            return reply
        case .success(let selected):
            for display in selected {
                setInputSource(code, for: display)
            }
            return .success()
        }
    }

    private func powerReply(_ command: RemoteCommand) -> RemoteReply {
        guard let op = command.power else {
            return .failure(code: 1, message: "Missing power mode.")
        }
        switch DisplaySelector.resolve(command.display, in: displays) {
        case .failure(let reply):
            return reply
        case .success(let selected):
            for display in selected {
                setPower(op.mode, for: display)
            }
            return .success()
        }
    }

    private func presetReply(_ command: RemoteCommand) -> RemoteReply {
        guard let name = command.preset, !name.isEmpty else {
            return .failure(code: 1, message: "Missing preset name.")
        }
        guard let found = settings.settings.presets.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return .failure(code: 1, message: "Preset '\(name)' not found.")
        }
        switch DisplaySelector.resolve(command.display, in: displays) {
        case .failure(let reply):
            return reply
        case .success(let selected):
            if selected.count == displays.count {
                applyPreset(found)
            } else {
                for display in selected {
                    setLevel(found.brightness, for: display, source: .preset)
                    if let contrast = found.contrast {
                        setContrast(contrast, for: display)
                    }
                }
            }
            return .success()
        }
    }

    private func probeReply() async -> RemoteReply {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: RemoteReply.success(payload: DDCProbe.report()))
            }
        }
    }

    private func read(_ property: RemoteCommand.Property, on display: ExternalDisplay) -> PropertyReadPayload? {
        switch property {
        case .brightness:
            guard let value = brightness[display.id] else { return nil }
            return PropertyReadPayload(
                name: display.name,
                id: display.id,
                property: property.rawValue,
                value: String(Int(value.rounded())),
                code: nil
            )
        case .contrast:
            guard let value = contrast[display.id] else { return nil }
            return PropertyReadPayload(
                name: display.name,
                id: display.id,
                property: property.rawValue,
                value: String(Int(value.rounded())),
                code: nil
            )
        case .volume:
            guard let value = volume[display.id] else { return nil }
            return PropertyReadPayload(
                name: display.name,
                id: display.id,
                property: property.rawValue,
                value: String(Int(value.rounded())),
                code: nil
            )
        case .mute:
            guard let isMuted = muted[display.id] else { return nil }
            return PropertyReadPayload(
                name: display.name,
                id: display.id,
                property: property.rawValue,
                value: isMuted ? "muted" : "unmuted",
                code: nil
            )
        case .input:
            guard let code = inputSource[display.id] else { return nil }
            return PropertyReadPayload(
                name: display.name,
                id: display.id,
                property: property.rawValue,
                value: InputSourceParser.describe(code),
                code: code
            )
        }
    }

    private func numericValue(_ property: RemoteCommand.Property, on display: ExternalDisplay) -> Double? {
        switch property {
        case .brightness: return brightness[display.id]
        case .contrast: return contrast[display.id]
        case .volume: return volume[display.id]
        case .mute, .input: return nil
        }
    }
}
