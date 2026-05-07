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
    private var annotationWindow: NSWindow?
    private var annotationToolbarWindow: NSWindow?
    private var teleprompterWindow: NSPanel?
    private var teleprompterControlWindow: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private var windowMoveObserver: Any?
    private var teleprompterMoveObserver: Any?
    private var teleprompterResizeObserver: Any?
    private var teleprompterPlacementObserver: Any?

    /// Callback for annotation screenshot — set by RecordingCoordinator
    var onAnnotationScreenshot: (() -> Void)?

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

        // Auto-hide camera when Presenter Overlay (or another app) steals the camera
        cameraManager.$isInterrupted
            .receive(on: RunLoop.main)
            .sink { [weak self] interrupted in
                guard let self = self else { return }
                if interrupted {
                    // Presenter Overlay is active — hide our camera preview
                    self.cameraWindow?.orderOut(nil)
                    print("📷 Camera preview hidden (Presenter Overlay active)")
                } else if self.appState?.isCameraEnabled == true && self.cameraManager?.isRunning == true {
                    // Presenter Overlay deactivated — restore our camera preview
                    self.showCamera()
                    print("📷 Camera preview restored")
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

        // Observe annotation mode toggle
        appState.$isAnnotationModeActive
            .receive(on: RunLoop.main)
            .sink { [weak self] active in
                if active {
                    self?.showAnnotationOverlay()
                    self?.setAnnotationInteractive(true)
                } else {
                    self?.setAnnotationInteractive(false)
                    self?.hideAnnotationToolbar()
                }
            }
            .store(in: &cancellables)

        // Observe annotation visibility toggle
        appState.$isAnnotationVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in
                if visible {
                    self?.annotationWindow?.alphaValue = 1.0
                } else {
                    self?.annotationWindow?.alphaValue = 0.0
                }
            }
            .store(in: &cancellables)

        // Observe teleprompter toggle
        appState.$isTeleprompterEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                if enabled {
                    self?.showTeleprompter()
                } else {
                    self?.hideTeleprompter()
                }
            }
            .store(in: &cancellables)

        // Observe teleprompter settings changes that affect the window
        appState.$teleprompterSettings
            .receive(on: RunLoop.main)
            .sink { [weak self] settings in
                self?.applyTeleprompterSettings(settings)
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
        annotationWindow?.orderOut(nil)
        annotationWindow = nil
        annotationToolbarWindow?.orderOut(nil)
        annotationToolbarWindow = nil
        destroyTeleprompter()
        cancellables.removeAll()
    }

    // MARK: - Annotation Overlay Window

    func showAnnotationOverlay() {
        guard let appState = appState else { return }

        if annotationWindow == nil {
            createAnnotationWindow(appState: appState)
        }

        annotationWindow?.orderFrontRegardless()
        showAnnotationToolbar()
    }

    func hideAnnotationOverlay() {
        annotationWindow?.orderOut(nil)
        annotationWindow = nil
        hideAnnotationToolbar()
    }

    /// Toggle the annotation window between interactive (drawing) and click-through (passthrough) modes
    func setAnnotationInteractive(_ active: Bool) {
        if annotationWindow == nil {
            if active { showAnnotationOverlay() } else { return }
        }
        
        guard let window = annotationWindow else { return }

        if active {
            window.ignoresMouseEvents = false
            window.level = .screenSaver
            // Ensure the window accepts input — make it key
            window.makeKey()
            showAnnotationToolbar()
        } else {
            window.ignoresMouseEvents = true
            window.level = .floating
            hideAnnotationToolbar()
        }
    }

    private func createAnnotationWindow(appState: AppState) {
        guard let screen = NSScreen.main else { return }

        let screenFrame = screen.frame

        let canvasView = AnnotationCanvasView(annotationState: appState.annotationState)
        let hostingView = NSHostingView(rootView: canvasView)
        hostingView.frame = NSRect(x: 0, y: 0, width: screenFrame.width, height: screenFrame.height)

        let window = InteractiveOverlayWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.level = .screenSaver       // Above everything
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = false  // Start interactive
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false

        // CRITICAL: .readOnly makes annotations appear in screen recording
        window.sharingType = .readOnly

        window.contentView = hostingView
        annotationWindow = window
    }

    // MARK: - Annotation Toolbar Window

    private func showAnnotationToolbar() {
        guard let appState = appState, let screen = NSScreen.main else { return }

        if annotationToolbarWindow == nil {
            createAnnotationToolbarWindow(appState: appState)
        }

        // Position at top center of screen
        let screenFrame = screen.visibleFrame
        let toolbarSize = annotationToolbarWindow!.frame.size
        let x = screenFrame.midX - toolbarSize.width / 2
        let y = screenFrame.maxY - toolbarSize.height - 10
        annotationToolbarWindow?.setFrameOrigin(NSPoint(x: x, y: y))
        annotationToolbarWindow?.orderFrontRegardless()
    }

    private func hideAnnotationToolbar() {
        annotationToolbarWindow?.orderOut(nil)
    }

    /// Public: temporarily hide toolbar for screenshot capture
    func hideAnnotationToolbarForCapture() {
        annotationToolbarWindow?.orderOut(nil)
    }

    /// Public: re-show toolbar after screenshot capture
    func showAnnotationToolbarAfterCapture() {
        showAnnotationToolbar()
    }

    private func createAnnotationToolbarWindow(appState: AppState) {
        let toolbarView = AnnotationToolbar(
            annotationState: appState.annotationState,
            onClose: { [weak self] in
                self?.appState?.isAnnotationModeActive = false
            },
            onClear: { [weak self] in
                self?.appState?.annotationState.clearAll()
            },
            onScreenshot: { [weak self] in
                self?.onAnnotationScreenshot?()
            }
        )

        let hostingView = NSHostingView(rootView: toolbarView)
        let contentSize = hostingView.fittingSize

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        window.level = .screenSaver + 1  // Above annotation canvas
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.sharingType = .none  // Don't capture the toolbar itself

        window.contentView = hostingView
        annotationToolbarWindow = window
    }

    // MARK: - Teleprompter Overlay Window

    func showTeleprompter() {
        guard let appState = appState else { return }

        if teleprompterWindow == nil {
            createTeleprompterWindow(appState: appState)
        }

        teleprompterWindow?.orderFrontRegardless()
    }

    func hideTeleprompter() {
        // Persist position before hiding
        persistTeleprompterFrame()
        teleprompterWindow?.orderOut(nil)
        hideTeleprompterControls()
    }

    func destroyTeleprompter() {
        if let obs = teleprompterMoveObserver {
            NotificationCenter.default.removeObserver(obs)
            teleprompterMoveObserver = nil
        }
        if let obs = teleprompterResizeObserver {
            NotificationCenter.default.removeObserver(obs)
            teleprompterResizeObserver = nil
        }
        if let obs = teleprompterPlacementObserver {
            NotificationCenter.default.removeObserver(obs)
            teleprompterPlacementObserver = nil
        }
        persistTeleprompterFrame()
        teleprompterWindow?.orderOut(nil)
        teleprompterWindow = nil
        hideTeleprompterControls()
    }

    func toggleTeleprompter() {
        if teleprompterWindow?.isVisible == true {
            hideTeleprompter()
        } else {
            showTeleprompter()
        }
    }

    var isTeleprompterVisible: Bool {
        teleprompterWindow?.isVisible ?? false
    }

    private func createTeleprompterWindow(appState: AppState) {
        let settings = appState.teleprompterSettings
        let frame = frameForPlacement(settings)
        let isDynamic = settings.placementMode == .dynamicIsland

        // Dynamic Island: borderless for a clean pill shape, just like textream.
        // Others: titled + resizable for standard window controls.
        let styleMask: NSWindow.StyleMask = isDynamic
            ? [.borderless, .nonactivatingPanel]
            : [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow, .fullSizeContentView]

        let panel = NSPanel(
            contentRect: frame,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        // Dynamic Island: .screenSaver level allows drawing perfectly over the menu bar / notch.
        if isDynamic {
            panel.level = .screenSaver
        } else {
            panel.level = .floating // Always on top by default
        }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = !isDynamic // No shadow for Dynamic Island — pure pill
        if isDynamic {
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        } else {
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
        panel.isReleasedWhenClosed = false
        panel.alphaValue = settings.opacity
        panel.ignoresMouseEvents = settings.isClickThrough
        panel.minSize = NSSize(width: 200, height: 100)

        // Dynamic Island: locked in place, not movable
        panel.isMovableByWindowBackground = !isDynamic

        // Determine sharing type: demo mode overrides exclusion
        panel.sharingType = Self.sharingType(for: settings)

        // Clean title bar (for non-borderless modes)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        // Show close button only if it's not dynamic island and NOT in click-through mode
        // Wait, user asked to show title bar for click-through mode, so we just check isDynamic
        panel.standardWindowButton(.closeButton)?.isHidden = isDynamic

        let overlayView = TeleprompterOverlayView(
            appState: appState,
            scrollController: appState.autoScrollController
        )
        let hostingView = NSHostingView(rootView: overlayView)
        panel.contentView = hostingView

        teleprompterWindow = panel

        // Persist position on move (only for non-locked modes)
        teleprompterMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let state = self.appState else { return }
                // Don't persist position for fixed placement modes
                if state.teleprompterSettings.placementMode == .floating {
                    self.persistTeleprompterFrame()
                }
            }
        }

        // Persist position on resize
        teleprompterResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let state = self.appState else { return }
                if state.teleprompterSettings.placementMode == .floating {
                    self.persistTeleprompterFrame()
                }
            }
        }

        // Observe placement mode changes from Settings
        teleprompterPlacementObserver = NotificationCenter.default.addObserver(
            forName: .teleprompterPlacementChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyTeleprompterPlacement()
            }
        }
    }

    /// Apply live setting changes to the teleprompter window
    private func applyTeleprompterSettings(_ settings: TeleprompterSettings) {
        guard let panel = teleprompterWindow else { return }
        panel.alphaValue = settings.opacity
        panel.level = .floating
        panel.ignoresMouseEvents = settings.isClickThrough
        panel.sharingType = Self.sharingType(for: settings)
    }

    /// Reposition the teleprompter for the current placement mode.
    /// Recreates the window when switching to/from Dynamic Island
    /// (because NSWindow.styleMask can't be changed between borderless and titled).
    func applyTeleprompterPlacement() {
        guard let appState = appState else { return }
        let wasVisible = teleprompterWindow?.isVisible == true

        // Destroy and recreate to apply new styleMask
        destroyTeleprompter()
        createTeleprompterWindow(appState: appState)

        if wasVisible {
            teleprompterWindow?.orderFrontRegardless()
        }
    }

    /// Compute the window frame for a given placement mode.
    private func frameForPlacement(_ settings: TeleprompterSettings) -> CGRect {
        switch settings.placementMode {
        case .dynamicIsland:
            return dynamicIslandFrame()

        case .presentationTop:
            return presentationTopFrame()

        case .floating:
            // Use saved position or default center
            return settings.windowFrame ?? defaultTeleprompterFrame()
        }
    }

    /// Dynamic Island: compact pill-shaped window pinned to the very top center
    /// of the screen, flush against the top edge, overlapping the notch area.
    private func dynamicIslandFrame() -> CGRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return defaultTeleprompterFrame() }

        let screenFrame = screen.frame

        // Compact pill dimensions — wide enough for text, short enough to feel native
        let width: CGFloat = min(420, screenFrame.width * 0.30)
        let height: CGFloat = min(320, screenFrame.height * 0.28)
        let x = screenFrame.midX - width / 2

        // Flush against the very top of the screen
        let y = screenFrame.maxY - height

        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Presentation Top: wide and narrow strip at top of screen
    private func presentationTopFrame() -> CGRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return defaultTeleprompterFrame() }

        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let menuBarHeight = screenFrame.maxY - visibleFrame.maxY
        let topInset = menuBarHeight + 4

        let width = screenFrame.width * 0.75
        let height: CGFloat = 280
        let x = screenFrame.midX - width / 2
        let y = screenFrame.maxY - topInset - height

        return CGRect(x: x, y: y, width: width, height: height)
    }


    /// Default frame: center of main screen, 420×600
    private func defaultTeleprompterFrame() -> CGRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let width: CGFloat = 420
        let height: CGFloat = 600
        let x = screenFrame.midX - width / 2
        let y = screenFrame.midY - height / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Persist current teleprompter frame to settings
    private func persistTeleprompterFrame() {
        guard let panel = teleprompterWindow, let appState = appState else { return }
        appState.teleprompterSettings.setWindowFrame(panel.frame)
        if let screen = panel.screen {
            appState.teleprompterSettings.lastScreenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
        }
    }

    /// Compute correct NSWindowSharingType for a given set of settings.
    /// Demo Mode (`isVisibleInRecordings`) takes priority and forces `.readOnly`.
    static func sharingType(for settings: TeleprompterSettings) -> NSWindow.SharingType {
        return settings.isVisibleInRecordings ? .readOnly : .none
    }

    /// Update the live teleprompter panel's sharing type in-place.
    /// Called when the user toggles "Exclude from Recording" or "Demo Mode".
    func updateTeleprompterSharingType() {
        guard let panel = teleprompterWindow, let appState = appState else { return }
        panel.sharingType = Self.sharingType(for: appState.teleprompterSettings)
    }

    // MARK: - Teleprompter Control Panel

    func showTeleprompterControls() {
        guard let appState = appState else { return }

        if teleprompterControlWindow == nil {
            createTeleprompterControlWindow(appState: appState)
        }

        // Position: next to teleprompter window if visible, otherwise center on screen
        if let teleWindow = teleprompterWindow, teleWindow.isVisible {
            let x = teleWindow.frame.maxX + 12
            let y = teleWindow.frame.midY - teleprompterControlWindow!.frame.height / 2
            teleprompterControlWindow?.setFrameOrigin(NSPoint(x: x, y: y))
        } else if teleprompterControlWindow?.isVisible != true {
            teleprompterControlWindow?.center()
        }

        teleprompterControlWindow?.orderFrontRegardless()
    }

    func hideTeleprompterControls() {
        teleprompterControlWindow?.orderOut(nil)
    }

    func toggleTeleprompterControls() {
        if teleprompterControlWindow?.isVisible == true {
            hideTeleprompterControls()
        } else {
            showTeleprompterControls()
        }
    }

    private func createTeleprompterControlWindow(appState: AppState) {
        let controlView = TeleprompterControlPanel(
            appState: appState,
            scrollController: appState.autoScrollController,
            overlayManager: self,
            onClose: { [weak self] in
                self?.hideTeleprompterControls()
            }
        )

        let hostingView = NSHostingView(rootView: controlView)
        let contentSize = NSSize(width: 400, height: 720)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.sharingType = .readOnly  // Allow screenshots (only the overlay uses .none)

        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        panel.contentView = hostingView
        teleprompterControlWindow = panel
    }
}

// MARK: - InteractiveOverlayWindow

/// A custom NSWindow subclass that allows borderless transparent windows
/// to become the key window and reliably receive mouse/keyboard events.
class InteractiveOverlayWindow: NSWindow {
    override var canBecomeKey: Bool {
        return true
    }
    
    override var canBecomeMain: Bool {
        return true
    }
}
