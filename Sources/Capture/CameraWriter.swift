import AVFoundation
import CoreMedia
import CoreVideo

/// Writes camera-only video using AVAssetWriter.
/// Unlike VideoWriter (which composites screen + camera), this writes raw
/// camera frames directly — simpler, lower latency, native camera resolution.
class CameraWriter {
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    private var isWriting = false
    private var sessionStarted = false
    private var firstTimestamp: CMTime?

    private let outputFormat: OutputFormat
    private let outputURL: URL

    // Serial queue for thread-safe buffer appending
    private let writerQueue = DispatchQueue(label: "com.screenrecorder.camerawriter", qos: .userInitiated)

    // MARK: - Init

    init(outputURL: URL, format: OutputFormat) {
        self.outputURL = outputURL
        self.outputFormat = format
    }

    // MARK: - Setup

    func setup(videoWidth: Int, videoHeight: Int, includeMicrophone: Bool = false) throws {
        // Remove existing file
        try? FileManager.default.removeItem(at: outputURL)

        // Determine file type
        let fileType: AVFileType = outputFormat == .mp4H264 ? .mp4 : .mov

        // Create asset writer
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        assetWriter = writer

        // Video settings — use H.264 for wide compatibility (good for YC uploads)
        let videoCodec: AVVideoCodecType = outputFormat == .movHEVC ? .hevc : .h264
        let bitRate = min(videoWidth * videoHeight * 6, 15_000_000) // Higher quality for camera, cap 15 Mbps

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
        writer.add(vInput)
        videoInput = vInput

        // Pixel buffer adaptor
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: videoWidth,
            kCVPixelBufferHeightKey as String: videoHeight
        ]
        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: attrs
        )

        // Microphone audio input
        if includeMicrophone {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128000
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true
            writer.add(aInput)
            audioInput = aInput
        }
    }

    // MARK: - Start/Stop Writing

    func startWriting() throws {
        guard let writer = assetWriter else { throw CameraWriterError.notSetUp }
        guard writer.startWriting() else {
            throw CameraWriterError.startFailed(writer.error)
        }
        isWriting = true
    }

    func stopWriting() async throws -> URL {
        guard isWriting, let writer = assetWriter else { throw CameraWriterError.notWriting }

        isWriting = false
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        if writer.status == .failed {
            throw CameraWriterError.writeFailed(writer.error)
        }

        return outputURL
    }

    // MARK: - Append Buffers

    func appendVideoBuffer(_ sampleBuffer: CMSampleBuffer) {
        writerQueue.async { [weak self] in
            guard let self = self, self.isWriting else { return }
            guard let input = self.videoInput, input.isReadyForMoreMediaData else { return }

            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            if !self.sessionStarted {
                self.assetWriter?.startSession(atSourceTime: timestamp)
                self.sessionStarted = true
                self.firstTimestamp = timestamp
            }

            input.append(sampleBuffer)
        }
    }

    func appendMicBuffer(_ sampleBuffer: CMSampleBuffer, gain: Float = 1.0) {
        writerQueue.async { [weak self] in
            guard let self = self, self.isWriting else { return }
            guard let input = self.audioInput, input.isReadyForMoreMediaData else { return }

            if !self.sessionStarted { return }  // Wait for first video frame

            if gain != 1.0 {
                // Apply gain to audio
                if let scaled = Self.scaleAudio(sampleBuffer, gain: gain) {
                    input.append(scaled)
                }
            } else {
                input.append(sampleBuffer)
            }
        }
    }

    // MARK: - Audio Scaling

    private static func scaleAudio(_ buffer: CMSampleBuffer, gain: Float) -> CMSampleBuffer? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { return nil }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let data = dataPointer else { return nil }

        let floatCount = length / MemoryLayout<Float>.size
        data.withMemoryRebound(to: Float.self, capacity: floatCount) { floatPtr in
            for i in 0..<floatCount {
                floatPtr[i] *= gain
            }
        }

        return buffer
    }
}

// MARK: - Errors

enum CameraWriterError: Error, LocalizedError {
    case notSetUp
    case startFailed(Error?)
    case notWriting
    case writeFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .notSetUp: return "CameraWriter not set up"
        case .startFailed(let e): return "Failed to start writing: \(e?.localizedDescription ?? "unknown")"
        case .notWriting: return "CameraWriter not writing"
        case .writeFailed(let e): return "Writing failed: \(e?.localizedDescription ?? "unknown")"
        }
    }
}
