@preconcurrency import AVFoundation
import CoreMedia
import AppKit

/// Manages camera capture using AVFoundation.
/// Provides live camera frames as CMSampleBuffers for compositing and preview.
/// Optionally captures microphone audio in the same session (for camera-only recording).
@MainActor
class CameraManager: NSObject, ObservableObject {
    private(set) var captureSession: AVCaptureSession?
    private(set) var videoPreviewLayer: AVCaptureVideoPreviewLayer?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var videoDelegate: CameraOutputDelegate?
    private var audioDelegate: AudioOutputDelegate?
    private var interruptionObserver: NSObjectProtocol?
    private var resumeObserver: NSObjectProtocol?

    @Published var availableCameras: [AVCaptureDevice] = []
    @Published var selectedCamera: AVCaptureDevice?
    @Published var isRunning = false
    /// True when another process (e.g. Presenter Overlay) has stolen the camera
    @Published var isInterrupted = false

    var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)?

    // MARK: - Setup

    func setup() {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        availableCameras = discoverySession.devices
        selectedCamera = availableCameras.first
    }

    // MARK: - Start Camera

    /// Start camera capture, optionally including microphone audio.
    /// - Parameter includeMicrophone: If true, also captures mic audio in the same session.
    func startCamera(includeMicrophone: Bool = false) throws {
        guard let camera = selectedCamera else { return }

        let session = AVCaptureSession()
        session.sessionPreset = .high

        // Add video input
        let input = try AVCaptureDeviceInput(device: camera)
        if session.canAddInput(input) {
            session.addInput(input)
        }

        // Add video output
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        let delegate = CameraOutputDelegate()
        delegate.onSampleBuffer = { [weak self] buffer in
            self?.onSampleBuffer?(buffer)
        }
        output.setSampleBufferDelegate(delegate, queue: DispatchQueue(label: "com.screenrecorder.camera", qos: .userInitiated))

        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        // Create preview layer synchronously BEFORE startRunning to avoid mutation crash
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill

        captureSession = session
        videoPreviewLayer = preview
        videoOutput = output
        videoDelegate = delegate

        // Add microphone input + output if requested (for camera-only recording)
        if includeMicrophone {
            if let mic = AVCaptureDevice.default(for: .audio) {
                do {
                    let micInput = try AVCaptureDeviceInput(device: mic)
                    if session.canAddInput(micInput) {
                        session.addInput(micInput)
                    }

                    let audioOut = AVCaptureAudioDataOutput()
                    let audioDel = AudioOutputDelegate()
                    audioDel.onAudioBuffer = { [weak self] buffer in
                        self?.onAudioSampleBuffer?(buffer)
                    }
                    audioOut.setSampleBufferDelegate(audioDel, queue: DispatchQueue(label: "com.screenrecorder.camera.audio", qos: .userInitiated))

                    if session.canAddOutput(audioOut) {
                        session.addOutput(audioOut)
                    }

                    audioOutput = audioOut
                    audioDelegate = audioDel
                    print("  🎤 Microphone added to camera session")
                } catch {
                    print("  ⚠️ Failed to add microphone to camera session: \(error)")
                }
            } else {
                print("  ⚠️ No microphone device found")
            }
        }

        // Listen for session interruptions (Presenter Overlay, other apps stealing camera)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionWasInterrupted,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                print("📷 Camera interrupted (Presenter Overlay or other app took camera)")
                self?.isInterrupted = true
            }
        }

        resumeObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionInterruptionEnded,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                print("📷 Camera resumed")
                self?.isInterrupted = false
            }
        }

        let captureSession = session
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            captureSession.startRunning()
            Task { @MainActor in
                self?.isRunning = true
            }
        }
    }

    // MARK: - Stop Camera

    func stopCamera() {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        if let observer = resumeObserver {
            NotificationCenter.default.removeObserver(observer)
            resumeObserver = nil
        }
        captureSession?.stopRunning()
        captureSession = nil
        videoPreviewLayer = nil
        videoOutput = nil
        audioOutput = nil
        videoDelegate = nil
        audioDelegate = nil
        isRunning = false
        isInterrupted = false
    }

    // MARK: - Get Preview Layer

    func previewLayer() -> AVCaptureVideoPreviewLayer? {
        return videoPreviewLayer
    }
}

// MARK: - Camera Output Delegate

private class CameraOutputDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onSampleBuffer?(sampleBuffer)
    }
}

// MARK: - Audio Output Delegate

private class AudioOutputDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    var onAudioBuffer: ((CMSampleBuffer) -> Void)?

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onAudioBuffer?(sampleBuffer)
    }
}
