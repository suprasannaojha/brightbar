import AppKit
import Foundation

// MARK: - IPC names

enum RemoteIPC {
    static let commandName = Notification.Name("com.brightbar.command")
    static let payloadKey = "payload"
    static let replyToKey = "replyTo"
    static let timeout: TimeInterval = 1.5
    static let bundleIdentifier = "com.brightbar.app"

    static func replyName(_ id: String) -> Notification.Name {
        Notification.Name("com.brightbar.reply.\(id)")
    }

    /// True when another BrightBar process (the menu-bar app) is already running.
    static func isAppRunning() -> Bool {
        let identifier = Bundle.main.bundleIdentifier ?? bundleIdentifier
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .contains { $0.processIdentifier != mine && !$0.isTerminated }
    }

    /// Posts `command` and waits up to `timeout` for a reply. Returns nil on timeout / encode failure.
    static func send(_ command: RemoteCommand, timeout: TimeInterval = timeout) -> RemoteReply? {
        guard isAppRunning() else { return nil }
        guard let payload = encode(command) else { return nil }

        let replyTo = UUID().uuidString
        let replyName = replyName(replyTo)
        let box = ReplyBox()
        let center = DistributedNotificationCenter.default()
        let observer = center.addObserver(forName: replyName, object: nil, queue: nil) { notification in
            if let json = notification.userInfo?[payloadKey] as? String,
               let reply = RemoteReply.decode(json) {
                box.value = reply
            }
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        defer { center.removeObserver(observer) }

        center.postNotificationName(
            commandName,
            object: nil,
            userInfo: [payloadKey: payload, replyToKey: replyTo],
            deliverImmediately: true
        )

        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while box.value == nil {
            let remaining = deadline - CFAbsoluteTimeGetCurrent()
            if remaining <= 0 { break }
            let result = CFRunLoopRunInMode(.defaultMode, remaining, true)
            if result == .timedOut || result == .finished { break }
        }
        return box.value
    }

    static func encode(_ command: RemoteCommand) -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(command) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func encode(_ reply: RemoteReply) -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(reply) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private final class ReplyBox {
        var value: RemoteReply?
    }
}

// MARK: - Command / reply

/// Command posted by the CLI (and produced by `URLCommands.parse`) for the running app to execute.
struct RemoteCommand: Codable, Equatable {
    enum Action: String, Codable, Equatable {
        case list
        case get
        case set
        case mute
        case input
        case power
        case preset
        case probe
    }

    enum Property: String, Codable, Equatable {
        case brightness
        case contrast
        case volume
        case mute
        case input
    }

    enum MuteOp: String, Codable, Equatable {
        case on
        case off
        case toggle
    }

    enum PowerOp: String, Codable, Equatable {
        case on
        case standby
        case off

        var mode: PowerMode {
            switch self {
            case .on: return .on
            case .standby: return .standby
            case .off: return .off
            }
        }
    }

    var action: Action
    /// 1-based index, `CGDirectDisplayID`, name substring, or `"all"`. Nil means all.
    var display: String?
    var property: Property?
    /// Absolute target or relative delta, depending on `relative`.
    var value: Double?
    var relative: Bool
    var mute: MuteOp?
    var input: String?
    var power: PowerOp?
    var preset: String?

    var targetsAllDisplays: Bool {
        guard let display else { return true }
        return display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || display.caseInsensitiveCompare("all") == .orderedSame
    }

    init(
        action: Action,
        display: String? = nil,
        property: Property? = nil,
        value: Double? = nil,
        relative: Bool = false,
        mute: MuteOp? = nil,
        input: String? = nil,
        power: PowerOp? = nil,
        preset: String? = nil
    ) {
        self.action = action
        self.display = display
        self.property = property
        self.value = value
        self.relative = relative
        self.mute = mute
        self.input = input
        self.power = power
        self.preset = preset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(Action.self, forKey: .action)
        display = try container.decodeIfPresent(String.self, forKey: .display)
        property = try container.decodeIfPresent(Property.self, forKey: .property)
        value = try container.decodeIfPresent(Double.self, forKey: .value)
        relative = try container.decodeIfPresent(Bool.self, forKey: .relative) ?? false
        mute = try container.decodeIfPresent(MuteOp.self, forKey: .mute)
        input = try container.decodeIfPresent(String.self, forKey: .input)
        power = try container.decodeIfPresent(PowerOp.self, forKey: .power)
        preset = try container.decodeIfPresent(String.self, forKey: .preset)
    }
}

/// Reply posted back to the CLI. `payload` is JSON for `list`/`get` (see `DisplayInfoPayload` /
/// `PropertyReadPayload`); plain text for `probe`; empty for mutations.
struct RemoteReply: Codable, Equatable, Error {
    var ok: Bool
    var message: String
    var payload: String
    /// CLI exit code when `ok` is false: 1 usage, 2 display not found, 3 hardware.
    var code: Int32

    static func success(payload: String = "", message: String = "") -> RemoteReply {
        RemoteReply(ok: true, message: message, payload: payload, code: 0)
    }

    static func failure(code: Int32, message: String, payload: String = "") -> RemoteReply {
        RemoteReply(ok: false, message: message, payload: payload, code: code)
    }

    init(ok: Bool, message: String, payload: String, code: Int32) {
        self.ok = ok
        self.message = message
        self.payload = payload
        self.code = code
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        payload = try container.decodeIfPresent(String.self, forKey: .payload) ?? ""
        if let code = try container.decodeIfPresent(Int32.self, forKey: .code) {
            self.code = code
        } else {
            self.code = ok ? 0 : 3
        }
    }

    static func decode(_ json: String) -> RemoteReply? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RemoteReply.self, from: data)
    }
}

/// One row of `list` output. Integrator: encode `[DisplayInfoPayload]` into `RemoteReply.payload`.
struct DisplayInfoPayload: Codable, Equatable {
    var index: Int
    var name: String
    var id: UInt32
    var persistentKey: String
    var capabilities: [String]
    var brightness: Int?
}

/// One row of `get` output. Integrator: encode `[PropertyReadPayload]` into `RemoteReply.payload`.
struct PropertyReadPayload: Codable, Equatable {
    var name: String
    var id: UInt32
    var property: String
    var value: String
    var code: UInt16?
}

enum InputSourceParser {
    /// Resolves a CLI / URL input token to a VCP 0x60 code.
    static func parse(_ raw: String) -> UInt16? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("0x") {
            return UInt16(lower.dropFirst(2), radix: 16)
        }

        if let named = matchName(trimmed) {
            return named
        }

        return UInt16(trimmed)
    }

    static func describe(_ code: UInt16) -> String {
        if let source = InputSource(rawValue: code) {
            return "\(source.displayName) (\(hex(code)))"
        }
        return "Unknown (\(hex(code)))"
    }

    static func hex(_ code: UInt16) -> String {
        String(format: "0x%02X", code)
    }

    private static func compact(_ string: String) -> String {
        string.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func matchName(_ raw: String) -> UInt16? {
        let token = compact(raw)
        if token.isEmpty { return nil }

        for source in InputSource.allCases {
            var keys = Set<String>()
            keys.insert(compact(source.displayName))
            keys.formUnion(aliases(source))
            if keys.contains(token) {
                return source.rawValue
            }
        }
        return nil
    }

    private static func aliases(_ source: InputSource) -> Set<String> {
        switch source {
        case .hdmi1: return ["hdmi1", "hdmi"]
        case .hdmi2: return ["hdmi2"]
        case .displayPort1: return ["displayport1", "dp1", "dp"]
        case .displayPort2: return ["displayport2", "dp2"]
        case .usbC1: return ["usbc1", "usbc", "usbcable"]
        case .usbC2: return ["usbc2"]
        case .thunderbolt: return ["thunderbolt", "tb"]
        case .vga1: return ["vga", "vga1"]
        case .vga2: return ["vga2"]
        case .dvi1: return ["dvi", "dvi1"]
        case .dvi2: return ["dvi2"]
        case .compositeVideo1: return ["composite", "compositevideo", "compositevideo1"]
        case .sVideo1: return ["svideo", "svideo1"]
        }
    }
}

enum PayloadJSON {
    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    static func decodeList(_ payload: String) -> [DisplayInfoPayload]? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([DisplayInfoPayload].self, from: data)
    }

    static func decodeGet(_ payload: String) -> [PropertyReadPayload]? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([PropertyReadPayload].self, from: data)
    }
}
