import HotKey
import AppKit

/// Manages global hotkey registration using the HotKey package.
/// All hotkeys work even when the app is in the background.
@MainActor
class GlobalHotkeyManager {
    private var recordHotKey: HotKey?
    private var keystrokeHotKey: HotKey?
    private var cameraHotKey: HotKey?
    private var controlBarHotKey: HotKey?

    weak var appState: AppState?
    var onToggleRecording: (() -> Void)?

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
            state.isKeystrokeOverlayEnabled.toggle()
        }

        // ⌘⇧C — Toggle Camera
        cameraHotKey = HotKey(key: .c, modifiers: [.command, .shift])
        cameraHotKey?.keyDownHandler = { [weak self] in
            guard let state = self?.appState else { return }
            state.isCameraEnabled.toggle()
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
