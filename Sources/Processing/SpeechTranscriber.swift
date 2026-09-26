import Speech
import AVFoundation

/// Transcribes narration from a recording using Apple's Speech framework.
///
/// - Uses the **microphone track** only (recordings store system audio and mic as separate
///   tracks; mixing them would transcribe whatever was playing on the Mac). Falls back to the
///   system-audio track when there is no mic track.
/// - Uses the user's language, on-device when supported. Server recognition is limited to about
///   a minute per request, so without on-device support the audio is transcribed in chunks.
/// - Produces sentence-like segments (utterances) plus per-word timings.
class SpeechTranscriber {

    struct TranscriptSegment: Codable {
        let text: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        let confidence: Float
    }

    struct TranscriptResult: Codable {
        let fullText: String
        /// Utterances: words grouped at pauses/sentence ends. (Older sessions stored single words here.)
        let segments: [TranscriptSegment]
        let language: String
        let durationProcessed: TimeInterval
        /// Individual words with timings.
        var words: [TranscriptSegment]? = nil
        /// Which audio track was transcribed: "microphone" or "system".
        var source: String? = nil
    }

    /// Longest audio sent per request when on-device recognition isn't available.
    private let serverChunkSeconds: Double = 50
    /// A pause longer than this starts a new utterance.
    private let utterancePause: TimeInterval = 0.8
    /// Utterances are split once they get this long.
    private let maxUtteranceSeconds: TimeInterval = 15

    // MARK: - Availability

    /// Recognizer for the user's language, falling back to US English.
    static func makeRecognizer() -> SFSpeechRecognizer? {
        if let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable {
            return recognizer
        }
        return SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    static var isAvailable: Bool {
        makeRecognizer()?.isAvailable ?? false
    }

    /// Returns whether speech recognition is authorized, prompting only if the user hasn't decided yet.
    static func requestAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        default: break
        }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: - Transcribe

    func transcribe(videoURL: URL) async throws -> TranscriptResult {
        guard await Self.requestAuthorization() else {
            throw TranscriberError.notAuthorized
        }
        guard let recognizer = Self.makeRecognizer(), recognizer.isAvailable else {
            throw TranscriberError.recognizerUnavailable
        }

        let asset = AVURLAsset(url: videoURL)
        let (track, source) = try await pickAudioTrack(in: asset)
        let trackRange = try await track.load(.timeRange)
        let duration = trackRange.duration.seconds
        guard duration > 0.3 else { throw TranscriberError.noAudioTrack }

        let onDevice = recognizer.supportsOnDeviceRecognition
        let chunkLength = onDevice ? duration : serverChunkSeconds
        print("🎙️ Transcribing \(source) audio (\(String(format: "%.0f", duration))s, \(recognizer.locale.identifier), \(onDevice ? "on-device" : "server, \(Int(chunkLength))s chunks"))")

        var words: [TranscriptSegment] = []
        var texts: [String] = []
        var lastError: Error?
        var succeededChunks = 0

        var chunkStart = 0.0
        while chunkStart < duration {
            let length = min(chunkLength, duration - chunkStart)
            let range = CMTimeRange(
                start: CMTimeAdd(trackRange.start, CMTime(seconds: chunkStart, preferredTimescale: 600)),
                duration: CMTime(seconds: length, preferredTimescale: 600)
            )
            do {
                let audioURL = try await exportAudio(track: track, range: range)
                defer { try? FileManager.default.removeItem(at: audioURL) }
                let result = try await recognize(url: audioURL, with: recognizer, onDevice: onDevice)
                succeededChunks += 1
                let text = result.bestTranscription.formattedString
                if !text.isEmpty { texts.append(text) }
                words += result.bestTranscription.segments.map {
                    TranscriptSegment(
                        text: $0.substring,
                        startTime: chunkStart + $0.timestamp,
                        endTime: chunkStart + $0.timestamp + $0.duration,
                        confidence: $0.confidence
                    )
                }
            } catch {
                // A silent chunk reports "no speech detected"; keep going with the rest.
                lastError = error
                print("  🎙️ Chunk at \(Int(chunkStart))s: \(error.localizedDescription)")
            }
            chunkStart += length
        }

        if succeededChunks == 0, let lastError, !Self.isNoSpeechError(lastError) {
            throw lastError
        }

        let transcript = TranscriptResult(
            fullText: texts.joined(separator: " "),
            segments: groupIntoUtterances(words),
            language: recognizer.locale.identifier,
            durationProcessed: duration,
            words: words,
            source: source
        )
        print("🎙️ Transcription complete: \(transcript.fullText.count) characters, \(transcript.segments.count) utterances")
        return transcript
    }

    // MARK: - Audio

    /// The mic is written as its own track after the system-audio track, so with two audio
    /// tracks the last one is the mic.
    private func pickAudioTrack(in asset: AVURLAsset) async throws -> (AVAssetTrack, String) {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let last = tracks.last else { throw TranscriberError.noAudioTrack }
        return (last, tracks.count >= 2 ? "microphone" : "system")
    }

    /// Export one track's time range to a temporary .m4a file.
    private func exportAudio(track: AVAssetTrack, range: CMTimeRange) async throws -> URL {
        let composition = AVMutableComposition()
        guard let compTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw TranscriberError.exportFailed
        }
        try compTrack.insertTimeRange(range, of: track, at: .zero)

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriberError.exportFailed
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speech_\(UUID().uuidString).m4a")
        export.outputURL = url
        export.outputFileType = .m4a
        await export.export()
        guard export.status == .completed else {
            throw export.error ?? TranscriberError.exportFailed
        }
        return url
    }

    // MARK: - Recognition

    private func recognize(url: URL, with recognizer: SFSpeechRecognizer, onDevice: Bool) async throws -> SFSpeechRecognitionResult {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = onDevice
        request.addsPunctuation = true

        // The result handler can fire more than once (e.g. a final result followed by an error);
        // resuming a continuation twice crashes, so only the first outcome counts.
        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    if once.claim() { continuation.resume(returning: result) }
                } else if let error {
                    if once.claim() { continuation.resume(throwing: error) }
                }
            }
        }
    }

    private final class ResumeOnce {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    /// Speech framework reports silence as an error (kAFAssistantErrorDomain 1110 / 203).
    private static func isNoSpeechError(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == "kAFAssistantErrorDomain" && (ns.code == 1110 || ns.code == 203)
    }

    // MARK: - Utterances

    private func groupIntoUtterances(_ words: [TranscriptSegment]) -> [TranscriptSegment] {
        var utterances: [TranscriptSegment] = []
        var current: [TranscriptSegment] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let confidence = current.map(\.confidence).reduce(0, +) / Float(current.count)
            utterances.append(TranscriptSegment(
                text: current.map(\.text).joined(separator: " "),
                startTime: first.startTime,
                endTime: last.endTime,
                confidence: confidence
            ))
            current.removeAll()
        }

        for word in words {
            if let last = current.last, let first = current.first,
               word.startTime - last.endTime > utterancePause || word.endTime - first.startTime > maxUtteranceSeconds {
                flush()
            }
            current.append(word)
            if let end = word.text.last, ".?!".contains(end) { flush() }
        }
        flush()
        return utterances
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
