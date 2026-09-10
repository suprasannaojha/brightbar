import AppKit
import CoreGraphics
import Foundation

/// `BrightnessController` is not Sendable (defined in Core). Hardware access is
/// serialized onto background queues by this store; the box only exists to satisfy
/// the compiler when hopping off the main actor.
private final class ControllerHandle: @unchecked Sendable {
    let controller: BrightnessController
    init(_ controller: BrightnessController) {
        self.controller = controller
    }
}

@MainActor
final class BrightnessStore: ObservableObject {
    static let minimumLevel: Double = -50
    static let maximumLevel: Double = 100

    @Published var displays: [ExternalDisplay] = []
    /// Per-display level in `minimumLevel...maximumLevel`. Values `>= 0` are DDC
    /// brightness; values `< 0` keep hardware at 0 and apply software dimming.
    @Published var brightness: [CGDirectDisplayID: Double] = [:]
    @Published var unsupported: Set<CGDirectDisplayID> = []
    @Published var isRefreshing = false

    private let controllerHandle: ControllerHandle
    private let dimmer = SoftwareDimmer()
    private let hardwareQueue = DispatchQueue(label: "com.brightbar.hardware", qos: .userInitiated)
    private var pendingWrites: [CGDirectDisplayID: DispatchWorkItem] = [:]
    private var hardwareTarget: [CGDirectDisplayID: Int] = [:]
    private var lastSoftwareLevel: [CGDirectDisplayID: Double] = [:]
    private var displayChangeWorkItem: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?
    private var refreshGeneration = 0
    private var shouldReapplySoftwareDim = false

    init(controller: BrightnessController) {
        self.controllerHandle = ControllerHandle(controller)

        // IDs from CoreGraphics are unstable for about a second after plug/unplug.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleRefreshAfterDisplayChange()
            }
        }

        refresh()
    }

    deinit {
        pendingWrites.values.forEach { $0.cancel() }
        displayChangeWorkItem?.cancel()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    func shutdown() {
        pendingWrites.values.forEach { $0.cancel() }
        pendingWrites.removeAll()
        dimmer.clearAll()
    }

    func refresh() {
        isRefreshing = true
        refreshGeneration += 1
        let generation = refreshGeneration
        let previousBrightness = brightness
        let previousIDs = Set(displays.map(\.id))
        let handle = controllerHandle

        DispatchQueue.global(qos: .userInitiated).async {
            let controller = handle.controller
            let displays = controller.refreshDisplays()
            var nextBrightness: [CGDirectDisplayID: Double] = [:]
            var unsupported: Set<CGDirectDisplayID> = []

            for display in displays {
                let previous = previousBrightness[display.id]
                if let value = controller.readBrightness(for: display) {
                    if let previous, previous < 0, value == 0 {
                        nextBrightness[display.id] = previous
                    } else {
                        nextBrightness[display.id] = Double(value)
                    }
                } else {
                    unsupported.insert(display.id)
                    if let previous, previous < 0 {
                        nextBrightness[display.id] = previous
                    } else {
                        nextBrightness[display.id] = 0
                    }
                }
            }

            Task { @MainActor [weak self] in
                guard let self, generation == self.refreshGeneration else { return }

                let liveIDs = Set(displays.map(\.id))
                let staleIDs = previousIDs.union(self.lastSoftwareLevel.keys).subtracting(liveIDs)
                for id in staleIDs {
                    self.pendingWrites[id]?.cancel()
                    self.pendingWrites.removeValue(forKey: id)
                    self.hardwareTarget.removeValue(forKey: id)
                    self.lastSoftwareLevel.removeValue(forKey: id)
                    self.dimmer.clear(for: id)
                }

                var brightness = nextBrightness
                for (id, work) in self.pendingWrites where !work.isCancelled {
                    if let pending = self.brightness[id] {
                        brightness[id] = pending
                    }
                }

                self.displays = displays
                self.brightness = brightness
                self.unsupported = unsupported
                self.reconcileSoftwareDimming(reapply: self.shouldReapplySoftwareDim)
                self.shouldReapplySoftwareDim = false
                self.isRefreshing = false
            }
        }
    }

    func setBrightness(_ value: Double, for display: ExternalDisplay) {
        let isUnsupported = unsupported.contains(display.id)
        let upper = isUnsupported ? 0 : Self.maximumLevel
        let clamped = min(max(value, Self.minimumLevel), upper)
        brightness[display.id] = clamped
        applySoftwareDimmingIfNeeded(clamped, for: display.id)

        if isUnsupported { return }

        let hardwareValue = Int(max(0, clamped).rounded())
        if hardwareTarget[display.id] == 0, hardwareValue == 0 {
            return
        }

        hardwareTarget[display.id] = hardwareValue
        pendingWrites[display.id]?.cancel()

        let handle = controllerHandle
        let displayID = display.id
        var work: DispatchWorkItem!
        work = DispatchWorkItem {
            handle.controller.setBrightness(hardwareValue, for: display)
            Task { @MainActor [weak self] in
                guard let self, self.pendingWrites[displayID] === work else { return }
                self.pendingWrites.removeValue(forKey: displayID)
            }
        }
        pendingWrites[display.id] = work
        hardwareQueue.asyncAfter(deadline: .now() + 0.07, execute: work)
    }

    func setAll(_ value: Double) {
        let clamped = min(max(value, Self.minimumLevel), Self.maximumLevel)
        for display in displays {
            setBrightness(clamped, for: display)
        }
    }

    func adjustAll(by delta: Double) {
        for display in displays {
            let current = brightness[display.id] ?? 0
            setBrightness(current + delta, for: display)
        }
    }

    private func softwareLevel(for value: Double) -> Double {
        value < 0 ? min(1.0, -value / -Self.minimumLevel) : 0
    }

    private func applySoftwareDimmingIfNeeded(_ value: Double, for displayID: CGDirectDisplayID) {
        let level = softwareLevel(for: value)
        let previous = lastSoftwareLevel[displayID] ?? 0
        guard abs(level - previous) > 0.005 else { return }
        lastSoftwareLevel[displayID] = level
        dimmer.setLevel(level, for: displayID)
    }

    private func reconcileSoftwareDimming(reapply: Bool) {
        for display in displays {
            let id = display.id
            let value = brightness[id] ?? 0
            if value < 0 {
                lastSoftwareLevel[id] = softwareLevel(for: value)
                hardwareTarget[id] = 0
            } else {
                if (lastSoftwareLevel[id] ?? 0) > 0.005 {
                    dimmer.clear(for: id)
                }
                lastSoftwareLevel[id] = 0
                if pendingWrites[id] == nil {
                    hardwareTarget[id] = Int(value.rounded())
                }
            }
        }

        if reapply {
            dimmer.reapplyAll()
        }
    }

    private func scheduleRefreshAfterDisplayChange() {
        displayChangeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.shouldReapplySoftwareDim = true
                self?.refresh()
            }
        }
        displayChangeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
}
