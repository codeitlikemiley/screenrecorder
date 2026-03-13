import AppKit
import SwiftUI

/// Application delegate for handling lifecycle events,
/// global hotkey registration, and window management.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotkeyManager: GlobalHotkeyManager?
    private var appState: AppState?
    private var coordinator: RecordingCoordinator?

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            // Make the app an accessory (no dock icon, just menu bar)
            NSApp.setActivationPolicy(.accessory)
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
    }

    private func setupHotkeys() {
        guard let appState = appState, let coordinator = coordinator else { return }

        let manager = GlobalHotkeyManager()
        manager.appState = appState

        // Not-recording: enable/disable with permissions
        manager.onToggleRecording = { [weak coordinator] in
            Task { @MainActor in
                await coordinator?.toggleRecording()
            }
        }
        manager.onToggleCamera = { [weak coordinator] in
            coordinator?.toggleCamera()
        }
        manager.onToggleKeystrokeMonitor = { [weak coordinator] in
            coordinator?.toggleKeystrokeMonitor()
        }

        // During-recording: show/hide and mute (no re-initialization)
        manager.onShowHideCamera = { [weak coordinator] in
            coordinator?.overlayManager.toggleCamera()
        }
        manager.onShowHideKeystroke = { [weak coordinator] in
            coordinator?.overlayManager.toggleKeystrokeVisibility()
        }
        manager.onMuteUnmuteMic = { [weak appState] in
            appState?.isMicMuted.toggle()
        }
        manager.onOpenRecordingsFolder = { [weak appState] in
            guard let dir = appState?.saveDirectory else { return }
            NSWorkspace.shared.open(dir)
        }

        manager.registerHotkeys()
        hotkeyManager = manager
    }

    // MARK: - Window Helpers

    /// Configure a window as a floating overlay (click-through, no shadow, always on top)
    static func configureOverlayWindow(_ window: NSWindow) {
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = false
    }

    /// Configure a window as a HUD panel
    static func configureHUDWindow(_ window: NSWindow) {
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
    }
}
