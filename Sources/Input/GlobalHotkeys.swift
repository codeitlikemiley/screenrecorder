import HotKey
import AppKit

/// Manages global hotkey registration using the HotKey package.
/// All hotkeys work even when the app is in the background.
///
/// Behavior changes based on recording state:
/// - NOT recording: enable/disable features (with permission checks)
/// - IS recording: show/hide or mute/unmute (no re-initialization)
@MainActor
class GlobalHotkeyManager {
    private var recordHotKey: HotKey?
    private var keystrokeHotKey: HotKey?
    private var cameraHotKey: HotKey?
    private var controlBarHotKey: HotKey?

    weak var appState: AppState?

    // Not-recording callbacks (enable/disable with permissions)
    var onToggleRecording: (() -> Void)?
    var onToggleCamera: (() -> Void)?
    var onToggleKeystrokeMonitor: (() -> Void)?

    // During-recording callbacks (show/hide, mute/unmute)
    var onShowHideCamera: (() -> Void)?
    var onShowHideKeystroke: (() -> Void)?
    var onMuteUnmuteMic: (() -> Void)?

    // MARK: - Register Hotkeys

    func registerHotkeys() {
        // ⌘⇧R — Start/Stop Recording
        recordHotKey = HotKey(key: .r, modifiers: [.command, .shift])
        recordHotKey?.keyDownHandler = { [weak self] in
            self?.onToggleRecording?()
        }

        // ⌘⇧K — Toggle Keystroke Overlay
        keystrokeHotKey = HotKey(key: .k, modifiers: [.command, .shift])
        keystrokeHotKey?.keyDownHandler = { [weak self] in
            guard let state = self?.appState else { return }

            if state.isRecording {
                // During recording: just show/hide the overlay
                self?.onShowHideKeystroke?()
            } else {
                // Not recording: enable/disable with permission check
                if !state.isKeystrokeOverlayEnabled {
                    let granted = PermissionManager.shared.requestAccessibilityPermission()
                    state.hasAccessibilityPermission = granted
                    state.isKeystrokeOverlayEnabled = granted
                    if granted { self?.onToggleKeystrokeMonitor?() }
                } else {
                    state.isKeystrokeOverlayEnabled = false
                    self?.onToggleKeystrokeMonitor?()
                }
            }
        }

        // ⌘⇧C — Toggle Camera
        cameraHotKey = HotKey(key: .c, modifiers: [.command, .shift])
        cameraHotKey?.keyDownHandler = { [weak self] in
            guard let state = self?.appState else { return }

            if state.isRecording {
                // During recording: just show/hide the camera preview
                self?.onShowHideCamera?()
            } else {
                // Not recording: enable/disable with permission check
                if !state.isCameraEnabled {
                    Task {
                        let granted = await PermissionManager.shared.requestCameraPermission()
                        state.hasCameraPermission = granted
                        state.isCameraEnabled = granted
                        if granted { self?.onToggleCamera?() }
                    }
                } else {
                    state.isCameraEnabled = false
                    self?.onToggleCamera?()
                }
            }
        }

        // ⌘⇧H — Show/Hide Control Bar
        controlBarHotKey = HotKey(key: .h, modifiers: [.command, .shift])
        controlBarHotKey?.keyDownHandler = { [weak self] in
            guard let state = self?.appState else { return }
            state.isControlBarVisible.toggle()
        }
    }

    // MARK: - Unregister

    func unregisterHotkeys() {
        recordHotKey = nil
        keystrokeHotKey = nil
        cameraHotKey = nil
        controlBarHotKey = nil
    }
}
