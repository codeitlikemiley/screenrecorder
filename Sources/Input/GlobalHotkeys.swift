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
    var onToggleCameraRecording: (() -> Void)?
    var onToggleCamera: (() -> Void)?
    var onToggleKeystrokeMonitor: (() -> Void)?
    var onOpenRecordingsFolder: (() -> Void)?
    var onOpenLibrary: (() -> Void)?
    var onShowHideCamera: (() -> Void)?
    var onMuteUnmuteMic: (() -> Void)?
    var onToggleAnnotation: (() -> Void)?
    var onClearAnnotations: (() -> Void)?
    var onAnnotationScreenshot: (() -> Void)?
    var onToggleTeleprompter: (() -> Void)?
    var onTeleprompterPrevSlide: (() -> Void)?
    var onTeleprompterNextSlide: (() -> Void)?
    var onTeleprompterEditScript: (() -> Void)?

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

        // ⌘⇧W — Start/Stop Camera-Only Recording
        KeyboardShortcuts.onKeyDown(for: .toggleCameraRecording) { [weak self] in
            self?.onToggleCameraRecording?()
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

        // ⌘F3 — Toggle Teleprompter (always global)
        KeyboardShortcuts.onKeyDown(for: .toggleTeleprompter) { [weak self] in
            self?.onToggleTeleprompter?()
        }

        // ⌘F4 — Edit Script (always global)
        KeyboardShortcuts.onKeyDown(for: .teleprompterEditScript) { [weak self] in
            self?.onTeleprompterEditScript?()
        }

        setupAnnotationHotkeys()
        setupTeleprompterHotkeys()
    }

    private func setupAnnotationHotkeys() {
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

        // Disable them initially so they don't steal keys when annotation mode is off
        unregisterAnnotationHotkeys()
    }

    private func setupTeleprompterHotkeys() {
        // ⌘F1 — Previous Slide
        KeyboardShortcuts.onKeyDown(for: .teleprompterPrevSlide) { [weak self] in
            self?.onTeleprompterPrevSlide?()
        }

        // ⌘F2 — Next Slide
        KeyboardShortcuts.onKeyDown(for: .teleprompterNextSlide) { [weak self] in
            self?.onTeleprompterNextSlide?()
        }

        // ⌘⌥+ — Increase font size
        KeyboardShortcuts.onKeyDown(for: .teleprompterFontUp) { [weak self] in
            guard let self, let state = self.appState else { return }
            state.teleprompterSettings.fontSize = min(80, state.teleprompterSettings.fontSize + 2)
        }

        // ⌘⌥- — Decrease font size
        KeyboardShortcuts.onKeyDown(for: .teleprompterFontDown) { [weak self] in
            guard let self, let state = self.appState else { return }
            state.teleprompterSettings.fontSize = max(16, state.teleprompterSettings.fontSize - 2)
        }

        // Disable initially
        unregisterTeleprompterHotkeys()
    }

    // MARK: - Annotation-scoped hotkeys (only active during annotation mode)

    /// Call this when annotation mode becomes active.
    /// Registers shortcuts that would conflict with other apps when not annotating.
    func registerAnnotationHotkeys() {
        KeyboardShortcuts.enable(.clearAnnotations, .annotationScreenshot, .annotationScreenshotAlt, .toolPen, .toolLine, .toolArrow, .toolRectangle, .toolEllipse, .toolText, .toolMove, .annotationUndo, .annotationRedo)
    }

    /// Call this when annotation mode is deactivated.
    /// Releases all annotation-only shortcuts so other apps can use them freely.
    func unregisterAnnotationHotkeys() {
        KeyboardShortcuts.disable(.clearAnnotations, .annotationScreenshot, .annotationScreenshotAlt, .toolPen, .toolLine, .toolArrow, .toolRectangle, .toolEllipse, .toolText, .toolMove, .annotationUndo, .annotationRedo)
    }

    // MARK: - Teleprompter-scoped hotkeys (only active when teleprompter is visible)

    /// Call this when the teleprompter becomes visible.
    func registerTeleprompterHotkeys() {
        KeyboardShortcuts.enable(.teleprompterPrevSlide, .teleprompterNextSlide, .teleprompterFontUp, .teleprompterFontDown)
    }

    /// Call this when the teleprompter is hidden.
    func unregisterTeleprompterHotkeys() {
        KeyboardShortcuts.disable(.teleprompterPrevSlide, .teleprompterNextSlide, .teleprompterFontUp, .teleprompterFontDown)
    }

    // MARK: - Unregister All

    func unregisterHotkeys() {
        KeyboardShortcuts.removeAllHandlers()
    }
}
