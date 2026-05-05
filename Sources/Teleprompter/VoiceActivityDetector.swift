import Foundation
import AVFoundation
import Combine

// MARK: - Voice Activity Detector

/// Lightweight voice activity detection using AVAudioEngine.
/// Monitors the default microphone input and publishes whether the user is speaking.
///
/// Uses RMS power level analysis — no speech recognition, no ML, no network calls.
/// Works independently of the ScreenCaptureKit recording pipeline.
@MainActor
class VoiceActivityDetector: ObservableObject {

    /// Whether the user is currently speaking (above sensitivity threshold)
    @Published var isSpeaking = false

    /// Current audio level (0.0...1.0) for UI meter display
    @Published var audioLevel: Float = 0

    /// Whether the detector is actively monitoring
    @Published var isMonitoring = false

    // MARK: Private

    private var audioEngine: AVAudioEngine?
    private var sensitivity: Float = 0.3
    private var pauseDelay: TimeInterval = 1.5
    private var silenceWorkItem: DispatchWorkItem?

    /// Tracks whether we're in a "speaking" state internally
    private var speakingState = false

    // MARK: Lifecycle

    deinit {
        // audioEngine is stopped in stop() which should be called before deinit
    }

    // MARK: Public API

    /// Start monitoring the default microphone for voice activity.
    ///
    /// - Parameters:
    ///   - sensitivity: Threshold (0.0...1.0). Lower = more sensitive.
    ///                  0.1 picks up whispers, 0.5 requires normal speech volume.
    ///   - pauseDelay: Seconds of silence before `isSpeaking` goes false.
    func start(sensitivity: CGFloat, pauseDelay: TimeInterval) {
        stop() // Clean up any existing session

        self.sensitivity = Float(sensitivity)
        self.pauseDelay = pauseDelay

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Get the hardware format
        let hwFormat = inputNode.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            print("🎙️ VoiceActivityDetector: No microphone available")
            return
        }

        // Install tap on the input node
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            let level = Self.calculateRMSLevel(buffer: buffer)
            Task { @MainActor [weak self] in
                self?.processAudioLevel(level)
            }
        }

        do {
            try engine.start()
            audioEngine = engine
            isMonitoring = true
            print("🎙️ VoiceActivityDetector: Started (sensitivity: \(self.sensitivity), pauseDelay: \(pauseDelay)s)")
        } catch {
            print("🎙️ VoiceActivityDetector: Failed to start — \(error.localizedDescription)")
        }
    }

    /// Stop monitoring.
    func stop() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        silenceWorkItem?.cancel()
        silenceWorkItem = nil
        isSpeaking = false
        audioLevel = 0
        isMonitoring = false
        speakingState = false
    }

    /// Update sensitivity without restarting the engine.
    func updateSensitivity(_ newValue: CGFloat) {
        sensitivity = Float(newValue)
    }

    /// Update pause delay without restarting the engine.
    func updatePauseDelay(_ newValue: TimeInterval) {
        pauseDelay = newValue
    }

    // MARK: - Audio Processing

    private func processAudioLevel(_ level: Float) {
        audioLevel = level

        if level > sensitivity {
            // Sound detected above threshold
            silenceWorkItem?.cancel()
            silenceWorkItem = nil

            if !speakingState {
                speakingState = true
                isSpeaking = true
            }
        } else {
            // Below threshold — start silence timer if currently speaking
            if speakingState && silenceWorkItem == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.speakingState = false
                    self.isSpeaking = false
                    self.silenceWorkItem = nil
                }
                silenceWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + pauseDelay, execute: work)
            }
        }
    }

    // MARK: - RMS Calculation

    /// Calculate the RMS (root mean square) power level of an audio buffer.
    /// Returns a normalized value between 0.0 and 1.0.
    private static func calculateRMSLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }

        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        var totalRMS: Float = 0

        for channel in 0..<channelCount {
            let data = channelData[channel]
            var sumOfSquares: Float = 0

            for frame in 0..<frameLength {
                let sample = data[frame]
                sumOfSquares += sample * sample
            }

            totalRMS += sqrt(sumOfSquares / Float(frameLength))
        }

        let averageRMS = totalRMS / Float(channelCount)

        // Normalize: typical speech RMS is 0.01–0.1, clamp to 0...1
        // Using a log scale would be more perceptually accurate, but linear
        // works well enough for threshold comparison
        return min(1.0, averageRMS * 5.0)
    }
}
