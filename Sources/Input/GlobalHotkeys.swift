import KeyboardShortcuts
import AppKit

/// Registers global keyboard shortcut handlers using KeyboardShortcuts.
/// Replaces the old HotKey-based GlobalHotkeyManager.
///
/// IMPORTANT: Annotation-only shortcuts (⌘1-7, ⌘Z, ⌘⇧Z, ⌘⇧X, ⌘⇧3) are registered
/// ONLY while annotation mode is active, so they don't intercept keys in other apps
/// (Warp, Safari, etc.) when the user is not annotating.
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

    // MARK: - Register (always-on hotkeys)

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
                state.isKeystrokeOverlayEnabled = true
                self.onToggleKeystrokeMonitor?()
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

        // ⌘⇧D — Toggle Annotation Mode (always global)
        KeyboardShortcuts.onKeyDown(for: .toggleAnnotation) { [weak self] in
            self?.onToggleAnnotation?()
        }

        // NOTE: Annotation-only shortcuts (tools, undo/redo, clear, screenshot) are
        // registered separately via registerAnnotationHotkeys() and only active
        // while annotation mode is on. They must NOT be registered here.
    }

    // MARK: - Annotation-scoped hotkeys (only active during annotation mode)

    /// Call this when annotation mode becomes active.
    /// Registers shortcuts that would conflict with other apps when not annotating.
    func registerAnnotationHotkeys() {
        // ⌘⇧X — Clear All Annotations
        KeyboardShortcuts.onKeyDown(for: .clearAnnotations) { [weak self] in
            self?.onClearAnnotations?()
        }

        // ⌘⇧3 — Annotation Screenshot
        KeyboardShortcuts.onKeyDown(for: .annotationScreenshot) { [weak self] in
            self?.onAnnotationScreenshot?()
        }

        // ⌘⇧⌥3 — Annotation Screenshot (Alt)
        KeyboardShortcuts.onKeyDown(for: .annotationScreenshotAlt) { [weak self] in
            self?.onAnnotationScreenshot?()
        }

        // ⌘1 — Pen Tool
        KeyboardShortcuts.onKeyDown(for: .toolPen) { [weak self] in
            self?.appState?.annotationState.selectedTool = .pen
        }
        // ⌘2 — Line Tool
        KeyboardShortcuts.onKeyDown(for: .toolLine) { [weak self] in
            self?.appState?.annotationState.selectedTool = .line
        }
        // ⌘3 — Arrow Tool
        KeyboardShortcuts.onKeyDown(for: .toolArrow) { [weak self] in
            self?.appState?.annotationState.selectedTool = .arrow
        }
        // ⌘4 — Rectangle Tool
        KeyboardShortcuts.onKeyDown(for: .toolRectangle) { [weak self] in
            self?.appState?.annotationState.selectedTool = .rectangle
        }
        // ⌘5 — Ellipse Tool
        KeyboardShortcuts.onKeyDown(for: .toolEllipse) { [weak self] in
            self?.appState?.annotationState.selectedTool = .ellipse
        }
        // ⌘6 — Text Tool
        KeyboardShortcuts.onKeyDown(for: .toolText) { [weak self] in
            self?.appState?.annotationState.selectedTool = .text
        }
        // ⌘7 — Move Tool
        KeyboardShortcuts.onKeyDown(for: .toolMove) { [weak self] in
            self?.appState?.annotationState.selectedTool = .move
        }

        // ⌘Z — Undo Annotation
        KeyboardShortcuts.onKeyDown(for: .annotationUndo) { [weak self] in
            self?.appState?.annotationState.undo()
        }

        // ⌘⇧Z — Redo Annotation
        KeyboardShortcuts.onKeyDown(for: .annotationRedo) { [weak self] in
            self?.appState?.annotationState.redo()
        }
    }

    /// Call this when annotation mode is deactivated.
    /// Releases all annotation-only shortcuts so other apps can use them freely.
    func unregisterAnnotationHotkeys() {
        KeyboardShortcuts.removeHandler(for: .clearAnnotations)
        KeyboardShortcuts.removeHandler(for: .annotationScreenshot)
        KeyboardShortcuts.removeHandler(for: .annotationScreenshotAlt)
        KeyboardShortcuts.removeHandler(for: .toolPen)
        KeyboardShortcuts.removeHandler(for: .toolLine)
        KeyboardShortcuts.removeHandler(for: .toolArrow)
        KeyboardShortcuts.removeHandler(for: .toolRectangle)
        KeyboardShortcuts.removeHandler(for: .toolEllipse)
        KeyboardShortcuts.removeHandler(for: .toolText)
        KeyboardShortcuts.removeHandler(for: .toolMove)
        KeyboardShortcuts.removeHandler(for: .annotationUndo)
        KeyboardShortcuts.removeHandler(for: .annotationRedo)
    }

    // MARK: - Unregister All

    func unregisterHotkeys() {
        KeyboardShortcuts.removeAllHandlers()
    }
}
