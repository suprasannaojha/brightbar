import Foundation

/// Listens for `com.brightbar.command` distributed notifications and posts
/// `com.brightbar.reply.<uuid>` with `deliverImmediately: true`.
///
/// The integrator constructs this on the main actor (typically from `AppDelegate`)
/// with a handler that applies the command to `BrightnessStore`.
@MainActor
final class RemoteCommandServer {
    typealias Handler = (RemoteCommand) async -> RemoteReply

    private let box: HandlerBox
    private let observerBox = ObserverBox()

    init(handler: @escaping Handler) {
        self.box = HandlerBox(handler)
    }

    func start() {
        stop()
        let box = self.box
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: RemoteIPC.commandName,
            object: nil,
            queue: .main
        ) { notification in
            let payload = notification.userInfo?[RemoteIPC.payloadKey] as? String
            let replyTo = notification.userInfo?[RemoteIPC.replyToKey] as? String
            Task { @MainActor in
                await RemoteCommandServer.process(payload: payload, replyTo: replyTo, handler: box)
            }
        }
        observerBox.set(observer)
    }

    func stop() {
        observerBox.set(nil)
    }

    @MainActor
    private static func process(payload: String?, replyTo: String?, handler: HandlerBox) async {
        guard let replyTo else { return }
        let reply: RemoteReply
        if let payload,
           let data = payload.data(using: .utf8),
           let command = try? JSONDecoder().decode(RemoteCommand.self, from: data) {
            reply = await handler.call(command)
        } else {
            reply = .failure(code: 1, message: "Invalid command.")
        }
        guard let json = RemoteIPC.encode(reply) else {
            let fallback = RemoteIPC.encode(.failure(code: 3, message: "Failed to encode reply.")) ?? #"{"ok":false,"message":"Failed to encode reply.","payload":"","code":3}"#
            DistributedNotificationCenter.default().postNotificationName(
                RemoteIPC.replyName(replyTo),
                object: nil,
                userInfo: [RemoteIPC.payloadKey: fallback],
                deliverImmediately: true
            )
            return
        }

        DistributedNotificationCenter.default().postNotificationName(
            RemoteIPC.replyName(replyTo),
            object: nil,
            userInfo: [RemoteIPC.payloadKey: json],
            deliverImmediately: true
        )
    }
}

/// `@unchecked Sendable` so the DNC callback can hop to the handler without isolation warnings.
private final class HandlerBox: @unchecked Sendable {
    let call: (RemoteCommand) async -> RemoteReply

    init(_ call: @escaping (RemoteCommand) async -> RemoteReply) {
        self.call = call
    }
}

private final class ObserverBox: @unchecked Sendable {
    private let lock = NSLock()
    private var observer: NSObjectProtocol?

    func set(_ next: NSObjectProtocol?) {
        lock.lock()
        let previous = observer
        observer = next
        lock.unlock()
        if let previous {
            DistributedNotificationCenter.default().removeObserver(previous)
        }
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }
}
