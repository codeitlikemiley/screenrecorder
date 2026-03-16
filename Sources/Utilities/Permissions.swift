import AVFoundation
import AppKit

/// Permission state snapshot for change detection
struct PermissionSnapshot {
    let camera: Bool
    let microphone: Bool
    let accessibility: Bool

    /// Count of granted (truthy) permissions
    var grantedCount: Int {
        [camera, microphone, accessibility].filter { $0 }.count
    }
}

/// Centralized permission manager for all system permissions the app requires.
/// Each feature checks and requests its permission when toggled on.
@MainActor
class PermissionManager {
    static let shared = PermissionManager()

    /// Snapshot taken at app startup (or after last restart)
    private(set) var startupSnapshot: PermissionSnapshot

    private init() {
        // Capture initial permission state
        startupSnapshot = PermissionSnapshot(
            camera: AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibility: AXIsProcessTrusted()
        )
    }

    // MARK: - Snapshot & Change Detection

    /// Check current permissions and return names of newly granted ones (compared to startup)
    func checkForNewGrants() -> [String] {
        let current = PermissionSnapshot(
            camera: AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibility: AXIsProcessTrusted()
        )

        var newGrants: [String] = []
        if current.camera && !startupSnapshot.camera { newGrants.append("Camera") }
        if current.microphone && !startupSnapshot.microphone { newGrants.append("Microphone") }
        if current.accessibility && !startupSnapshot.accessibility { newGrants.append("Accessibility") }

        return newGrants
    }

    /// Restart the app (launch new instance, terminate current)
    func restartApp() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Camera Permission

    func checkCameraPermission() -> Bool {
        return AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    func requestCameraPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            openSystemSettings(pane: "Privacy_Camera")
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Microphone Permission

    func checkMicrophonePermission() -> Bool {
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            openSystemSettings(pane: "Privacy_Microphone")
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Accessibility Permission (for keystroke overlay)

    func checkAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Called when a feature needs accessibility (e.g. keystroke overlay toggle).
    /// Shows the system prompt dialog if not trusted.
    func requestAccessibilityPermission() -> Bool {
        if AXIsProcessTrusted() { return true }
        // Reset stale TCC entries first — entries get tied to code signatures
        // and go stale on rebuild, preventing the app from appearing in the list
        resetAccessibilityTCC()
        // Show system dialog — clicking "Open System Settings" will now
        // properly register and show the app in the Accessibility list
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Called by the Settings Grant button. Triggers the system accessibility prompt
    /// which registers the app in the Accessibility list when "Open System Settings" is clicked.
    func openAccessibilitySettings() {
        // Reset stale TCC entries first
        resetAccessibilityTCC()
        // Show the system dialog — "Open System Settings" will add the app to the list
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Clears stale Accessibility TCC entries for this bundle ID.
    /// TCC entries are tied to code signatures (CDHash) and go stale
    /// when the app is rebuilt or updated with a different signature.
    private func resetAccessibilityTCC() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleId]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - Open System Settings

    func openSystemSettings(pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
