import Foundation
import Combine

// MARK: - Voice Follow Engine

/// Manages the speech recognition provider lifecycle and forwards
/// recognised words to the SlideVoiceTracker.
///
/// Responsibilities:
/// 1. Creating and managing the SpeechProvider (Apple Speech / WhisperKit)
/// 2. Forwarding recognised words to the SlideVoiceTracker via `onRecognizedWords`
/// 3. Providing the speech provider reference for external audio feed (screen recording)
///
/// The actual alignment/tracking logic lives in SlideVoiceTracker.
@MainActor
class VoiceFollowEngine: ObservableObject {

    /// Whether the speech provider is listening
    @Published var isListening: Bool = false

    // MARK: - Configuration

    /// How many recent spoken words to use for LCS matching
    var phraseWindowSize: Int = 12

    /// Locale for speech recognition
    var speechLocale: String = "en-US"

    /// Which speech backend to use
    var speechBackend: SpeechBackend = .apple

    // MARK: - Speech Provider

    /// Exposed so RecordingCoordinator can feed mic samples during screen recording
    private(set) var speechProvider: SpeechProvider?

    /// When true, the speech provider uses external audio (from ScreenCaptureKit mic)
    /// instead of creating its own AVAudioEngine tap.
    var useExternalAudioFeed: Bool = false

    // MARK: - Callbacks

    /// Called when new recognised words arrive — the SlideVoiceTracker subscribes to this.
    var onRecognizedWords: (([RecognizedWord]) -> Void)?

    // MARK: - Lifecycle

    func start() {
        let provider: SpeechProvider = AppleSpeechProvider()

        provider.useExternalAudioFeed = useExternalAudioFeed

        // Forward recognised words to SlideVoiceTracker via callback
        provider.onWords = { [weak self] words in
            Task { @MainActor [weak self] in
                self?.onRecognizedWords?(words)
            }
        }

        speechProvider = provider
        provider.start(locale: speechLocale)

        isListening = true
        print("🎤 VoiceFollowEngine: started (backend: \(speechBackend), locale: \(speechLocale))")
    }

    func stop() {
        speechProvider?.stop()
        speechProvider = nil
        isListening = false
    }
}
