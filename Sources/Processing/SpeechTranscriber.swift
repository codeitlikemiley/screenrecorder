import Speech
import AVFoundation

/// Transcribes speech from a video recording's audio track using Apple's on-device Speech framework.
/// Runs entirely locally — no cloud dependency.
/// Produces timestamped transcript segments for synchronization with interaction events.
class SpeechTranscriber {

    struct TranscriptSegment: Codable {
        let text: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        let confidence: Float
    }

    struct TranscriptResult: Codable {
        let fullText: String
        let segments: [TranscriptSegment]
        let language: String
        let durationProcessed: TimeInterval
    }

    // MARK: - Check Availability

    /// Check if on-device speech recognition is available
    static var isAvailable: Bool {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        return recognizer?.isAvailable ?? false
    }

    /// Check and request speech recognition authorization
    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: - Transcribe

    /// Transcribe the audio track from a video file.
    /// Extracts the mic audio track, then runs on-device speech recognition.
    func transcribe(videoURL: URL) async throws -> TranscriptResult {
        // Check authorization
        let authorized = await Self.requestAuthorization()
        guard authorized else {
            throw TranscriberError.notAuthorized
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw TranscriberError.recognizerUnavailable
        }

        // Prefer on-device recognition for privacy
        if #available(macOS 13.0, *) {
            if recognizer.supportsOnDeviceRecognition {
                print("🎙️ Using on-device speech recognition")
            } else {
                print("🎙️ On-device recognition not available, will use server")
            }
        }

        print("🎙️ Starting transcription of \(videoURL.lastPathComponent)...")

        // Extract audio to a temporary file for processing
        let audioURL = try await extractAudioTrack(from: videoURL)

        // Run speech recognition
        let request = SFSpeechURLRecognitionRequest(url: audioURL)

        // Request on-device processing if available
        if #available(macOS 13.0, *) {
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        }

        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SFSpeechRecognitionResult, Error>) in
            recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                if let result = result, result.isFinal {
                    continuation.resume(returning: result)
                }
                // Non-final results are ignored — we wait for the final one
            }
        }

        // Build timestamped segments from transcription results
        let segments = buildSegments(from: result)

        // Cleanup temp audio file
        try? FileManager.default.removeItem(at: audioURL)

        let transcript = TranscriptResult(
            fullText: result.bestTranscription.formattedString,
            segments: segments,
            language: "en-US",
            durationProcessed: result.bestTranscription.segments.last.map {
                $0.timestamp + $0.duration
            } ?? 0
        )

        print("🎙️ Transcription complete: \(transcript.fullText.count) characters, \(segments.count) segments")
        return transcript
    }

    // MARK: - Extract Audio Track

    /// Extract audio from video into a temporary WAV file for speech recognition
    private func extractAudioTrack(from videoURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)

        // Check for audio tracks
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw TranscriberError.noAudioTrack
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech_\(UUID().uuidString).wav")

        // Use AVAssetExportSession to extract audio
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriberError.exportFailed
        }

        exportSession.outputURL = tempURL.deletingPathExtension().appendingPathExtension("m4a")
        exportSession.outputFileType = .m4a

        // Only export audio (no video)
        let audioTimeRange = try await asset.load(.duration)
        exportSession.timeRange = CMTimeRange(start: .zero, duration: audioTimeRange)

        await exportSession.export()

        if exportSession.status == .failed {
            throw exportSession.error ?? TranscriberError.exportFailed
        }

        let outputURL = exportSession.outputURL ?? tempURL
        print("  🔊 Audio extracted: \(ByteCountFormatter.string(fromByteCount: Int64((try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0), countStyle: .file))")

        return outputURL
    }

    // MARK: - Build Segments

    private func buildSegments(from result: SFSpeechRecognitionResult) -> [TranscriptSegment] {
        let transcription = result.bestTranscription

        return transcription.segments.map { segment in
            TranscriptSegment(
                text: segment.substring,
                startTime: segment.timestamp,
                endTime: segment.timestamp + segment.duration,
                confidence: segment.confidence
            )
        }
    }
}

// MARK: - Errors

enum TranscriberError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable
    case noAudioTrack
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Speech recognition not authorized"
        case .recognizerUnavailable: return "Speech recognizer not available"
        case .noAudioTrack: return "No audio track found in recording"
        case .exportFailed: return "Failed to extract audio from video"
        }
    }
}
