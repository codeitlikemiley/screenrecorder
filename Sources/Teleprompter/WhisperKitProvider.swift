import Foundation
import CoreMedia
import AVFoundation
import WhisperKit

// MARK: - WhisperKit Speech Provider

/// WhisperKit-based speech provider for higher accuracy with accented speech.
/// Uses OpenAI Whisper models running on-device via Apple Silicon CoreML.
///
/// **Architecture**:
/// - Downloads and loads a Whisper model on first use (~150MB for base)
/// - Captures audio via AVAudioEngine (or external feed from ScreenCaptureKit)
/// - Accumulates audio in a rolling buffer (16kHz mono Float32)
/// - Runs transcription periodically on accumulated audio
/// - Emits cumulative word list via `onWords`
class WhisperKitProvider: SpeechProvider {

    var onWords: (([String]) -> Void)?
    private(set) var isListening: Bool = false
    var useExternalAudioFeed: Bool = false

    /// RMS energy level for VAD
    private(set) var currentRMS: Float = 0

    // MARK: - WhisperKit

    private var whisperKit: WhisperKit?
    private var isModelLoaded: Bool = false

    /// Model to use. "base" = ~150MB, good speed/accuracy.
    /// "tiny" = fastest but less accurate. "large-v3" = best accuracy but slow.
    private let modelName = "base"

    // MARK: - Audio Buffer

    private var audioEngine: AVAudioEngine?

    /// Rolling audio buffer (16kHz mono Float32 samples)
    private var audioSamples: [Float] = []
    private let samplesLock = NSLock()

    /// Transcription loop task
    private var transcriptionTask: Task<Void, Never>?

    /// How often to run transcription (seconds)
    private let transcriptionInterval: TimeInterval = 1.5

    /// Min audio duration before attempting transcription
    private let minAudioSeconds: Double = 1.0

    private var currentLocale: String = "en"

    // MARK: - Lifecycle

    func start(locale: String) {
        currentLocale = locale.components(separatedBy: "-").first ?? "en"

        Task {
            await loadModelAndStart()
        }
    }

    func stop() {
        isListening = false
        transcriptionTask?.cancel()
        transcriptionTask = nil

        if !useExternalAudioFeed {
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine?.stop()
            audioEngine = nil
        }

        samplesLock.lock()
        audioSamples.removeAll()
        samplesLock.unlock()

        print("🛑 WhisperKitProvider: stopped")
    }

    // MARK: - External Audio Feed

    func feedAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard useExternalAudioFeed, isModelLoaded else { return }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        var lengthOut = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &lengthOut, dataPointerOut: &dataPointer)
        guard let dataPointer else { return }

        var samples = [Float](repeating: 0, count: frameCount)

        if asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            let floatPtr = UnsafeRawPointer(dataPointer).bindMemory(to: Float.self, capacity: frameCount)
            for i in 0..<frameCount { samples[i] = floatPtr[i] }
        } else if asbd.pointee.mBitsPerChannel == 16 {
            let int16Ptr = UnsafeRawPointer(dataPointer).bindMemory(to: Int16.self, capacity: frameCount)
            for i in 0..<frameCount { samples[i] = Float(int16Ptr[i]) / Float(Int16.max) }
        }

        // Resample to 16kHz if needed
        let sourceSR = asbd.pointee.mSampleRate
        if abs(sourceSR - 16000) > 100 {
            samples = Self.linearResample(samples, from: sourceSR, to: 16000)
        }

        appendSamples(samples)
    }

    // MARK: - Model Loading

    private func loadModelAndStart() async {
        do {
            print("🔄 WhisperKitProvider: loading model '\(modelName)'...")

            let config = WhisperKitConfig(model: modelName)
            let pipe = try await WhisperKit(config)
            whisperKit = pipe
            isModelLoaded = true

            print("✅ WhisperKitProvider: model loaded successfully")

            await MainActor.run {
                if !useExternalAudioFeed {
                    startInternalAudioEngine()
                } else {
                    print("🎤 WhisperKitProvider: waiting for external audio feed")
                }
                startTranscriptionLoop()
                isListening = true
                print("🎤 WhisperKitProvider: listening (\(currentLocale), model: \(modelName), external: \(useExternalAudioFeed))")
            }
        } catch {
            print("⚠️ WhisperKitProvider: model load failed: \(error)")
            print("⚠️ WhisperKitProvider: falling back to Apple Speech")
            await MainActor.run {
                fallbackToAppleSpeech()
            }
        }
    }

    // MARK: - Internal Audio Engine (self-managed mic)

    private func startInternalAudioEngine() {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        print("🎤 WhisperKitProvider: mic format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch")

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Extract float samples from channel 0
            guard let channelData = buffer.floatChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            var rawSamples = [Float](repeating: 0, count: frameLength)
            for i in 0..<frameLength {
                rawSamples[i] = channelData[0][i]
            }

            // Resample to 16kHz if needed
            if abs(inputFormat.sampleRate - 16000) > 100 {
                rawSamples = Self.linearResample(rawSamples, from: inputFormat.sampleRate, to: 16000)
            }

            self.appendSamples(rawSamples)
            self.updateRMS(rawSamples)
        }

        do {
            try engine.start()
            audioEngine = engine
            print("✅ WhisperKitProvider: internal mic started")
        } catch {
            print("⚠️ WhisperKitProvider: audio engine failed: \(error)")
        }
    }

    // MARK: - Audio Buffer Management

    private func appendSamples(_ samples: [Float]) {
        samplesLock.lock()
        audioSamples.append(contentsOf: samples)

        // Keep last 30 seconds at 16kHz
        let maxSamples = 30 * 16000
        if audioSamples.count > maxSamples {
            audioSamples.removeFirst(audioSamples.count - maxSamples)
        }
        samplesLock.unlock()
    }

    private func getSamplesCopy() -> [Float] {
        samplesLock.lock()
        let copy = audioSamples
        samplesLock.unlock()
        return copy
    }

    // MARK: - Transcription Loop

    private func startTranscriptionLoop() {
        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self?.transcriptionInterval ?? 1.5) * 1_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.runTranscription()
            }
        }
    }

    private func runTranscription() async {
        guard let pipe = whisperKit, isModelLoaded else { return }

        let samples = getSamplesCopy()

        // Need at least minAudioSeconds of audio at 16kHz
        let minSamples = Int(minAudioSeconds * 16000)
        guard samples.count >= minSamples else {
            return
        }

        do {
            let options = DecodingOptions(
                verbose: true,
                language: currentLocale,
                temperature: 0,
                temperatureFallbackCount: 2,
                usePrefillPrompt: true,
                usePrefillCache: true,
                withoutTimestamps: true,
                suppressBlank: true,
                noSpeechThreshold: 0.3
            )

            let results: [TranscriptionResult] = try await pipe.transcribe(
                audioArray: samples,
                decodeOptions: options
            )

            // Combine all segment texts
            var allWords: [String] = []
            for result in results {
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                    allWords.append(contentsOf: words)
                }
            }

            if !allWords.isEmpty {
                print("🗣️ WhisperKit: \(allWords.count) words: \(allWords.suffix(5).joined(separator: " "))")
                await MainActor.run { [weak self] in
                    self?.onWords?(allWords)
                }
            }
        } catch {
            print("⚠️ WhisperKit transcription error: \(error.localizedDescription)")
        }
    }

    // MARK: - Fallback

    private var appleFallback: AppleSpeechProvider?

    private func fallbackToAppleSpeech() {
        let provider = AppleSpeechProvider()
        provider.onWords = onWords
        provider.useExternalAudioFeed = useExternalAudioFeed
        provider.start(locale: "\(currentLocale)-US")
        appleFallback = provider
        isListening = true
    }

    // MARK: - Helpers

    private func updateRMS(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = sqrtf(sum / Float(samples.count))
        DispatchQueue.main.async { [weak self] in
            self?.currentRMS = rms
        }
    }

    /// Simple linear interpolation resampling
    static func linearResample(_ samples: [Float], from sourceSR: Double, to targetSR: Double) -> [Float] {
        guard sourceSR != targetSR, !samples.isEmpty else { return samples }
        let ratio = targetSR / sourceSR
        let outputCount = Int(Double(samples.count) * ratio)
        guard outputCount > 0 else { return [] }
        var output = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let srcIdx = Double(i) / ratio
            let idx = Int(srcIdx)
            let frac = Float(srcIdx - Double(idx))
            if idx + 1 < samples.count {
                output[i] = samples[idx] * (1 - frac) + samples[idx + 1] * frac
            } else if idx < samples.count {
                output[i] = samples[idx]
            }
        }
        return output
    }
}
