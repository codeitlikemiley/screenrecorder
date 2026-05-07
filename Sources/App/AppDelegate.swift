import AppKit
import SwiftUI
import Combine
import KeyboardShortcuts

/// Application delegate for handling lifecycle events,
/// global hotkey registration, and window management.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotkeyManager: GlobalHotkeyManager?
    private var appState: AppState?
    private var coordinator: RecordingCoordinator?
    private var licenseCancellable: AnyCancellable?
    private var annotationModeCancellable: AnyCancellable?
    private var teleprompterCancellable: AnyCancellable?

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            // Make the app an accessory (no dock icon, just menu bar)
            NSApp.setActivationPolicy(.accessory)

            // Migrate stale shortcut defaults (e.g. ⌘F4 → ⌘F3)
            KeyboardShortcuts.Name.migrateDefaults()

            setupHotkeys()
        }
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            hotkeyManager?.unregisterHotkeys()
        }
    }

    nonisolated func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - Setup

    func configure(appState: AppState, coordinator: RecordingCoordinator) {
        self.appState = appState
        self.coordinator = coordinator
        setupHotkeys()

        // Re-register hotkeys when license status changes
        licenseCancellable = LicenseActivator.shared.$isActivated
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.setupHotkeys()
                }
            }

        // Observe annotation mode changes from ANY code path:
        // coordinator, ControlBar, OverlayWindowManager toolbar close, AgentRouter, etc.
        // When active → register annotation-only hotkeys so ⌘1-7, ⌘Z, etc. work.
        // When inactive → release them so Warp / Safari / other apps get the keys.
        annotationModeCancellable = appState.$isAnnotationModeActive
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] isActive in
                guard let manager = self?.hotkeyManager else { return }
                if isActive {
                    manager.registerAnnotationHotkeys()
                } else {
                    manager.unregisterAnnotationHotkeys()
                }
            }

        // Observe teleprompter visibility for scoped hotkeys
        teleprompterCancellable = appState.$isTeleprompterEnabled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] isEnabled in
                guard let manager = self?.hotkeyManager else { return }
                if isEnabled {
                    manager.registerTeleprompterHotkeys()
                } else {
                    manager.unregisterTeleprompterHotkeys()
                }
            }
    }

    private func setupHotkeys() {
        guard let appState = appState, let coordinator = coordinator else { return }

        let manager = GlobalHotkeyManager()
        manager.appState = appState

        let isLicensed = LicenseActivator.shared.isActivated

        // Recording hotkeys — only when licensed
        if isLicensed {
            manager.onToggleRecording = { [weak coordinator] in
                Task { @MainActor in
                    await coordinator?.toggleRecording()
                }
            }
            manager.onToggleCameraRecording = { [weak coordinator] in
                Task { @MainActor in
                    await coordinator?.toggleCameraRecording()
                }
            }
            manager.onToggleCamera = { [weak coordinator] in
                coordinator?.toggleCamera()
            }
            manager.onToggleKeystrokeMonitor = { [weak coordinator] in
                coordinator?.toggleKeystrokeMonitor()
            }
            manager.onShowHideCamera = { [weak coordinator] in
                coordinator?.overlayManager.toggleCamera()
            }
            manager.onMuteUnmuteMic = { [weak appState] in
                appState?.isMicMuted.toggle()
            }
            manager.onToggleAnnotation = { [weak coordinator] in
                coordinator?.toggleAnnotationMode()
            }
            manager.onClearAnnotations = { [weak coordinator] in
                coordinator?.clearAnnotations()
            }
            manager.onAnnotationScreenshot = { [weak coordinator] in
                coordinator?.captureAnnotationScreenshot()
            }
            manager.onToggleTeleprompter = { [weak coordinator] in
                coordinator?.toggleTeleprompterVisibility()
            }
            manager.onTeleprompterPrevSlide = { [weak coordinator] in
                coordinator?.teleprompterPrevSlide()
            }
            manager.onTeleprompterNextSlide = { [weak coordinator] in
                coordinator?.teleprompterNextSlide()
            }
            manager.onTeleprompterEditScript = { [weak coordinator] in
                coordinator?.toggleEditScript()
            }
        }

        // Always-available hotkeys (licensed or not)
        manager.onOpenRecordingsFolder = { [weak appState] in
            guard let dir = appState?.saveDirectory else { return }
            NSWorkspace.shared.open(dir)
        }
        manager.onOpenLibrary = { [weak appState] in
            guard let dir = appState?.saveDirectory else { return }
            LibraryWindowManager.shared.open(directory: dir)
        }

        manager.registerHotkeys()
        hotkeyManager = manager

        // Ensure scoped hotkeys are re-registered on the new manager if their features are already active
        if appState.isTeleprompterEnabled {
            manager.registerTeleprompterHotkeys()
        }
        if appState.isAnnotationModeActive {
            manager.registerAnnotationHotkeys()
        }
    }

}
