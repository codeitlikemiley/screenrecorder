import KeyboardShortcuts
import AppKit

/// Registers global keyboard shortcut handlers using KeyboardShortcuts.
/// Replaces the old HotKey-based GlobalHotkeyManager.
///
/// Behavior changes based on recording state:
/// - NOT recording: enable/disable features (with permission checks)
/// - IS recording: show/hide or mute/unmute (no re-initialization)
@MainActor
final class GlobalHotkeyManager {

    weak var appState: AppState?

    // Callbacks wired by AppDelegate
    var onToggleRecording: (() -> Void)?
    var onToggleCamera: (() -> Void)?
    var onToggleKeystrokeMonitor: (() -> Void)?
    var onOpenRecordingsFolder: (() -> Void)?
    var onOpenLibrary: (() -> Void)?
    var onShowHideCamera: (() -> Void)?
    var onMuteUnmuteMic: (() -> Void)?
    var onToggleAnnotation: (() -> Void)?
    var onClearAnnotations: (() -> Void)?
    var onAnnotationScreenshot: (() -> Void)?

    // MARK: - Register

    func registerHotkeys() {
        // ⌘⇧4 — Start/Stop Recording
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
            self?.onToggleRecording?()
        }

        // ⌘⇧S — Start/Stop Recording (Alt fallback)
        KeyboardShortcuts.onKeyDown(for: .toggleRecordingAlt) { [weak self] in
            self?.onToggleRecording?()
        }

        // ⌘⇧K — Toggle Keystroke Overlay
        KeyboardShortcuts.onKeyDown(for: .toggleKeystrokeOverlay) { [weak self] in
            guard let self, let state = self.appState else { return }

            if !state.isKeystrokeOverlayEnabled {
                let granted = PermissionManager.shared.requestAccessibilityPermission()
                state.hasAccessibilityPermission = granted
                state.isKeystrokeOverlayEnabled = granted
                if granted { self.onToggleKeystrokeMonitor?() }
            } else {
                state.isKeystrokeOverlayEnabled = false
                self.onToggleKeystrokeMonitor?()
            }
        }

        // ⌘⇧C — Toggle Camera
        KeyboardShortcuts.onKeyDown(for: .toggleCamera) { [weak self] in
            guard let self, let state = self.appState else { return }

            if state.isRecording {
                self.onShowHideCamera?()
            } else {
                if !state.isCameraEnabled {
                    Task {
                        let granted = await PermissionManager.shared.requestCameraPermission()
                        state.hasCameraPermission = granted
                        state.isCameraEnabled = granted
                        if granted { self.onToggleCamera?() }
                    }
                } else {
                    state.isCameraEnabled = false
                    self.onToggleCamera?()
                }
            }
        }

        // ⌘⇧M — Toggle Microphone
        KeyboardShortcuts.onKeyDown(for: .toggleMicrophone) { [weak self] in
            guard let self, let state = self.appState else { return }

            if state.isRecording {
                self.onMuteUnmuteMic?()
            } else {
                if !state.isMicrophoneEnabled {
                    Task {
                        let granted = await PermissionManager.shared.requestMicrophonePermission()
                        state.hasMicrophonePermission = granted
                        state.isMicrophoneEnabled = granted
                    }
                } else {
                    state.isMicrophoneEnabled = false
                }
            }
        }

        // ⌘⇧H — Show/Hide Control Bar
        KeyboardShortcuts.onKeyDown(for: .toggleControlBar) { [weak self] in
            self?.appState?.isControlBarVisible.toggle()
        }

        // ⌘, — Open Settings
        KeyboardShortcuts.onKeyDown(for: .openSettings) {
            NotificationCenter.default.post(name: .openSettings, object: nil)
        }

        // ⌘⇧F — Open Recordings Folder
        KeyboardShortcuts.onKeyDown(for: .openRecordings) { [weak self] in
            self?.onOpenRecordingsFolder?()
        }

        // ⌘⇧L — Open Recording Library
        KeyboardShortcuts.onKeyDown(for: .openLibrary) { [weak self] in
            self?.onOpenLibrary?()
        }

        // ⌘⇧= — Increase Mic Volume
        KeyboardShortcuts.onKeyDown(for: .volumeUp) { [weak self] in
            self?.appState?.adjustMicVolume(by: 1)
        }

        // ⌘⇧- — Decrease Mic Volume
        KeyboardShortcuts.onKeyDown(for: .volumeDown) { [weak self] in
            self?.appState?.adjustMicVolume(by: -1)
        }

        // ⌘⇧0 — Reset Mic Volume to Default
        KeyboardShortcuts.onKeyDown(for: .volumeReset) { [weak self] in
            self?.appState?.resetMicVolume()
        }

        // ⌘⇧D — Toggle Annotation Mode
        KeyboardShortcuts.onKeyDown(for: .toggleAnnotation) { [weak self] in
            self?.onToggleAnnotation?()
        }

        // ⌘⇧X — Clear All Annotations (only in annotation mode)
        KeyboardShortcuts.onKeyDown(for: .clearAnnotations) { [weak self] in
            guard let self, let state = self.appState,
                  state.isAnnotationModeActive else { return }
            self.onClearAnnotations?()
        }

        // ⌘⇧3 — Annotation Screenshot (only in annotation mode)
        KeyboardShortcuts.onKeyDown(for: .annotationScreenshot) { [weak self] in
            guard let self, let state = self.appState,
                  state.isAnnotationModeActive else { return }
            self.onAnnotationScreenshot?()
        }

        // ⌘⇧⌥3 — Annotation Screenshot Alt (only in annotation mode)
        KeyboardShortcuts.onKeyDown(for: .annotationScreenshotAlt) { [weak self] in
            guard let self, let state = self.appState,
                  state.isAnnotationModeActive else { return }
            self.onAnnotationScreenshot?()
        }

        // ⌘1-7 — Per-tool shortcuts (only in annotation mode)
        KeyboardShortcuts.onKeyDown(for: .toolPen) { [weak self] in
            guard let self, let state = self.appState,
                  state.isAnnotationModeActive else { return }
            state.annotationState.selectedTool = .pen
        }
        KeyboardShortcuts.onKeyDown(for: .toolLine) { [weak self] in
            guard let self, let state = self.appState,
                  state.isAnnotationModeActive else { return }
            state.annotationState.selectedTool = .line
        }
        KeyboardShortcuts.onKeyDown(for: .toolArrow) { [weak self] in
            guard let self, let state = self.appState,
                  state.isAnnotationModeActive else { return }
            state.annotationState.selectedTool = .arrow
        }
        KeyboardShortcuts.onKeyDown(for: .toolRectangle) { [weak self] in
            guard let self, let state = self.appState,
                  state.isAnnotationModeActive else { return }
            state.annotationState.selectedTool = .rectangle
        }
        KeyboardShortcuts.onKeyDown(for: .toolEllipse) { [weak self] in
            guard let self, let state = self.appState,
                  state.isAnnotationModeActive else { return }
            state.annotationState.selectedTool = .ellipse
        }
        KeyboardShortcuts.onKeyDown(for: .toolText) { [weak self] in
            guard let self, let state = self.appState,
                  state.isAnnotationModeActive else { return }
            state.annotationState.selectedTool = .text
        }
        KeyboardShortcuts.onKeyDown(for: .toolMove) { [weak self] in
            guard let self, let state = self.appState,
                  state.isAnnotationModeActive else { return }
            state.annotationState.selectedTool = .move
        }

        // ⌘Z — Undo Annotation (only in annotation mode)
        KeyboardShortcuts.onKeyDown(for: .annotationUndo) { [weak self] in
            guard let self, let state = self.appState,
                  state.isAnnotationModeActive else { return }
            state.annotationState.undo()
        }

        // ⌘⇧Z — Redo Annotation (only in annotation mode)
        KeyboardShortcuts.onKeyDown(for: .annotationRedo) { [weak self] in
            guard let self, let state = self.appState,
                  state.isAnnotationModeActive else { return }
            state.annotationState.redo()
        }
    }

    // MARK: - Unregister

    func unregisterHotkeys() {
        KeyboardShortcuts.removeAllHandlers()
    }
}
