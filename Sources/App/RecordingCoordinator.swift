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
    let overlayManager = OverlayWindowManager()
    private var videoWriter: VideoWriter?
    private var isSetUp = false

    init(appState: AppState) {
        self.appState = appState
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
            }
        }

        // Setup overlay windows
        overlayManager.setup(appState: appState, cameraManager: cameraManager)

        // Silent permission checks (no prompts)
        appState.hasCameraPermission = PermissionManager.shared.checkCameraPermission()
        appState.hasMicrophonePermission = PermissionManager.shared.checkMicrophonePermission()
        appState.hasAccessibilityPermission = PermissionManager.shared.checkAccessibilityPermission()
        appState.hasScreenPermission = true

        print("🎬 Setup complete!")
    }

    // MARK: - Start Recording

    func startRecording() async {
        guard !appState.isRecording else { return }

        if !isSetUp { await setup() }

        // Request camera & mic if not determined
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            appState.hasCameraPermission = await AVCaptureDevice.requestAccess(for: .video)
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            appState.hasMicrophonePermission = await AVCaptureDevice.requestAccess(for: .audio)
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

        // Countdown (camera is visible and warming up, nothing is recording yet)
        appState.isCountingDown = true
        for i in stride(from: 3, through: 1, by: -1) {
            appState.countdownValue = i
            print("  ⏱ \(i)...")
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
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
            screenCapture.onMicSampleBuffer = { [weak writer] buffer in
                writer?.appendMicBuffer(buffer)
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

        // 4. Stop keystroke monitor
        keystrokeMonitor.stopMonitoring()

        // 5. Drain buffers
        try? await Task.sleep(nanoseconds: 200_000_000)

        // 6. Finalize video
        if let writer = videoWriter {
            do {
                let url = try await writer.stopWriting()
                print("✅ Recording saved to: \(url.path)")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                print("❌ Failed to save recording: \(error)")
            }
        }

        videoWriter = nil
    }

    // MARK: - Toggle Recording

    func toggleRecording() async {
        if appState.isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
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
            appState.activeKeystrokes.removeAll()
        }
    }

    // MARK: - Helpers

    private func startKeystrokeMonitorWithPermissionCheck() {
        // Don't prompt — just try to start monitoring.
        // If accessibility isn't granted, the CGEvent tap will fail silently.
        // This avoids the repeated dialog on every rebuild.
        if AXIsProcessTrusted() {
            appState.hasAccessibilityPermission = true
            keystrokeMonitor.startMonitoring()
        } else {
            // Try anyway — the permission might be granted for the bundle but
            // AXIsProcessTrusted() returns false due to CDHash mismatch after rebuild
            keystrokeMonitor.startMonitoring()
            // If it actually worked (event tap succeeded), mark as granted
            if keystrokeMonitor.isMonitoring {
                appState.hasAccessibilityPermission = true
            } else {
                appState.hasAccessibilityPermission = false
                print("⚠️ Accessibility permission needed for keystroke overlay")
                print("   Enable in System Settings → Privacy → Accessibility")
            }
        }
    }
}
