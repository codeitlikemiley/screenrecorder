import AVFoundation
import AppKit

/// Centralized permission manager for all system permissions the app requires.
/// Uses SILENT, non-prompting APIs only. Never triggers OS dialogs on its own.
@MainActor
class PermissionManager {
    static let shared = PermissionManager()

    // MARK: - Camera Permission

    func checkCameraPermission() -> Bool {
        return AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    // MARK: - Microphone Permission

    func checkMicrophonePermission() -> Bool {
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: - Accessibility Permission

    func checkAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Shows the system Accessibility permission prompt dialog.
    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Open System Preferences

    func openScreenRecordingPreferences() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func openAccessibilityPreferences() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
