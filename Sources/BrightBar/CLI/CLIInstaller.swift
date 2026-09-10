import Foundation

enum CLIInstallerError: Error, LocalizedError, Equatable {
    case executableNotFound
    case notWritable(link: String, destination: String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Could not locate the BrightBar executable."
        case .notWritable(let link, let destination):
            return "Cannot write \(link). Try: sudo ln -s \(destination) \(link)"
        }
    }
}

enum CLIInstaller {
    static let linkPath = "/usr/local/bin/brightbar"
    private static let binDirectory = "/usr/local/bin"

    static var isInstalled: Bool {
        guard let expected = executablePath else { return false }
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath) else {
            return false
        }
        let resolved = URL(fileURLWithPath: dest).resolvingSymlinksInPath().path
        return resolved == expected
    }

    static func install() throws {
        guard let destination = executablePath else {
            throw CLIInstallerError.executableNotFound
        }

        let fm = FileManager.default
        if !fm.fileExists(atPath: binDirectory) {
            do {
                try fm.createDirectory(atPath: binDirectory, withIntermediateDirectories: true)
            } catch {
                throw CLIInstallerError.notWritable(link: linkPath, destination: destination)
            }
        }

        if let existing = try? fm.destinationOfSymbolicLink(atPath: linkPath) {
            let resolved = URL(fileURLWithPath: existing).resolvingSymlinksInPath().path
            if resolved == destination {
                return
            }
            do {
                try fm.removeItem(atPath: linkPath)
            } catch {
                throw CLIInstallerError.notWritable(link: linkPath, destination: destination)
            }
        } else if fm.fileExists(atPath: linkPath) {
            do {
                try fm.removeItem(atPath: linkPath)
            } catch {
                throw CLIInstallerError.notWritable(link: linkPath, destination: destination)
            }
        }

        do {
            try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: destination)
        } catch {
            throw CLIInstallerError.notWritable(link: linkPath, destination: destination)
        }
    }

    private static var executablePath: String? {
        Bundle.main.executableURL?.resolvingSymlinksInPath().path
    }
}
