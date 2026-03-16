import Foundation
import SwiftUI

/// Manages installation of CLI tools (sr, sr-mcp) from the app bundle
/// into /usr/local/bin via symlinks.
@MainActor
final class CLIInstaller: ObservableObject {
    static let shared = CLIInstaller()

    @Published var srInstalled: Bool = false
    @Published var mcpInstalled: Bool = false
    @Published var isInstalling: Bool = false
    @Published var statusMessage: String?

    private let installDir = "/usr/local/bin"

    private init() {
        checkInstallStatus()
    }

    /// The path to the running app's MacOS directory.
    private var macOSDir: String? {
        Bundle.main.bundlePath.appending("/Contents/MacOS")
    }

    // MARK: - Check Status

    func checkInstallStatus() {
        srInstalled = isSymlinkValid(name: "sr")
        mcpInstalled = isSymlinkValid(name: "sr-mcp")
    }

    private func isSymlinkValid(name: String) -> Bool {
        let linkPath = "\(installDir)/\(name)"
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath) else {
            return false
        }
        // Valid if it points to our app bundle
        if let macOS = macOSDir {
            return dest == "\(macOS)/\(name)"
        }
        return false
    }

    // MARK: - Install

    func install() {
        guard let macOS = macOSDir else {
            statusMessage = "Cannot determine app bundle path"
            return
        }

        isInstalling = true
        statusMessage = nil

        // Build a script that creates the symlinks
        var commands: [String] = []
        commands.append("mkdir -p '\(installDir)'")

        for name in ["sr", "sr-mcp"] {
            let source = "\(macOS)/\(name)"
            let link = "\(installDir)/\(name)"

            // Check the binary exists in our bundle
            guard FileManager.default.fileExists(atPath: source) else {
                statusMessage = "\(name) not found in app bundle"
                isInstalling = false
                return
            }

            commands.append("ln -sf '\(source)' '\(link)'")
        }

        let script = commands.joined(separator: " && ")

        // Try without admin first
        let process = Process()
        process.launchPath = "/bin/sh"
        process.arguments = ["-c", script]

        let pipe = Pipe()
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                checkInstallStatus()
                statusMessage = "CLI tools installed successfully!"
                isInstalling = false
                return
            }
        } catch {}

        // Need admin privileges — use osascript
        let adminScript = "do shell script \"\(script)\" with administrator privileges"
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: adminScript) {
            appleScript.executeAndReturnError(&error)
            if let error = error {
                statusMessage = "Install failed: \(error[NSAppleScript.errorMessage] ?? "unknown error")"
            } else {
                checkInstallStatus()
                statusMessage = "CLI tools installed successfully!"
            }
        } else {
            statusMessage = "Failed to create install script"
        }

        isInstalling = false
    }

    // MARK: - Uninstall

    func uninstall() {
        var commands: [String] = []
        for name in ["sr", "sr-mcp"] {
            let link = "\(installDir)/\(name)"
            if isSymlinkValid(name: name) {
                commands.append("rm '\(link)'")
            }
        }

        guard !commands.isEmpty else { return }

        let script = commands.joined(separator: " && ")
        let adminScript = "do shell script \"\(script)\" with administrator privileges"
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: adminScript) {
            appleScript.executeAndReturnError(&error)
        }

        checkInstallStatus()
        statusMessage = nil
    }
}
