import AppKit
import os

/// LetsMove-style prompt to copy BrightBar into Applications and relaunch.
@MainActor
enum MoveToApplications {
    private static let log = Logger(subsystem: "com.brightbar.app", category: "install")
    private static let suppressKey = "com.brightbar.suppressMoveToApplications"
    private static let bundleIdentifier = "com.brightbar.app"
    private static let developmentMarkers = ["/.build/", "/build/", "/DerivedData/", "/Xcode/"]

    private static var relaunchFailed = false

    static func promptIfNeeded() {
        let dryRun = ProcessInfo.processInfo.environment["BRIGHTBAR_MOVE_DRY_RUN"] == "1"
        switch evaluate(createUserApplications: !dryRun) {
        case .skip(let reason):
            log.notice("Skipping move prompt: \(reason, privacy: .public)")
        case .prompt(let destination, let source, let original):
            if dryRun {
                log.notice("Would prompt to move BrightBar to \(destination.path, privacy: .public)")
                return
            }
            log.notice("Prompting to move BrightBar to \(destination.path, privacy: .public)")
            presentAlert(destination: destination, source: source, original: original)
        }
    }

    private enum Decision {
        case prompt(destination: URL, source: URL, original: URL)
        case skip(String)
    }

    private static func evaluate(createUserApplications: Bool) -> Decision {
        let source = Bundle.main.bundleURL
        guard source.pathExtension.lowercased() == "app" else {
            return .skip("not an app bundle")
        }

        let running = source.resolvingSymlinksInPath()
        if isDevelopmentBuild(running) {
            return .skip("development build")
        }

        let original = AppTranslocation.originalURL(for: source).resolvingSymlinksInPath()
        if isInsideApplications(running) || isInsideApplications(original) {
            return .skip("already in Applications")
        }

        if UserDefaults.standard.bool(forKey: suppressKey) {
            return .skip("user chose don't ask again")
        }

        guard let destination = preferredDestination(createUserApplications: createUserApplications) else {
            return .skip("Applications folders are not writable")
        }

        return .prompt(destination: destination, source: source, original: original)
    }

    private static func presentAlert(destination: URL, source: URL, original: URL) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Move BrightBar to the Applications folder?"
        alert.informativeText = "BrightBar works best from the Applications folder. It will be moved there and relaunched. The copy you opened will be moved to the Trash."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            performMove(from: source, original: original, to: destination)
            return
        }
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: suppressKey)
            log.notice("User chose don't ask again")
        }
    }

    private static func performMove(from source: URL, original: URL, to destination: URL) {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destination.path) {
                terminateInstance(at: destination)
                do {
                    try fm.trashItem(at: destination, resultingItemURL: nil)
                } catch {
                    try fm.removeItem(at: destination)
                }
            }

            try fm.copyItem(at: source, to: destination)
            stripQuarantine(at: destination)

            do {
                try fm.trashItem(at: original, resultingItemURL: nil)
            } catch {
                log.notice("Could not trash original copy at \(original.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }

            relaunch(at: destination)
        } catch {
            presentError(error)
        }
    }

    private static func terminateInstance(at destination: URL) {
        let destPath = destination.resolvingSymlinksInPath().path
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        for app in apps {
            if app == NSRunningApplication.current { continue }
            guard let runningURL = app.bundleURL else { continue }
            let runningPath = runningURL.resolvingSymlinksInPath().path
            guard runningPath.caseInsensitiveCompare(destPath) == .orderedSame else { continue }
            log.notice("Terminating existing BrightBar at \(destPath, privacy: .public)")
            app.terminate()
            let deadline = Date().addingTimeInterval(3)
            while !app.isTerminated, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
        }
    }

    private static func stripQuarantine(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log.notice("xattr failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func relaunch(at destination: URL) {
        log.notice("Relaunching from \(destination.path, privacy: .public)")
        relaunchFailed = false
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    relaunchFailed = true
                    presentError(error)
                    return
                }
                NSApp.terminate(nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !relaunchFailed {
                NSApp.terminate(nil)
            }
        }
    }

    private static func presentError(_ error: Error) {
        log.error("Move to Applications failed: \(error.localizedDescription, privacy: .public)")
        NSApp.activate(ignoringOtherApps: true)
        NSAlert(error: error).runModal()
    }

    private static func preferredDestination(createUserApplications: Bool) -> URL? {
        let fm = FileManager.default
        let systemFolder = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if fm.isWritableFile(atPath: systemFolder.path) {
            return systemFolder.appendingPathComponent("BrightBar.app", isDirectory: true)
        }

        let userFolder = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        if !fm.fileExists(atPath: userFolder.path) {
            guard createUserApplications else { return nil }
            do {
                try fm.createDirectory(at: userFolder, withIntermediateDirectories: true)
            } catch {
                log.error("Could not create ~/Applications: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        guard fm.isWritableFile(atPath: userFolder.path) else { return nil }
        return userFolder.appendingPathComponent("BrightBar.app", isDirectory: true)
    }

    private static func isInsideApplications(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        let folders = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
        for folder in folders {
            let folderPath = folder.resolvingSymlinksInPath().path
            if path.caseInsensitiveCompare(folderPath) == .orderedSame {
                return true
            }
            let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
            if path.lowercased().hasPrefix(prefix.lowercased()) {
                return true
            }
        }
        return false
    }

    private static func isDevelopmentBuild(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        return developmentMarkers.contains { path.localizedCaseInsensitiveContains($0) }
    }
}

// MARK: - App Translocation

private enum AppTranslocation {
    private typealias IsTranslocatedFn = @convention(c) (
        CFURL,
        UnsafeMutablePointer<Bool>,
        UnsafeMutablePointer<Unmanaged<CFError>?>?
    ) -> Bool

    private typealias OriginalPathFn = @convention(c) (
        CFURL,
        UnsafeMutablePointer<Unmanaged<CFError>?>?
    ) -> Unmanaged<CFURL>?

    private static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY)
    }()

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private static let isTranslocated = symbol("SecTranslocateIsTranslocatedURL", as: IsTranslocatedFn.self)
    private static let originalPath = symbol("SecTranslocateCreateOriginalPathForURL", as: OriginalPathFn.self)

    static func originalURL(for url: URL) -> URL {
        guard let isTranslocated, let originalPath else { return url }
        var flag = false
        guard isTranslocated(url as CFURL, &flag, nil), flag else { return url }
        guard let original = originalPath(url as CFURL, nil) else { return url }
        return original.takeRetainedValue() as URL
    }
}
