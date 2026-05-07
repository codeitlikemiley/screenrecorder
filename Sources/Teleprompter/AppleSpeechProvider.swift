import Foundation
import Speech
import AVFoundation
import CoreMedia

// MARK: - Apple Speech Provider

/// SFSpeechRecognizer-based speech provider. Low latency (~200ms partial results),
/// works on-device or with network, auto-restarts on the ~60s timeout.
///
/// Supports two audio input modes:
/// 1. **Self-managed** (default): Creates its own AVAudioEngine tap on the microphone.
/// 2. **External feed**: Receives CMSampleBuffers from an external source (e.g. ScreenCaptureKit
///    mic capture). Use this when another subsystem already owns the microphone.
class AppleSpeechProvider: SpeechProvider {

    var onWords: (([RecognizedWord]) -> Void)?
    private(set) var isListening: Bool = false

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?

    /// RMS energy level for VAD
    private(set) var currentRMS: Float = 0

    /// When true, the provider does NOT create its own AVAudioEngine.
    /// Instead, call `feedAudioBuffer(_:)` to push CMSampleBuffers from an external source.
    var useExternalAudioFeed: Bool = false

    private var currentLocale: String = "en-US"

    func start(locale: String) {
        currentLocale = locale
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                switch status {
                case .authorized:
                    self.startRecognition(locale: locale)
                case .denied, .restricted:
                    print("⚠️ AppleSpeechProvider: permission denied")
                case .notDetermined:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    func stop() {
        stopInternal()
        isListening = false
    }

    // MARK: - External Audio Feed

    /// Push a CMSampleBuffer from an external audio source (e.g. ScreenCaptureKit mic).
    /// Only works when `useExternalAudioFeed = true`.
    func feedAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard useExternalAudioFeed, let request = recognitionRequest else { return }

        // Convert CMSampleBuffer to AVAudioPCMBuffer
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        let format = AVAudioFormat(streamDescription: asbd)
        guard let format else { return }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        // Copy audio data
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var lengthOut = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &lengthOut, dataPointerOut: &dataPointer)

        if let dataPointer, let destChannels = pcmBuffer.floatChannelData {
            // If format is float, copy directly
            if asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
                memcpy(destChannels[0], dataPointer, min(lengthOut, Int(pcmBuffer.frameCapacity) * MemoryLayout<Float>.size))
            } else if asbd.pointee.mBitsPerChannel == 16 {
                // Convert Int16 to Float32
                let int16Ptr = UnsafeRawPointer(dataPointer).bindMemory(to: Int16.self, capacity: frameCount)
                for i in 0..<frameCount {
                    destChannels[0][i] = Float(int16Ptr[i]) / Float(Int16.max)
                }
            }
        }

        request.append(pcmBuffer)
        computeRMS(buffer: pcmBuffer)
    }

    // MARK: - Private

    private func startRecognition(locale: String) {
        let loc = Locale(identifier: locale)
        let recogniser = SFSpeechRecognizer(locale: loc)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recogniser, recogniser.isAvailable else {
            print("⚠️ AppleSpeechProvider: unavailable for \(locale)")
            return
        }
        speechRecognizer = recogniser

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        recognitionRequest = request

        if useExternalAudioFeed {
            // External mode: don't create AVAudioEngine, wait for feedAudioBuffer() calls
            print("🎤 AppleSpeechProvider: listening via external feed (\(locale))")
        } else {
            // Self-managed mode: create our own audio engine
            let engine = AVAudioEngine()
            audioEngine = engine

            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, weak request] buffer, _ in
                request?.append(buffer)
                self?.computeRMS(buffer: buffer)
            }

            do {
                try engine.start()
                print("🎤 AppleSpeechProvider: listening via internal mic (\(locale))")
            } catch {
                print("⚠️ AppleSpeechProvider: audio engine failed: \(error)")
                return
            }
        }

        recognitionTask = recogniser.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let segments = result.bestTranscription.segments
                let words: [RecognizedWord] = segments.map { segment in
                    RecognizedWord(
                        text: segment.substring,
                        timestamp: segment.timestamp,
                        duration: segment.duration,
                        confidence: segment.confidence
                    )
                }
                DispatchQueue.main.async {
                    self.onWords?(words)
                }
            }
            if error != nil {
                DispatchQueue.main.async {
                    self.restartRecognition(locale: locale)
                }
            }
        }

        isListening = true
    }

    private func restartRecognition(locale: String) {
        guard isListening else { return }
        stopInternal()
        startRecognition(locale: locale)
    }

    private func stopInternal() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        if !useExternalAudioFeed {
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine?.stop()
        }
        recognitionRequest = nil
        recognitionTask = nil
        audioEngine = nil
    }

    private func computeRMS(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        var sum: Float = 0
        let data = channelData[0]
        for i in 0..<frameLength {
            let sample = data[i]
            sum += sample * sample
        }
        let rms = sqrtf(sum / Float(frameLength))

        DispatchQueue.main.async { [weak self] in
            self?.currentRMS = rms
        }
    }
}
