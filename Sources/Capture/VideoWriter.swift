import AVFoundation
import CoreMedia
import CoreVideo
import CoreImage
import Accelerate

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

    // Pause support (all accessed on writerQueue). Timestamps are host-clock seconds, the same
    // timebase ScreenCaptureKit stamps buffers with. Buffers captured while paused are dropped
    // and everything after is shifted back by the total paused time, so the file has no gap.
    private var pausedAt: Double?
    private var lastPauseInterval: ClosedRange<Double>?
    private var pauseOffset: Double = 0
    private var lastVideoPTS: CMTime?

    /// Host-clock time (seconds) of the first video frame, i.e. t = 0 of the output file.
    /// Used to align the interaction log with the video.
    var firstFrameHostTime: Double? {
        writerQueue.sync { firstTimestamp?.seconds }
    }

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

    // Black-frame detection: caches the last non-black frame so we can
    // substitute it when the compositor sends all-black content (e.g.
    // AeroSpace moving windows off-screen during workspace switches).
    private var lastGoodPixelBuffer: CVPixelBuffer?
    private var consecutiveBlackFrames: Int = 0

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
        pausedAt = nil
        lastPauseInterval = nil
        pauseOffset = 0
        lastVideoPTS = nil

        print("  📝 Asset writer started (status: \(writer.status.rawValue))")
    }

    // MARK: - Pause / Resume

    func setPaused(_ paused: Bool) {
        let now = InteractionLogger.hostNow()
        writerQueue.sync {
            if paused {
                if pausedAt == nil { pausedAt = now }
            } else if let start = pausedAt {
                pauseOffset += now - start
                lastPauseInterval = start...now
                pausedAt = nil
            }
        }
    }

    /// Whether a buffer stamped `seconds` (host clock) falls in a paused span. Call on writerQueue.
    private func isInPausedSpan(_ seconds: Double) -> Bool {
        if let pausedAt, seconds >= pausedAt { return true }
        if let span = lastPauseInterval, span.contains(seconds) { return true }
        return false
    }

    /// Shift a sample buffer back by the accumulated pause time. Call on writerQueue.
    private func retimed(_ buffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard pauseOffset > 0 else { return buffer }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return buffer }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count) == noErr else {
            return nil
        }
        let offset = CMTime(seconds: pauseOffset, preferredTimescale: 1_000_000_000)
        for i in timing.indices {
            timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp, offset)
            if timing[i].decodeTimeStamp.isValid {
                timing[i].decodeTimeStamp = CMTimeSubtract(timing[i].decodeTimeStamp, offset)
            }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: buffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timing,
            sampleBufferOut: &out
        )
        return out
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

            let captureTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard captureTimestamp.isValid && !captureTimestamp.isIndefinite else { return }
            guard !isInPausedSpan(captureTimestamp.seconds) else { return }
            let timestamp = pauseOffset > 0
                ? CMTimeSubtract(captureTimestamp, CMTime(seconds: pauseOffset, preferredTimescale: 1_000_000_000))
                : captureTimestamp
            // Timestamps must strictly increase (a late pre-pause frame could otherwise go backwards).
            if let last = lastVideoPTS, CMTimeCompare(timestamp, last) <= 0 { return }

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

            // --- Black-frame detection ---
            // AeroSpace (and similar tiling WMs) move windows off-screen when
            // switching workspaces. ScreenCaptureKit still delivers frames with
            // status .complete, but the pixel content is all-black. Detect this
            // and substitute the last known-good frame to create a freeze-frame
            // effect instead of recording black.
            var bufferToWrite = screenPixelBuffer
            if isFrameBlack(screenPixelBuffer) {
                consecutiveBlackFrames += 1
                if let lastGood = lastGoodPixelBuffer {
                    bufferToWrite = lastGood
                    if consecutiveBlackFrames == 1 {
                        print("  ⏸️ Black frame detected — substituting last good frame (workspace switch?)")
                    }
                }
                // If we have no last-good frame yet (recording just started),
                // fall through and write the black frame — nothing else we can do.
            } else {
                if consecutiveBlackFrames > 0 {
                    print("  ▶️ Content restored after \(consecutiveBlackFrames) black frames")
                }
                consecutiveBlackFrames = 0
                lastGoodPixelBuffer = screenPixelBuffer
                bufferToWrite = screenPixelBuffer
            }

            // Composite camera if enabled and we have a camera frame
            var finalPixelBuffer = bufferToWrite
            if isCameraEnabled, let cameraBuffer = latestCameraPixelBuffer, let ctx = ciContext {
                if let composited = compositeCamera(screenBuffer: bufferToWrite, cameraBuffer: cameraBuffer, context: ctx) {
                    finalPixelBuffer = composited
                }
            }

            // Append frame
            if videoInput.isReadyForMoreMediaData {
                let success = pixelBufferAdaptor?.append(finalPixelBuffer, withPresentationTime: timestamp) ?? false
                if success {
                    lastVideoPTS = timestamp
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

    // MARK: - Black Frame Detection

    /// Samples 9 pixels in a 3×3 grid across the frame. If ALL sampled pixels
    /// have R, G, and B channels below `threshold`, the frame is considered black.
    /// This is extremely fast — only 9 pixel reads regardless of resolution.
    private func isFrameBlack(_ pixelBuffer: CVPixelBuffer, threshold: UInt8 = 10) -> Bool {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return true }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        // Don't check tiny/degenerate buffers
        guard width > 4, height > 4 else { return true }

        // 3×3 grid of sample points, avoiding the very edges
        let samplePoints: [(Int, Int)] = [
            (width / 4,     height / 4),
            (width / 2,     height / 4),
            (3 * width / 4, height / 4),
            (width / 4,     height / 2),
            (width / 2,     height / 2),
            (3 * width / 4, height / 2),
            (width / 4,     3 * height / 4),
            (width / 2,     3 * height / 4),
            (3 * width / 4, 3 * height / 4),
        ]

        let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)

        for (x, y) in samplePoints {
            let offset = y * bytesPerRow + x * 4  // BGRA = 4 bytes per pixel
            let b = ptr[offset]
            let g = ptr[offset + 1]
            let r = ptr[offset + 2]
            // If ANY sample pixel has visible content, the frame is not black
            if r > threshold || g > threshold || b > threshold {
                return false
            }
        }

        return true
    }

    func appendAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isWriting, sessionStarted else { return }
        writerQueue.sync { appendAudioLocked(sampleBuffer, to: audioInput) }
    }

    func appendMicBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isWriting, sessionStarted else { return }
        writerQueue.sync { appendAudioLocked(sampleBuffer, to: micInput) }
    }

    /// Append mic buffer with gain applied (volume scaling)
    func appendMicBuffer(_ sampleBuffer: CMSampleBuffer, gain: Float) {
        guard isWriting, sessionStarted else { return }
        guard let scaledBuffer = applyGain(to: sampleBuffer, gain: gain) else {
            // Fallback: append without scaling
            appendMicBuffer(sampleBuffer)
            return
        }
        writerQueue.sync { appendAudioLocked(scaledBuffer, to: micInput) }
    }

    /// Shared audio path: drop paused audio, shift for earlier pauses, append. Call on writerQueue.
    private func appendAudioLocked(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard let input,
              let writer = assetWriter,
              writer.status == .writing else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard timestamp.isValid && !timestamp.isIndefinite else { return }
        guard !isInPausedSpan(timestamp.seconds) else { return }
        guard let buffer = retimed(sampleBuffer) else { return }

        if input.isReadyForMoreMediaData {
            input.append(buffer)
        }
    }

    /// Apply gain to audio sample buffer using vDSP
    private func applyGain(to buffer: CMSampleBuffer, gain: Float) -> CMSampleBuffer? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { return nil }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return nil }

        // Get audio data
        var dataPointer: UnsafeMutablePointer<Int8>?
        var lengthAtOffset: Int = 0
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: nil, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let data = dataPointer else { return nil }
        // The pointer only covers the first contiguous segment. Scaling `length` bytes through it
        // would write past that segment on a non-contiguous buffer, so skip gain in that case.
        guard lengthAtOffset >= length,
              CMBlockBufferIsRangeContiguous(blockBuffer, atOffset: 0, length: length) else { return nil }

        // Check format — assume 16-bit PCM (standard mic format)
        guard let formatDesc = CMSampleBufferGetFormatDescription(buffer) else { return nil }
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
        
        if let asbd = asbd, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            // Float32 audio
            let sampleCount = length / MemoryLayout<Float>.size
            data.withMemoryRebound(to: Float.self, capacity: sampleCount) { floatPtr in
                var g = gain
                vDSP_vsmul(floatPtr, 1, &g, floatPtr, 1, vDSP_Length(sampleCount))
            }
        } else {
            // Int16 PCM audio — convert, scale, convert back
            let sampleCount = length / MemoryLayout<Int16>.size
            data.withMemoryRebound(to: Int16.self, capacity: sampleCount) { int16Ptr in
                for i in 0..<sampleCount {
                    let scaled = Float(int16Ptr[i]) * gain
                    int16Ptr[i] = Int16(max(-32768, min(32767, scaled)))
                }
            }
        }

        return buffer  // Modified in-place
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

        // Mirror horizontally to match the preview overlay (natural mirror)
        let flippedCamera = scaledCamera
            .transformed(by: CGAffineTransform(scaleX: -1, y: 1)
                .translatedBy(x: -scaledCamera.extent.width, y: 0))

        // Center-crop to a square (camera is wider than tall)
        let scaledWidth = flippedCamera.extent.width
        let scaledHeight = flippedCamera.extent.height
        let cropOffsetX = (scaledWidth - targetSize) / 2
        let cropOffsetY = (scaledHeight - targetSize) / 2
        let centerCropRect = CGRect(x: cropOffsetX, y: cropOffsetY, width: targetSize, height: targetSize)

        // Crop to circle using radial gradient as mask
        let center = CIVector(x: targetSize / 2, y: targetSize / 2)
        let circularMask = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": center,
            "inputRadius0": targetSize / 2 - 2,
            "inputRadius1": targetSize / 2,
            "inputColor0": CIColor.white,
            "inputColor1": CIColor.clear
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: targetSize, height: targetSize))

        // Crop scaled camera from center, then shift to origin for masking
        let croppedCamera = flippedCamera
            .cropped(to: centerCropRect)
            .transformed(by: CGAffineTransform(translationX: -cropOffsetX, y: -cropOffsetY))

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

        print("  📝 Finalizing... (\(frameCount) frames written, \(consecutiveBlackFrames > 0 ? "\(consecutiveBlackFrames) trailing black frames suppressed" : "no black frames detected"))")

        // Release cached frame buffer
        lastGoodPixelBuffer = nil
        consecutiveBlackFrames = 0

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
