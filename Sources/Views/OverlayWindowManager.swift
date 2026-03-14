import SwiftUI
import AppKit
import AVFoundation
import Combine

/// Manages floating NSWindows for overlays (keystroke display, camera preview).
/// These windows are always-on-top, transparent, and click-through where needed.
@MainActor
class OverlayWindowManager {
    private var keystrokeWindow: NSWindow?
    private var cameraWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var windowMoveObserver: Any?

    weak var appState: AppState?
    weak var cameraManager: CameraManager?

    /// Called when the camera overlay window is moved.
    /// Returns normalized position (0,0 = bottom-left, 1,1 = top-right)
    var onCameraPositionChanged: ((CGPoint) -> Void)?

    // MARK: - Setup

    func setup(appState: AppState, cameraManager: CameraManager) {
        self.appState = appState
        self.cameraManager = cameraManager

        // Observe keystroke overlay toggle
        appState.$isKeystrokeOverlayEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                if enabled {
                    self?.showKeystrokeOverlay()
                } else {
                    self?.hideKeystrokeOverlay()
                }
            }
            .store(in: &cancellables)

        // Observe keystroke text changes to keep window on top
        appState.$keystrokeVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in
                if visible {
                    self?.keystrokeWindow?.orderFrontRegardless()
                }
            }
            .store(in: &cancellables)

        // Observe mic volume changes to show HUD
        appState.$showVolumeOverlay
            .receive(on: RunLoop.main)
            .sink { [weak self] show in
                if show {
                    self?.showVolumeHUD()
                } else {
                    self?.volumeWindow?.orderOut(nil)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Volume Overlay HUD

    private var volumeWindow: NSWindow?

    func showVolumeHUD() {
        guard let appState = appState, let screen = NSScreen.main else { return }

        if volumeWindow == nil {
            let hostView = NSHostingView(rootView: VolumeOverlay(appState: appState))
            let window = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 260, height: 100),
                styleMask: [.nonactivatingPanel, .hudWindow],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .screenSaver
            window.ignoresMouseEvents = true
            window.contentView = hostView
            window.sharingType = .none
            volumeWindow = window
        }

        // Center on screen
        let screenFrame = screen.visibleFrame
        let windowSize = volumeWindow!.frame.size
        let x = screenFrame.midX - windowSize.width / 2
        let y = screenFrame.midY - windowSize.height / 2
        volumeWindow?.setFrameOrigin(NSPoint(x: x, y: y))
        volumeWindow?.orderFrontRegardless()
    }

    func showCamera() {
        guard let appState = appState, let cameraManager = cameraManager else { return }

        if cameraWindow == nil {
            createCameraWindow(appState: appState, cameraManager: cameraManager)
        }

        cameraWindow?.orderFrontRegardless()
    }

    func hideCamera() {
        cameraWindow?.orderOut(nil)
    }

    /// Fully destroys the camera window so it gets recreated fresh next time.
    /// Call this when stopping recording — the next showCamera() will create
    /// a new window with the fresh camera session.
    func destroyCameraWindow() {
        if let observer = windowMoveObserver {
            NotificationCenter.default.removeObserver(observer)
            windowMoveObserver = nil
        }
        cameraWindow?.orderOut(nil)
        cameraWindow = nil
    }

    func toggleCamera() {
        if cameraWindow?.isVisible == true {
            hideCamera()
        } else {
            showCamera()
        }
    }

    var isCameraVisible: Bool {
        cameraWindow?.isVisible ?? false
    }

    private func createCameraWindow(appState: AppState, cameraManager: CameraManager) {
        guard let screen = NSScreen.main else { return }

        let size = appState.cameraSize + 20 // padding
        let screenFrame = screen.frame

        // Position at bottom-right of screen
        let originX = screenFrame.maxX - size - 30
        let originY = screenFrame.origin.y + 30

        let windowFrame = NSRect(x: originX, y: originY, width: size, height: size)

        let window = NSWindow(
            contentRect: windowFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.sharingType = .none  // Hide from screen capture (we composite camera ourselves in VideoWriter)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true

        // Host the SwiftUI camera overlay (with hide callback)
        let overlayView = CameraOverlay(
            appState: appState,
            cameraManager: cameraManager,
            onHide: { [weak self] in
                self?.hideCamera()
            }
        )
        let hostingView = NSHostingView(rootView: overlayView)
        hostingView.frame = NSRect(x: 0, y: 0, width: size, height: size)

        window.contentView = hostingView
        cameraWindow = window

        // Observe window moves to sync composited camera position
        windowMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.notifyCameraPositionChanged()
            }
        }
        // Send initial position
        notifyCameraPositionChanged()
    }

    private func notifyCameraPositionChanged() {
        guard let window = cameraWindow, let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let windowCenter = CGPoint(
            x: window.frame.midX - screenFrame.origin.x,
            y: window.frame.midY - screenFrame.origin.y
        )
        // Normalize to 0-1 range (origin at bottom-left, same as CoreImage)
        let normalized = CGPoint(
            x: windowCenter.x / screenFrame.width,
            y: windowCenter.y / screenFrame.height
        )
        onCameraPositionChanged?(normalized)
    }

    // MARK: - Keystroke Overlay Window

    private func showKeystrokeOverlay() {
        guard let appState = appState else { return }

        if keystrokeWindow == nil {
            createKeystrokeWindow(appState: appState)
        }

        keystrokeWindow?.orderFrontRegardless()
    }

    private func hideKeystrokeOverlay() {
        keystrokeWindow?.orderOut(nil)
    }

    /// Toggle keystroke overlay visibility (for during-recording show/hide)
    func toggleKeystrokeVisibility() {
        if keystrokeWindow?.isVisible == true {
            hideKeystrokeOverlay()
        } else {
            showKeystrokeOverlay()
        }
    }

    private func createKeystrokeWindow(appState: AppState) {
        guard let screen = NSScreen.main else { return }

        let screenFrame = screen.frame
        let windowWidth = screenFrame.width
        let windowHeight: CGFloat = 100

        // Position at bottom of screen, full width
        let originX = screenFrame.origin.x
        let originY = screenFrame.origin.y

        let windowFrame = NSRect(x: originX, y: originY, width: windowWidth, height: windowHeight)

        let window = NSWindow(
            contentRect: windowFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.level = .screenSaver  // Above everything
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true  // Click-through
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false

        // Allow capture so keystrokes appear in recordings
        window.sharingType = .readOnly

        // Host the SwiftUI view
        let overlayView = KeystrokeOverlay(appState: appState)
        let hostingView = NSHostingView(rootView: overlayView)
        hostingView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)

        window.contentView = hostingView

        keystrokeWindow = window
    }

    // MARK: - Countdown Overlay Window

    private var countdownWindow: NSWindow?

    /// Shows a fullscreen countdown overlay (3, 2, 1) and awaits completion.
    /// The window auto-destroys after the countdown finishes.
    func showCountdown(appState: AppState) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guard let screen = NSScreen.main else {
                continuation.resume()
                return
            }

            let screenFrame = screen.frame

            let overlayView = CountdownView(appState: appState) { [weak self] in
                // Countdown complete — destroy window and resume
                self?.countdownWindow?.orderOut(nil)
                self?.countdownWindow = nil
                continuation.resume()
            }

            let hostingView = NSHostingView(rootView: overlayView)
            hostingView.frame = NSRect(x: 0, y: 0, width: screenFrame.width, height: screenFrame.height)

            let window = NSWindow(
                contentRect: screenFrame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false
            window.sharingType = .none  // Don't capture the countdown itself
            window.contentView = hostingView

            self.countdownWindow = window
            window.orderFrontRegardless()
        }
    }

    // MARK: - Cleanup

    func cleanup() {
        keystrokeWindow?.orderOut(nil)
        keystrokeWindow = nil
        cameraWindow?.orderOut(nil)
        cameraWindow = nil
        cancellables.removeAll()
    }
}
