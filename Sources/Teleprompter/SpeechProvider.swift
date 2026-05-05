import Foundation
import CoreMedia

// MARK: - Speech Provider Protocol

/// Abstraction over speech recognition backends (Apple Speech, WhisperKit, etc.)
/// so the VoiceFollowEngine doesn't depend on a specific implementation.
protocol SpeechProvider: AnyObject {
    /// Called with the cumulative list of recognised words from the current session.
    /// Each call replaces the previous list (not incremental).
    var onWords: (([String]) -> Void)? { get set }

    /// Whether the provider is currently listening.
    var isListening: Bool { get }

    /// When true, the provider uses an external audio source instead of its own mic tap.
    var useExternalAudioFeed: Bool { get set }

    /// Start listening with the given locale identifier (e.g. "en-US", "en-PH").
    func start(locale: String)

    /// Stop listening and release audio resources.
    func stop()

    /// Feed an external audio buffer (for screen recording mic sharing).
    func feedAudioBuffer(_ sampleBuffer: CMSampleBuffer)
}

/// Which speech recognition backend to use.
enum SpeechBackend: String, Codable, CaseIterable, Identifiable {
    case apple      // SFSpeechRecognizer (lower latency, partial results ~200ms)
    case whisperKit // WhisperKit (better accuracy, ~1-2s chunk latency)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple:      return "Apple Speech"
        case .whisperKit: return "WhisperKit"
        }
    }
}
