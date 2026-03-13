import ScreenCaptureKit
import CoreMedia
import AppKit

/// Manages screen capture using ScreenCaptureKit.
/// Uses SCContentSharingPicker for content selection (handles permissions via system UI).
@MainActor
class ScreenCaptureManager: NSObject, ObservableObject, SCContentSharingPickerObserver {
    private var stream: SCStream?
    private var streamOutput: CaptureStreamOutput?
    private var contentFilter: SCContentFilter?

    @Published var isPickerComplete = false
    @Published var pickerError: String?

    // Continuations for async picker flow
    private var pickerContinuation: CheckedContinuation<SCContentFilter, Error>?

    // Callbacks
    var onVideoSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onMicSampleBuffer: ((CMSampleBuffer) -> Void)?

    // MARK: - Content Selection via System Picker

    /// Shows the system content sharing picker (like Zoom's screen selection).
    /// This handles screen recording permission internally — no separate dialog.
    func pickContent() async throws -> SCContentFilter {
        // If we already have a content filter from a previous selection, reuse it
        if let existing = contentFilter {
            return existing
        }

        let picker = SCContentSharingPicker.shared
        picker.add(self)
        picker.isActive = true

        // Configure picker to show all options
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleDisplay, .singleApplication, .singleWindow]
        picker.defaultConfiguration = config

        // Show the picker and wait for user selection
        let filter = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SCContentFilter, Error>) in
            self.pickerContinuation = continuation
            picker.present()
        }

        contentFilter = filter
        return filter
    }

    // MARK: - SCContentSharingPickerObserver

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in
            pickerContinuation?.resume(throwing: CaptureError.pickerCancelled)
            pickerContinuation = nil
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            contentFilter = filter
            pickerContinuation?.resume(returning: filter)
            pickerContinuation = nil
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            pickerContinuation?.resume(throwing: error)
            pickerContinuation = nil
        }
    }

    // MARK: - Start Capture (uses filter from picker OR fallback)

    func startCapture(frameRate: Int = 30, captureMicrophone: Bool = false, filter: SCContentFilter? = nil) async throws {
        let captureFilter: SCContentFilter
        if let f = filter {
            captureFilter = f
        } else if let cached = contentFilter {
            captureFilter = cached
        } else {
            throw CaptureError.noContentSelected
        }

        let config = SCStreamConfiguration()

        // Use actual screen pixel dimensions (accounts for Retina scale)
        let screen = NSScreen.main ?? NSScreen.screens.first
        let scale = Int(screen?.backingScaleFactor ?? 2)
        let screenWidth = Int(screen?.frame.width ?? 1920) * scale
        let screenHeight = Int(screen?.frame.height ?? 1080) * scale
        config.width = screenWidth
        config.height = screenHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        // System audio: only when mic is OFF (mic picks up ambient sounds naturally)
        // Having both causes double audio — same click recorded from both system + mic
        config.capturesAudio = !captureMicrophone
        config.sampleRate = 48000
        config.channelCount = 2

        // Enable microphone capture (macOS 15+)
        if captureMicrophone {
            if #available(macOS 15.0, *) {
                config.captureMicrophone = true
                config.sampleRate = 48000
                config.channelCount = 1  // Mono mic
            }
        }

        stream = SCStream(filter: captureFilter, configuration: config, delegate: nil)

        let output = CaptureStreamOutput()
        output.onVideoSampleBuffer = onVideoSampleBuffer
        output.onAudioSampleBuffer = onAudioSampleBuffer
        output.onMicSampleBuffer = onMicSampleBuffer
        streamOutput = output

        try stream?.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "com.screenrecorder.video", qos: .userInitiated))
        try stream?.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.screenrecorder.audio", qos: .userInitiated))

        if captureMicrophone {
            if #available(macOS 15.0, *) {
                try stream?.addStreamOutput(output, type: .microphone, sampleHandlerQueue: DispatchQueue(label: "com.screenrecorder.mic", qos: .userInitiated))
                print("  🎤 Microphone capture enabled")
            }
        }

        try await stream?.startCapture()
    }

    // MARK: - Fallback: Direct capture (for when picker isn't needed)

    func startCaptureDirectly(frameRate: Int = 30, captureMicrophone: Bool = false) async throws {
        // Only call SCShareableContent if we don't have a filter from the picker
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let excludedApps = content.applications.filter { app in
            app.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
        contentFilter = filter

        try await startCapture(frameRate: frameRate, captureMicrophone: captureMicrophone, filter: filter)
    }

    // MARK: - Stop Capture

    func stopCapture() async throws {
        try await stream?.stopCapture()
        stream = nil
        streamOutput = nil
    }

    /// Clear cached filter so next recording shows the picker again
    func clearContentFilter() {
        contentFilter = nil
    }
}

// MARK: - Stream Output Handler

private class CaptureStreamOutput: NSObject, SCStreamOutput {
    var onVideoSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onMicSampleBuffer: ((CMSampleBuffer) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        switch type {
        case .screen:
            onVideoSampleBuffer?(sampleBuffer)
        case .audio:
            onAudioSampleBuffer?(sampleBuffer)
        case .microphone:
            onMicSampleBuffer?(sampleBuffer)
        @unknown default:
            break
        }
    }
}

// MARK: - Errors

enum CaptureError: LocalizedError {
    case noDisplay
    case noContentSelected
    case pickerCancelled
    case captureNotStarted

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display available for capture"
        case .noContentSelected: return "No content selected for capture"
        case .pickerCancelled: return "Content selection was cancelled"
        case .captureNotStarted: return "Screen capture has not been started"
        }
    }
}
