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
            let granted = PermissionManager.shared.requestAccessibilityPermission()
            appState.hasAccessibilityPermission = granted
            if !granted { appState.isKeystrokeOverlayEnabled = false }
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
            screenCapture.onMicSampleBuffer = { [weak writer, weak self] buffer in
                // During recording, isMicMuted silences mic without stopping it
                guard self?.appState.isMicMuted != true else { return }
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
            appState.keystrokeDisplayText = ""
            appState.keystrokeVisible = false
        }
    }

    // MARK: - Helpers

    private func startKeystrokeMonitorWithPermissionCheck() {
        let trusted = AXIsProcessTrusted()
        print("🔑 Accessibility check: AXIsProcessTrusted = \(trusted)")

        // Try to create the event tap first (might work even if AXIsProcessTrusted is false)
        keystrokeMonitor.startMonitoring()

        if keystrokeMonitor.isMonitoring {
            appState.hasAccessibilityPermission = true
            print("✅ Keystroke monitoring started successfully")
            return
        }

        // Tap failed — prompt the user ONCE to grant permission for this binary
        print("⚠️ CGEvent tap failed, prompting for Accessibility permission...")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        appState.hasAccessibilityPermission = false
        print("❌ Keystroke overlay disabled — approve Accessibility permission, then restart recording")
    }
}
