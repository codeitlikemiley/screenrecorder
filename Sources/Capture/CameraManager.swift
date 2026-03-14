@preconcurrency import AVFoundation
import CoreMedia
import AppKit

/// Manages camera capture using AVFoundation.
/// Provides live camera frames as CMSampleBuffers for compositing and preview.
@MainActor
class CameraManager: NSObject, ObservableObject {
    private(set) var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var videoDelegate: CameraOutputDelegate?
    private var interruptionObserver: NSObjectProtocol?
    private var resumeObserver: NSObjectProtocol?

    @Published var availableCameras: [AVCaptureDevice] = []
    @Published var selectedCamera: AVCaptureDevice?
    @Published var isRunning = false
    /// True when another process (e.g. Presenter Overlay) has stolen the camera
    @Published var isInterrupted = false

    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

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

    func startCamera() throws {
        guard let camera = selectedCamera else { return }

        let session = AVCaptureSession()
        session.sessionPreset = .high

        // Add input
        let input = try AVCaptureDeviceInput(device: camera)
        if session.canAddInput(input) {
            session.addInput(input)
        }

        // Add output
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

        captureSession = session
        videoOutput = output
        videoDelegate = delegate

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
        videoOutput = nil
        videoDelegate = nil
        isRunning = false
        isInterrupted = false
    }

    // MARK: - Get Preview Layer

    func previewLayer() -> AVCaptureVideoPreviewLayer? {
        guard let session = captureSession else { return nil }
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }
}

// MARK: - Camera Output Delegate

private class CameraOutputDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onSampleBuffer?(sampleBuffer)
    }
}
