import Foundation

/// Pure parser for the `brightbar://` URL scheme. The integrator calls this from
/// `application(_:open:)` and feeds the result into the same handler as `RemoteCommandServer`.
enum URLCommands {
    static func parse(_ url: URL) -> RemoteCommand? {
        guard let scheme = url.scheme, scheme.caseInsensitiveCompare("brightbar") == .orderedSame else {
            return nil
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let host = (components?.host ?? url.host)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pathParts = (components?.path ?? url.path)
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }

        let command: String
        var remainder: [String] = []
        if let host, !host.isEmpty {
            command = host.lowercased()
            remainder = pathParts
        } else if let first = pathParts.first {
            command = first.lowercased()
            remainder = Array(pathParts.dropFirst())
        } else {
            return nil
        }

        let items = components?.queryItems ?? []
        let display = query(items, "display")

        switch command {
        case "set":
            return parseSet(items: items, display: display, relative: false)
        case "adjust":
            return parseSet(items: items, display: display, relative: true)
        case "preset":
            let name = query(items, "name") ?? remainder.first
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { return nil }
            return RemoteCommand(action: .preset, display: display, preset: trimmed)
        case "input":
            let source = query(items, "source") ?? query(items, "input") ?? remainder.first
            let trimmed = source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { return nil }
            return RemoteCommand(action: .input, display: display, input: trimmed)
        case "mute":
            let raw = (query(items, "state") ?? query(items, "mute") ?? "toggle")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let op: RemoteCommand.MuteOp
            switch raw {
            case "", "toggle": op = .toggle
            case "on", "mute", "muted", "1", "true": op = .on
            case "off", "unmute", "unmuted", "0", "false": op = .off
            default: return nil
            }
            return RemoteCommand(action: .mute, display: display, mute: op)
        case "power":
            let raw = (query(items, "state") ?? query(items, "power") ?? remainder.first ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let op: RemoteCommand.PowerOp
            switch raw {
            case "on": op = .on
            case "standby": op = .standby
            case "off": op = .off
            default: return nil
            }
            return RemoteCommand(action: .power, display: display, power: op)
        default:
            return nil
        }
    }

    private static func parseSet(
        items: [URLQueryItem],
        display: String?,
        relative: Bool
    ) -> RemoteCommand? {
        let candidates: [(RemoteCommand.Property, String)] = [
            (.brightness, "brightness"),
            (.contrast, "contrast"),
            (.volume, "volume"),
        ]
        for (property, key) in candidates {
            guard let raw = query(items, key) else { continue }
            guard let parsed = parseNumber(raw, forceRelative: relative) else { return nil }
            return RemoteCommand(
                action: .set,
                display: display,
                property: property,
                value: parsed.value,
                relative: parsed.relative
            )
        }
        return nil
    }

    /// Query values: `+10` may arrive as `+10`, `%2B10`, or ` 10` (`+` decoded as space).
    static func parseNumber(_ raw: String, forceRelative: Bool) -> (value: Double, relative: Bool)? {
        let original = raw
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        if trimmed.hasPrefix("+-") {
            guard let magnitude = Double(String(trimmed.dropFirst(2))) else { return nil }
            return (-magnitude, true)
        }

        let plusWasSpace = original.hasPrefix(" ") && !trimmed.hasPrefix("-") && !trimmed.hasPrefix("+")
        if plusWasSpace {
            guard let value = Double(trimmed) else { return nil }
            return (value, true)
        }

        if trimmed.hasPrefix("+") {
            guard let value = Double(trimmed) else { return nil }
            return (value, true)
        }

        guard let value = Double(trimmed) else { return nil }
        return (value, forceRelative)
    }

    private static func query(_ items: [URLQueryItem], _ name: String) -> String? {
        items.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
