import SwiftUI
import ScreenCaptureKit
import AVFoundation

/// Coordinates all recording activities — connects screen capture, camera, audio, and video writing.
@MainActor
class RecordingCoordinator: ObservableObject {
    let appState: AppState
    let screenCapture = ScreenCaptureManager()
    let cameraManager = CameraManager()
    let keystrokeMonitor = KeystrokeMonitor()
    let mouseMonitor = MouseMonitor()
    let overlayManager = OverlayWindowManager()
    let interactionLogger = InteractionLogger()
    let postProcessor = PostRecordingProcessor()
    let agentServer = AgentServer()
    private var agentRouter: AgentRouter?
    private var videoWriter: VideoWriter?
    private var accessibilityTimer: Timer?
    private var isSetUp = false

    /// Called whenever annotation mode changes. AppDelegate uses this to
    /// register/unregister annotation-only global hotkeys.
    var onAnnotationModeChanged: ((_ isActive: Bool) -> Void)?

    init(appState: AppState) {
        self.appState = appState
        // Start the RPC server immediately so the CLI can connect as soon
        // as the app launches — no need to click the menu bar icon first.
        Task { @MainActor [weak self] in
            self?.startAgentServer()
        }
    }

    // MARK: - Setup (lightweight — NO permission prompts)

    func setup() async {
        guard !isSetUp else { return }
        isSetUp = true

        print("🎬 Setting up Screen Recorder...")

        // Setup camera (discover devices only)
        cameraManager.setup()
        print("  ✅ Camera manager ready (\(cameraManager.availableCameras.count) cameras)")

        // Setup keystroke monitor callback
        keystrokeMonitor.onKeystroke = { [weak self] event in
            guard let self = self else { return }
            Task { @MainActor in
                if self.appState.isKeystrokeOverlayEnabled {
                    self.appState.addKeystroke(event)
                }
                // Log keystrokes to metadata only in AI mode
                if self.appState.isRecording && self.appState.recordingMode == .ai {
                    self.interactionLogger.logKeystroke(
                        key: event.keyString,
                        modifiers: event.modifiers.map(\.symbol),
                        isSpecialKey: event.isSpecialKey
                    )
                }
            }
        }

        // Setup mouse monitor callbacks
        mouseMonitor.onMouseClick = { [weak self] position, button, clickCount in
            self?.interactionLogger.logMouseClick(position: position, button: button, clickCount: clickCount)
        }
        mouseMonitor.onMouseDrag = { [weak self] startPos, endPos, duration in
            self?.interactionLogger.logMouseDrag(startPosition: startPos, endPosition: endPos, duration: duration)
        }
        mouseMonitor.onMouseScroll = { [weak self] position, deltaX, deltaY in
            self?.interactionLogger.logMouseScroll(position: position, deltaX: deltaX, deltaY: deltaY)
        }

        // Setup overlay windows
        overlayManager.setup(appState: appState, cameraManager: cameraManager)
        overlayManager.onAnnotationScreenshot = { [weak self] in
            self?.captureAnnotationScreenshot()
        }

        // Silent permission checks (no prompts)
        appState.hasCameraPermission = PermissionManager.shared.checkCameraPermission()
        appState.hasMicrophonePermission = PermissionManager.shared.checkMicrophonePermission()
        appState.hasScreenPermission = true

        // For Accessibility: AXIsProcessTrusted() can return false even when
        // the toggle is ON in System Settings (CDHash mismatch after rebuild).
        // So we try the event tap directly — if it works, we have real permission.
        if appState.isKeystrokeOverlayEnabled {
            keystrokeMonitor.startMonitoring()
        }
        // Derive permission state from whether the tap actually succeeded
        appState.hasAccessibilityPermission = keystrokeMonitor.isMonitoring || AXIsProcessTrusted()

        // Periodically re-check Accessibility permission (macOS doesn't apply
        // it until restart, but we poll so the Settings UI stays honest and
        // we can auto-start monitoring the moment it becomes available).
        startAccessibilityPolling()

        // Start agent server for programmatic control (idempotent — safe if already started)
        startAgentServer()

        print("🎬 Setup complete!")
    }

    // MARK: - Agent Server

    /// Start the JSON-RPC agent server. Safe to call multiple times — AgentServer
    /// and this method both guard against double-start.
    private func startAgentServer() {
        guard appState.isAgentServerEnabled, agentRouter == nil else { return }
        let router = AgentRouter(appState: appState, coordinator: self)
        self.agentRouter = router
        agentServer.start(router: router)
    }

    // MARK: - Start Recording

    func startRecording() async {
        guard !appState.isRecording else { return }

        if !isSetUp { await setup() }

        // 1. Request all needed permissions (prompt if first time, open Settings if denied)
        if appState.isCameraEnabled {
            let granted = await PermissionManager.shared.requestCameraPermission()
            appState.hasCameraPermission = granted
            if !granted { appState.isCameraEnabled = false }
        }
        if appState.isMicrophoneEnabled {
            let granted = await PermissionManager.shared.requestMicrophonePermission()
            appState.hasMicrophonePermission = granted
            if !granted { appState.isMicrophoneEnabled = false }
        }
        if appState.isKeystrokeOverlayEnabled {
            // Try the tap directly — AXIsProcessTrusted() is unreliable after rebuilds
            if !keystrokeMonitor.isMonitoring {
                keystrokeMonitor.startMonitoring()
            }
            appState.hasAccessibilityPermission = keystrokeMonitor.isMonitoring || AXIsProcessTrusted()
        }

        // 2. Check if any new permissions were granted since app launch → restart needed
        let newGrants = PermissionManager.shared.checkForNewGrants()
        if !newGrants.isEmpty {
            let names = newGrants.joined(separator: ", ")
            let alert = NSAlert()
            alert.messageText = "Restart Required"
            alert.informativeText = "New permissions granted: \(names).\n\nmacOS requires an app restart for these to take effect. Restart now?"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Restart Now")
            alert.addButton(withTitle: "Continue Anyway")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                PermissionManager.shared.restartApp()
                return
            }
        }

        // Show system content picker (handles screen recording permission internally)
        let filter: SCContentFilter
        do {
            filter = try await screenCapture.pickContent()
        } catch CaptureError.pickerCancelled {
            print("ℹ️ User cancelled content picker")
            return
        } catch {
            print("❌ Content picker failed: \(error)")
            return
        }

        appState.hasScreenPermission = true

        // Pre-warm camera BEFORE countdown (so it's ready when recording starts)
        if appState.isCameraEnabled {
            do {
                // Wire position tracking — updates VideoWriter to composite camera where user drags
                overlayManager.onCameraPositionChanged = { [weak self] normalized in
                    self?.videoWriter?.cameraPositionNormalized = normalized
                }
                try cameraManager.startCamera()
                overlayManager.showCamera()
                print("  ✅ Camera pre-warmed")
                // Give camera 300ms to start producing frames
                try? await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                print("  ⚠️ Camera failed to start: \(error)")
            }
        }

        // Countdown overlay (visible fullscreen 3→2→1)
        appState.isCountingDown = true
        print("  ⏱ Showing countdown overlay...")
        await overlayManager.showCountdown(appState: appState)
        appState.isCountingDown = false

        let outputURL = appState.generateOutputURL()
        appState.currentRecordingURL = outputURL

        print("🎬 Starting recording to: \(outputURL.lastPathComponent)")

        do {
            // Use actual screen pixel dimensions (must match stream config)
            let screen = NSScreen.main ?? NSScreen.screens.first
            let scale = Int(screen?.backingScaleFactor ?? 2)
            let width = Int(screen?.frame.width ?? 1920) * scale
            let height = Int(screen?.frame.height ?? 1080) * scale

            print("  📐 Capture resolution: \(width)x\(height)")

            // Setup video writer
            let writer = VideoWriter(outputURL: outputURL, format: appState.outputFormat)
            writer.isCameraEnabled = appState.isCameraEnabled
            writer.cameraSize = appState.cameraSize
            try writer.setup(videoWidth: width, videoHeight: height, includeMicrophone: appState.isMicrophoneEnabled)
            try writer.startWriting()
            videoWriter = writer

            // Wire camera frames to writer for compositing
            if appState.isCameraEnabled {
                cameraManager.onSampleBuffer = { [weak writer] sampleBuffer in
                    if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                        writer?.updateCameraFrame(pixelBuffer)
                    }
                }
            }

            // Wire screen capture → video writer
            screenCapture.onVideoSampleBuffer = { [weak writer] buffer in
                writer?.appendVideoBuffer(buffer)
            }
            screenCapture.onAudioSampleBuffer = { [weak writer] buffer in
                writer?.appendAudioBuffer(buffer)
            }
            screenCapture.onMicSampleBuffer = { [weak writer, weak self] buffer in
                // During recording, isMicMuted or volume 0 silences mic
                guard let self = self else { return }
                let volume = self.appState.micVolume
                guard !self.appState.isMicMuted, volume > 0 else { return }

                // Scale audio by volume: 5 = 1.0x (default), 10 = 2.0x, 1 = 0.2x
                if volume != 5 {
                    let gain = Float(volume) / 5.0
                    writer?.appendMicBuffer(buffer, gain: gain)
                } else {
                    writer?.appendMicBuffer(buffer)
                }
            }

            // Start screen capture using the picked filter
            try await screenCapture.startCapture(
                frameRate: appState.frameRate,
                captureMicrophone: appState.isMicrophoneEnabled,
                filter: filter
            )
            print("  ✅ Screen capture started")

            // Start keystroke monitor if enabled
            if appState.isKeystrokeOverlayEnabled {
                startKeystrokeMonitorWithPermissionCheck()
            }

            // Start interaction logging only in AI mode
            if appState.recordingMode == .ai {
                interactionLogger.startSession()
                mouseMonitor.startMonitoring()
                print("  📋 Interaction logging started (AI mode)")
            } else {
                print("  ℹ️ Normal recording mode — skipping interaction logging")
            }

            // NOW mark as recording and start timer
            appState.isRecording = true
            appState.startRecordingTimer()

            print("🔴 Recording in progress!")

        } catch {
            print("❌ Failed to start recording: \(error)")
            appState.isCountingDown = false
            // Clean up camera if recording failed
            if appState.isCameraEnabled {
                cameraManager.stopCamera()
                overlayManager.destroyCameraWindow()
            }
        }
    }

    // MARK: - Stop Recording

    func stopRecording() async {
        guard appState.isRecording else { return }

        print("⏹ Stopping recording...")

        appState.isRecording = false
        appState.isPaused = false
        appState.stopRecordingTimer()

        // 1. Stop screen capture FIRST
        do {
            try await screenCapture.stopCapture()
            print("  ✅ Screen capture stopped")
        } catch {
            print("  ⚠️ Error stopping capture: \(error)")
        }

        // 2. Clear content filter so picker shows again for next recording
        screenCapture.clearContentFilter()

        // 3. Stop camera & destroy overlay (so it recreates with fresh session)
        cameraManager.stopCamera()
        cameraManager.onSampleBuffer = nil
        overlayManager.destroyCameraWindow()

        // 4. Stop transient monitors. Keep the keystroke monitor alive if the
        // feature is still enabled so the menu state matches reality after the
        // recording ends.
        if !appState.isKeystrokeOverlayEnabled {
            keystrokeMonitor.stopMonitoring()
        }
        mouseMonitor.stopMonitoring()

        // 4b. Deactivate annotation mode (keep strokes visible for review)
        if appState.isAnnotationModeActive {
            appState.isAnnotationModeActive = false
            onAnnotationModeChanged?(false)
        }

        // 5. Drain buffers
        try? await Task.sleep(nanoseconds: 200_000_000)

        // 6. Finalize video
        if let writer = videoWriter {
            do {
                let url = try await writer.stopWriting()
                print("✅ Recording saved to: \(url.path)")

                if appState.recordingMode == .ai {
                    // 7. Flush interaction metadata as JSON sidecar
                    let metadataURL = interactionLogger.flush(videoURL: url)

                    // 8. Run post-recording processing pipeline (async, non-blocking)
                    let recordingDuration = appState.recordingDuration
                    Task {
                        let _ = await postProcessor.process(
                            videoURL: url,
                            metadataURL: metadataURL,
                            duration: recordingDuration
                        )
                    }
                    print("  🤖 AI pipeline launched")
                } else {
                    print("  ℹ️ Normal mode — video saved, no AI processing")
                }

                // Share-optimized export (if enabled)
                if appState.isShareOptimizedExportEnabled {
                    let shareURL = ShareOptimizedExporter.shareOutputURL(for: url)
                    print("📤 Share-optimized export enabled — exporting to \(shareURL.lastPathComponent)...")
                    do {
                        let exportedURL = try await ShareOptimizedExporter.export(sourceURL: url, outputURL: shareURL)
                        print("✅ Share-optimized file ready: \(exportedURL.path)")
                        // Open the share-optimized file in Finder instead of the original
                        NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
                    } catch {
                        print("⚠️ Share-optimized export failed: \(error.localizedDescription)")
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                print("❌ Failed to save recording: \(error)")
            }
        }

        videoWriter = nil
    }

    // MARK: - Toggle Recording

    func toggleRecording() async {
        if appState.isRecording {
            if appState.isCameraOnlyRecording {
                await stopCameraOnlyRecording()
            } else {
                await stopRecording()
            }
        } else {
            await startRecording()
        }
    }

    // MARK: - Camera-Only Recording

    private var cameraWriter: CameraWriter?

    func toggleCameraRecording() async {
        if appState.isRecording && appState.isCameraOnlyRecording {
            await stopCameraOnlyRecording()
        } else if !appState.isRecording {
            await startCameraOnlyRecording()
        }
    }

    func startCameraOnlyRecording() async {
        guard !appState.isRecording else { return }

        if !isSetUp { await setup() }

        // 1. Request camera permission
        let cameraGranted = await PermissionManager.shared.requestCameraPermission()
        appState.hasCameraPermission = cameraGranted
        guard cameraGranted else {
            print("❌ Camera permission denied — cannot record camera-only")
            return
        }

        // 2. Request microphone if enabled
        let includeMic = appState.isMicrophoneEnabled
        if includeMic {
            let micGranted = await PermissionManager.shared.requestMicrophonePermission()
            appState.hasMicrophonePermission = micGranted
            if !micGranted { appState.isMicrophoneEnabled = false }
        }

        // 3. Start camera WITH microphone in the same session
        do {
            try cameraManager.startCamera(includeMicrophone: appState.isMicrophoneEnabled)
            print("  ✅ Camera started for camera-only recording")

            // Show camera preview so user can see themselves
            overlayManager.showCamera()
            print("  ✅ Camera preview shown")

            // Give camera 300ms to start producing frames
            try? await Task.sleep(nanoseconds: 300_000_000)
        } catch {
            print("❌ Camera failed to start: \(error)")
            return
        }

        // 4. Countdown
        appState.isCountingDown = true
        print("  ⏱ Showing countdown overlay...")
        await overlayManager.showCountdown(appState: appState)
        appState.isCountingDown = false

        // 5. Determine camera resolution from the actual capture session
        let cameraResolution = getCameraResolution()
        let videoWidth = cameraResolution.width
        let videoHeight = cameraResolution.height

        let outputURL = appState.generateCameraOutputURL()
        appState.currentRecordingURL = outputURL

        print("🎬 Starting camera-only recording to: \(outputURL.lastPathComponent)")
        print("  📐 Camera resolution: \(videoWidth)x\(videoHeight)")

        do {
            // 6. Setup camera writer
            let writer = CameraWriter(outputURL: outputURL, format: appState.outputFormat)
            try writer.setup(
                videoWidth: videoWidth,
                videoHeight: videoHeight,
                includeMicrophone: appState.isMicrophoneEnabled
            )
            try writer.startWriting()
            cameraWriter = writer

            // 7. Wire camera frames directly to writer
            cameraManager.onSampleBuffer = { [weak writer] sampleBuffer in
                writer?.appendVideoBuffer(sampleBuffer)
            }

            // 8. Wire microphone audio from camera session to writer
            if appState.isMicrophoneEnabled {
                cameraManager.onAudioSampleBuffer = { [weak writer, weak self] buffer in
                    guard let self = self else { return }
                    let volume = self.appState.micVolume
                    guard !self.appState.isMicMuted, volume > 0 else { return }

                    if volume != 5 {
                        let gain = Float(volume) / 5.0
                        writer?.appendMicBuffer(buffer, gain: gain)
                    } else {
                        writer?.appendMicBuffer(buffer)
                    }
                }
                print("  🎤 Microphone wired to camera writer")
            }

            // 9. Wire camera position tracking for preview dragging
            overlayManager.onCameraPositionChanged = { _ in
                // No-op for camera-only — position only matters for screen compositing
            }

            // 10. Start keystroke monitor if enabled
            if appState.isKeystrokeOverlayEnabled {
                startKeystrokeMonitorWithPermissionCheck()
            }

            // 11. Mark as recording
            appState.isRecording = true
            appState.isCameraOnlyRecording = true
            appState.startRecordingTimer()

            print("🔴 Camera-only recording in progress!")

        } catch {
            print("❌ Failed to start camera-only recording: \(error)")
            appState.isCountingDown = false
            cameraManager.stopCamera()
            overlayManager.destroyCameraWindow()
        }
    }

    func stopCameraOnlyRecording() async {
        guard appState.isRecording, appState.isCameraOnlyRecording else { return }

        print("⏹ Stopping camera-only recording...")

        appState.isRecording = false
        appState.isCameraOnlyRecording = false
        appState.isPaused = false
        appState.stopRecordingTimer()

        // 1. Stop camera & destroy preview
        cameraManager.stopCamera()
        cameraManager.onSampleBuffer = nil
        cameraManager.onAudioSampleBuffer = nil
        overlayManager.destroyCameraWindow()

        // 2. Stop keystroke monitor if not user-enabled
        if !appState.isKeystrokeOverlayEnabled {
            keystrokeMonitor.stopMonitoring()
        }

        // 3. Drain buffers
        try? await Task.sleep(nanoseconds: 200_000_000)

        // 4. Finalize video
        if let writer = cameraWriter {
            do {
                let url = try await writer.stopWriting()
                print("✅ Camera recording saved to: \(url.path)")

                // Share-optimized export (if enabled)
                if appState.isShareOptimizedExportEnabled {
                    let shareURL = ShareOptimizedExporter.shareOutputURL(for: url)
                    print("📤 Share-optimized export enabled — exporting to \(shareURL.lastPathComponent)...")
                    do {
                        let exportedURL = try await ShareOptimizedExporter.export(sourceURL: url, outputURL: shareURL)
                        print("✅ Share-optimized file ready: \(exportedURL.path)")
                        NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
                    } catch {
                        print("⚠️ Share-optimized export failed: \(error.localizedDescription)")
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                print("❌ Failed to save camera recording: \(error)")
            }
        }

        cameraWriter = nil
    }

    /// Get camera capture resolution from the active session
    private func getCameraResolution() -> (width: Int, height: Int) {
        guard let camera = cameraManager.selectedCamera else {
            return (width: 1920, height: 1080) // Default fallback
        }
        let format = camera.activeFormat
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return (width: Int(dimensions.width), height: Int(dimensions.height))
    }

    // MARK: - Toggle Camera

    func toggleCamera() {
        if appState.isCameraEnabled && appState.isRecording {
            if !cameraManager.isRunning {
                cameraManager.onSampleBuffer = { [weak self] sampleBuffer in
                    if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                        self?.videoWriter?.updateCameraFrame(pixelBuffer)
                    }
                }
                try? cameraManager.startCamera()
            }
            overlayManager.showCamera()
            videoWriter?.isCameraEnabled = true
        } else {
            cameraManager.stopCamera()
            cameraManager.onSampleBuffer = nil
            overlayManager.hideCamera()
            videoWriter?.isCameraEnabled = false
        }
    }

    // MARK: - Toggle Keystroke Monitor

    func toggleKeystrokeMonitor() {
        if appState.isKeystrokeOverlayEnabled {
            startKeystrokeMonitorWithPermissionCheck()
        } else {
            keystrokeMonitor.stopMonitoring()
            appState.keystrokeDisplayText = ""
            appState.keystrokeVisible = false
        }
    }

    // MARK: - Helpers

    private func startKeystrokeMonitorWithPermissionCheck() {
        // Just try the tap directly — it's the true permission test
        keystrokeMonitor.startMonitoring()

        if keystrokeMonitor.isMonitoring {
            appState.hasAccessibilityPermission = true
            print("✅ Keystroke monitoring started successfully")
            return
        }

        // Tap failed. Don't disable the toggle — the polling timer will keep
        // retrying every 3s. Guide the user to fix the permission.
        print("⚠️ CGEvent tap failed — Accessibility permission not effective")

        if AXIsProcessTrusted() {
            // AXIsProcessTrusted says yes but tap failed — very rare, could be system issue
            appState.hasAccessibilityPermission = true
            print("   ℹ️  AXIsProcessTrusted() = true but tap failed. Try restarting the app.")
        } else {
            // Open System Settings on first attempt
            if !PermissionManager.shared.checkAccessibilityPermission() {
                _ = PermissionManager.shared.requestAccessibilityPermission()
            }
            print("   ℹ️  Toggle ScreenRecorder OFF then ON in System Settings → Accessibility")
            // Start polling to auto-detect when it works
            startAccessibilityPolling()
        }
    }

    // MARK: - Accessibility Polling

    /// Periodically attempt to acquire Accessibility permission.
    /// AXIsProcessTrusted() can return false after a rebuild (CDHash mismatch)
    /// even when the System Settings toggle is ON. So we also try creating the
    /// CGEvent tap directly — if THAT works, we have real permission.
    ///
    /// We poll every 3 seconds until either AXIsProcessTrusted() returns true
    /// or we successfully start the keystroke monitor.
    private func startAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        // Don't poll if we already have a working tap
        guard !keystrokeMonitor.isMonitoring else {
            appState.hasAccessibilityPermission = true
            return
        }

        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self = self else { timer.invalidate(); return }

                // Try 1: Check AXIsProcessTrusted()
                let axTrusted = AXIsProcessTrusted()

                // Try 2: If keystroke overlay is enabled but monitor isn't running,
                // try starting it. CGEvent.tapCreate() is the real permission test.
                if !self.keystrokeMonitor.isMonitoring && self.appState.isKeystrokeOverlayEnabled {
                    self.keystrokeMonitor.startMonitoring()
                }

                let reallyWorks = self.keystrokeMonitor.isMonitoring
                let wasGranted = self.appState.hasAccessibilityPermission
                let nowGranted = axTrusted || reallyWorks
                self.appState.hasAccessibilityPermission = nowGranted

                if !wasGranted && nowGranted {
                    print("✅ Accessibility permission granted (detected by polling)")
                    if reallyWorks {
                        print("✅ Keystroke monitoring auto-started after permission grant")
                    }
                }

                // Stop polling once we have a working tap or confirmed trust
                if nowGranted {
                    timer.invalidate()
                    self.accessibilityTimer = nil
                }
            }
        }
        RunLoop.main.add(accessibilityTimer!, forMode: .common)
    }

    // MARK: - Annotation Mode

    /// Toggle annotation drawing mode on/off
    func toggleAnnotationMode() {
        appState.isAnnotationModeActive.toggle()
        let isActive = appState.isAnnotationModeActive
        onAnnotationModeChanged?(isActive)
        print(isActive ? "✏️ Annotation mode activated" : "✏️ Annotation mode deactivated")
    }

    /// Clear all annotation strokes
    func clearAnnotations() {
        appState.annotationState.clearAll()
        print("🗑 Annotations cleared")
    }

    /// Capture a screenshot of the screen including annotations
    func captureAnnotationScreenshot() {
        ScreenshotCapture.captureAndSave(
            defaultDirectory: appState.saveDirectory,
            hideToolbar: { [weak self] in
                self?.overlayManager.hideAnnotationToolbarForCapture()
            },
            showToolbar: { [weak self] in
                // Only re-show if annotation mode is still active
                if self?.appState.isAnnotationModeActive == true {
                    self?.overlayManager.showAnnotationToolbarAfterCapture()
                }
            }
        )
    }
}
