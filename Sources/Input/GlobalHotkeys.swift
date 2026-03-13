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
    private var micHotKey: HotKey?
    private var controlBarHotKey: HotKey?
    private var settingsHotKey: HotKey?
    private var folderHotKey: HotKey?
    private var volumeUpHotKey: HotKey?
    private var volumeDownHotKey: HotKey?
    private var volumeResetHotKey: HotKey?

    weak var appState: AppState?

    // Not-recording callbacks (enable/disable with permissions)
    var onToggleRecording: (() -> Void)?
    var onToggleCamera: (() -> Void)?
    var onToggleKeystrokeMonitor: (() -> Void)?
    var onToggleMicrophone: (() -> Void)?
    var onOpenRecordingsFolder: (() -> Void)?

    // During-recording callbacks (show/hide, mute/unmute)
    var onShowHideCamera: (() -> Void)?
    var onShowHideKeystroke: (() -> Void)?
    var onMuteUnmuteMic: (() -> Void)?

    // MARK: - Register Hotkeys

    func registerHotkeys() {
        // ⌘⇧S — Start/Stop Recording
        recordHotKey = HotKey(key: .s, modifiers: [.command, .shift])
        recordHotKey?.keyDownHandler = { [weak self] in
            self?.onToggleRecording?()
        }

        // ⌘⇧K — Toggle Keystroke Overlay (always enable/disable, no re-init issue)
        keystrokeHotKey = HotKey(key: .k, modifiers: [.command, .shift])
        keystrokeHotKey?.keyDownHandler = { [weak self] in
            guard let state = self?.appState else { return }

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

        // ⌘⇧M — Toggle Microphone
        micHotKey = HotKey(key: .m, modifiers: [.command, .shift])
        micHotKey?.keyDownHandler = { [weak self] in
            guard let state = self?.appState else { return }

            if state.isRecording {
                // During recording: mute/unmute
                self?.onMuteUnmuteMic?()
            } else {
                // Not recording: enable/disable with permission check
                if !state.isMicrophoneEnabled {
                    Task {
                        let granted = await PermissionManager.shared.requestMicrophonePermission()
                        state.hasMicrophonePermission = granted
                        state.isMicrophoneEnabled = granted
                        if granted { self?.onToggleMicrophone?() }
                    }
                } else {
                    state.isMicrophoneEnabled = false
                    self?.onToggleMicrophone?()
                }
            }
        }

        // ⌘⇧H — Show/Hide Control Bar
        controlBarHotKey = HotKey(key: .h, modifiers: [.command, .shift])
        controlBarHotKey?.keyDownHandler = { [weak self] in
            guard let state = self?.appState else { return }
            state.isControlBarVisible.toggle()
        }

        // ⌘, — Open Settings (standard macOS convention)
        settingsHotKey = HotKey(key: .comma, modifiers: [.command])
        settingsHotKey?.keyDownHandler = {
            NotificationCenter.default.post(name: .openSettings, object: nil)
        }

        // ⌘⇧F — Open Recordings Folder
        folderHotKey = HotKey(key: .f, modifiers: [.command, .shift])
        folderHotKey?.keyDownHandler = { [weak self] in
            self?.onOpenRecordingsFolder?()
        }

        // ⌘⇧= — Increase Mic Volume (=  is the + key without shift)
        volumeUpHotKey = HotKey(key: .equal, modifiers: [.command, .shift])
        volumeUpHotKey?.keyDownHandler = { [weak self] in
            self?.appState?.adjustMicVolume(by: 1)
        }

        // ⌘⇧- — Decrease Mic Volume
        volumeDownHotKey = HotKey(key: .minus, modifiers: [.command, .shift])
        volumeDownHotKey?.keyDownHandler = { [weak self] in
            self?.appState?.adjustMicVolume(by: -1)
        }

        // ⌘⇧0 — Reset Mic Volume to Default
        volumeResetHotKey = HotKey(key: .zero, modifiers: [.command, .shift])
        volumeResetHotKey?.keyDownHandler = { [weak self] in
            self?.appState?.resetMicVolume()
        }
    }

    // MARK: - Unregister

    func unregisterHotkeys() {
        recordHotKey = nil
        keystrokeHotKey = nil
        cameraHotKey = nil
        micHotKey = nil
        controlBarHotKey = nil
        settingsHotKey = nil
        folderHotKey = nil
        volumeUpHotKey = nil
        volumeDownHotKey = nil
        volumeResetHotKey = nil
    }
}
