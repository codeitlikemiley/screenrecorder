import AVFoundation
import CoreMedia
import CoreVideo
import CoreImage

/// Manages video file writing using AVAssetWriter.
/// Supports HEVC (H.265) and H.264 encoding to MOV/MP4 containers.
/// Handles compositing camera overlay onto screen capture frames.
class VideoWriter {
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?       // System audio
    private var micInput: AVAssetWriterInput?          // Microphone audio
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    private var isWriting = false
    private var sessionStarted = false
    private var firstTimestamp: CMTime?
    private var frameCount = 0

    private let outputFormat: OutputFormat
    private let outputURL: URL

    // Camera compositing
    private var latestCameraPixelBuffer: CVPixelBuffer?
    private var ciContext: CIContext?
    private var videoWidth: Int = 0
    private var videoHeight: Int = 0
    var cameraSize: CGFloat = 160  // Diameter of camera circle in recording
    var isCameraEnabled: Bool = false
    /// Camera position as normalized coordinates (0,0 = bottom-left, 1,1 = top-right)
    /// Updated by OverlayWindowManager when user drags the camera window
    var cameraPositionNormalized: CGPoint = CGPoint(x: 0.9, y: 0.1)  // Default: bottom-right

    // Serial queue for thread-safe buffer appending
    private let writerQueue = DispatchQueue(label: "com.screenrecorder.writer", qos: .userInitiated)

    // MARK: - Init

    init(outputURL: URL, format: OutputFormat) {
        self.outputURL = outputURL
        self.outputFormat = format
    }

    // MARK: - Setup

    func setup(videoWidth: Int, videoHeight: Int, includeMicrophone: Bool = false) throws {
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight

        // Remove existing file
        try? FileManager.default.removeItem(at: outputURL)

        // Determine file type
        let fileType: AVFileType = outputFormat == .mp4H264 ? .mp4 : .mov

        // Create asset writer
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        assetWriter = writer

        // Video settings
        let videoCodec: AVVideoCodecType = outputFormat == .movHEVC ? .hevc : .h264
        let bitRate = min(videoWidth * videoHeight * 4, 20_000_000) // Cap at 20 Mbps

        var compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: bitRate,
            AVVideoExpectedSourceFrameRateKey: 30,
            AVVideoMaxKeyFrameIntervalKey: 60
        ]

        if outputFormat != .movHEVC {
            compressionProperties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: videoCodec,
            AVVideoWidthKey: videoWidth,
            AVVideoHeightKey: videoHeight,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]

        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        videoInput = vInput

        // Pixel buffer adaptor
        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: videoWidth,
            kCVPixelBufferHeightKey as String: videoHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        // System audio settings
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192000
        ]

        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        aInput.expectsMediaDataInRealTime = true
        audioInput = aInput

        // Add inputs
        if writer.canAdd(vInput) { writer.add(vInput) }
        if writer.canAdd(aInput) { writer.add(aInput) }

        // Microphone audio (separate track)
        if includeMicrophone {
            let micSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1,  // Mono mic
                AVEncoderBitRateKey: 128000
            ]
            let mInput = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
            mInput.expectsMediaDataInRealTime = true
            micInput = mInput
            if writer.canAdd(mInput) { writer.add(mInput) }
        }

        // Create CIContext for camera compositing
        if isCameraEnabled {
            ciContext = CIContext(options: [.useSoftwareRenderer: false])
        }
    }

    // MARK: - Start Writing

    func startWriting() throws {
        guard let writer = assetWriter else {
            throw WriterError.notSetup
        }

        guard writer.startWriting() else {
            throw WriterError.failedToStart(writer.error?.localizedDescription ?? "Unknown error")
        }

        isWriting = true
        sessionStarted = false
        firstTimestamp = nil
        frameCount = 0

        print("  📝 Asset writer started (status: \(writer.status.rawValue))")
    }

    // MARK: - Camera Frame Update

    /// Call this from the camera output delegate to provide the latest camera frame
    func updateCameraFrame(_ pixelBuffer: CVPixelBuffer) {
        writerQueue.sync {
            latestCameraPixelBuffer = pixelBuffer
        }
    }

    // MARK: - Append Buffers

    func appendVideoBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isWriting else { return }

        writerQueue.sync {
            guard let writer = assetWriter,
                  writer.status == .writing,
                  let videoInput = videoInput else { return }

            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard timestamp.isValid && !timestamp.isIndefinite else { return }

            // Start session with first valid timestamp
            if !sessionStarted {
                writer.startSession(atSourceTime: timestamp)
                sessionStarted = true
                firstTimestamp = timestamp
                print("  🎬 Session started at timestamp: \(timestamp.seconds)")
            }

            guard let screenPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                return
            }

            // Composite camera if enabled and we have a camera frame
            var finalPixelBuffer = screenPixelBuffer
            if isCameraEnabled, let cameraBuffer = latestCameraPixelBuffer, let ctx = ciContext {
                if let composited = compositeCamera(screenBuffer: screenPixelBuffer, cameraBuffer: cameraBuffer, context: ctx) {
                    finalPixelBuffer = composited
                }
            }

            // Append frame
            if videoInput.isReadyForMoreMediaData {
                let success = pixelBufferAdaptor?.append(finalPixelBuffer, withPresentationTime: timestamp) ?? false
                if success {
                    frameCount += 1
                    if frameCount % 150 == 0 {
                        print("  📹 Frames written: \(frameCount) (time: \(String(format: "%.1f", timestamp.seconds - (firstTimestamp?.seconds ?? 0)))s)")
                    }
                } else if writer.status == .failed {
                    print("  ❌ Writer failed: \(writer.error?.localizedDescription ?? "unknown")")
                }
            }
        }
    }

    func appendAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isWriting, sessionStarted else { return }

        writerQueue.sync {
            guard let audioInput = audioInput,
                  let writer = assetWriter,
                  writer.status == .writing else { return }

            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard timestamp.isValid && !timestamp.isIndefinite else { return }

            if audioInput.isReadyForMoreMediaData {
                audioInput.append(sampleBuffer)
            }
        }
    }

    func appendMicBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isWriting, sessionStarted else { return }

        writerQueue.sync {
            guard let micInput = micInput,
                  let writer = assetWriter,
                  writer.status == .writing else { return }

            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard timestamp.isValid && !timestamp.isIndefinite else { return }

            if micInput.isReadyForMoreMediaData {
                micInput.append(sampleBuffer)
            }
        }
    }

    // MARK: - Camera Compositing

    private func compositeCamera(screenBuffer: CVPixelBuffer, cameraBuffer: CVPixelBuffer, context: CIContext) -> CVPixelBuffer? {
        let screenImage = CIImage(cvPixelBuffer: screenBuffer)
        let cameraImage = CIImage(cvPixelBuffer: cameraBuffer)

        let screenWidth = CGFloat(CVPixelBufferGetWidth(screenBuffer))
        let screenHeight = CGFloat(CVPixelBufferGetHeight(screenBuffer))
        let cameraWidth = CGFloat(CVPixelBufferGetWidth(cameraBuffer))
        let cameraHeight = CGFloat(CVPixelBufferGetHeight(cameraBuffer))

        // Scale camera to desired size (circular overlay in bottom-right)
        let targetSize = cameraSize * 2  // Account for Retina
        let scaleX = targetSize / cameraWidth
        let scaleY = targetSize / cameraHeight
        let scale = max(scaleX, scaleY)

        // Scale and position camera
        let scaledCamera = cameraImage
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Crop to circle using radial gradient as mask
        let center = CIVector(x: targetSize / 2, y: targetSize / 2)
        let circularMask = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": center,
            "inputRadius0": targetSize / 2 - 2,
            "inputRadius1": targetSize / 2,
            "inputColor0": CIColor.white,
            "inputColor1": CIColor.clear
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: targetSize, height: targetSize))

        // Crop scaled camera to circle size
        let croppedCamera = scaledCamera.cropped(to: CGRect(x: 0, y: 0, width: targetSize, height: targetSize))

        // Apply circular mask
        let maskedCamera = croppedCamera.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputMaskImageKey: circularMask
        ])

        // Position camera using normalized coordinates (synced with overlay window)
        let padding: CGFloat = 20
        let maxX = screenWidth - targetSize - padding
        let maxY = screenHeight - targetSize - padding
        let translateX = min(max(padding, cameraPositionNormalized.x * screenWidth - targetSize / 2), maxX)
        let translateY = min(max(padding, cameraPositionNormalized.y * screenHeight - targetSize / 2), maxY)
        let positionedCamera = maskedCamera
            .transformed(by: CGAffineTransform(translationX: translateX, y: translateY))

        // Composite camera over screen
        let composited = positionedCamera.composited(over: screenImage)

        // Render to pixel buffer from pool (avoids black frame allocation)
        guard let pool = pixelBufferAdaptor?.pixelBufferPool else {
            // No pool yet — fall back to creating buffer (first few frames)
            var outputBuffer: CVPixelBuffer?
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
            ]
            CVPixelBufferCreate(kCFAllocatorDefault, Int(screenWidth), Int(screenHeight),
                               kCVPixelFormatType_32BGRA, attrs as CFDictionary, &outputBuffer)
            if let output = outputBuffer {
                context.render(composited, to: output)
            }
            return outputBuffer
        }

        var outputBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputBuffer)

        if let output = outputBuffer {
            context.render(composited, to: output)
        }

        return outputBuffer
    }

    // MARK: - Stop Writing

    func stopWriting() async throws -> URL {
        guard isWriting else {
            throw WriterError.notWriting
        }

        isWriting = false

        print("  📝 Finalizing... (\(frameCount) frames written)")

        // Wait for pending operations
        writerQueue.sync { /* drain */ }

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        micInput?.markAsFinished()

        guard let writer = assetWriter else {
            throw WriterError.notSetup
        }

        guard writer.status == .writing else {
            let errorMsg = writer.error?.localizedDescription ?? "unknown"
            throw WriterError.writingFailed("Writer status: \(writer.status.rawValue), error: \(errorMsg)")
        }

        await writer.finishWriting()

        if writer.status == .failed {
            let errorMsg = writer.error?.localizedDescription ?? "unknown"
            throw WriterError.writingFailed(errorMsg)
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = attrs?[.size] as? Int ?? 0
        print("  ✅ Recording finalized: \(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file))")

        return outputURL
    }

    var status: AVAssetWriter.Status? {
        assetWriter?.status
    }
}

// MARK: - Errors

enum WriterError: LocalizedError {
    case notSetup
    case failedToStart(String)
    case notWriting
    case writingFailed(String)

    var errorDescription: String? {
        switch self {
        case .notSetup: return "Video writer not set up"
        case .failedToStart(let msg): return "Failed to start writing: \(msg)"
        case .notWriting: return "Not currently writing"
        case .writingFailed(let msg): return "Writing failed: \(msg)"
        }
    }
}
