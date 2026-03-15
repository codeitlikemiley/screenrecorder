import Foundation

/// Represents a complete recording session with all associated artifacts.
/// Ties the video file to its interaction metadata, extracted frames, and speech transcript.
/// Saved as a session JSON file that serves as the input for AI step generation (Phase 3).
struct RecordingSession: Codable {

    /// Schema version for forward compatibility
    var version: Int = 1

    /// Unique session identifier
    let sessionId: String

    /// When the recording was made
    let recordingDate: Date

    /// Total recording duration in seconds
    let duration: TimeInterval

    // MARK: - File References

    /// Video file (e.g. "Recording_2026-03-13_19-30-00.mov")
    let videoFile: String

    /// Interaction metadata JSON (e.g. "Recording_2026-03-13_19-30-00_metadata.json")
    let metadataFile: String?

    /// Directory containing extracted key frames (e.g. "Recording_2026-03-13_19-30-00_frames/")
    let framesDirectory: String?

    // MARK: - Processed Data

    /// Extracted key frames with timestamps and triggers
    var frames: [FrameReference]

    /// Speech transcript (nil if no speech detected or transcription failed)
    var transcript: SpeechTranscriber.TranscriptResult?

    /// Aggregated semantic actions (nil if not yet aggregated)
    var aggregatedActions: [AggregatedAction]?

    /// Raw interaction events (for re-aggregation and detailed analysis)
    var rawEvents: [InteractionEvent]?

    /// Interaction events summary
    var eventSummary: EventSummary

    // MARK: - Processing State

    var processingState: ProcessingState

    enum ProcessingState: String, Codable {
        case raw           // Just recorded, no processing done
        case processing    // Currently being processed
        case completed     // All processing complete
        case failed        // Processing failed
    }

    // MARK: - Nested Types

    struct FrameReference: Codable {
        let filename: String
        let timestamp: TimeInterval
        let trigger: String        // What caused this frame to be captured
    }

    struct EventSummary: Codable {
        let totalEvents: Int
        let mouseClicks: Int
        let keystrokes: Int
        let scrolls: Int
        let drags: Int
    }

    // MARK: - Factory

    /// Create a new session from a completed recording
    static func create(
        videoURL: URL,
        metadataURL: URL?,
        duration: TimeInterval,
        events: [InteractionEvent]
    ) -> RecordingSession {
        let baseName = videoURL.deletingPathExtension().lastPathComponent

        // Count event types
        var clicks = 0, keys = 0, scrolls = 0, drags = 0
        for event in events {
            switch event {
            case .mouseClick: clicks += 1
            case .keystroke: keys += 1
            case .mouseScroll: scrolls += 1
            case .mouseDrag: drags += 1
            }
        }

        return RecordingSession(
            sessionId: UUID().uuidString,
            recordingDate: Date(),
            duration: duration,
            videoFile: videoURL.lastPathComponent,
            metadataFile: metadataURL?.lastPathComponent,
            framesDirectory: "\(baseName)_frames",
            frames: [],
            transcript: nil,
            aggregatedActions: nil,
            rawEvents: events.isEmpty ? nil : events,
            eventSummary: EventSummary(
                totalEvents: events.count,
                mouseClicks: clicks,
                keystrokes: keys,
                scrolls: scrolls,
                drags: drags
            ),
            processingState: .raw
        )
    }

    // MARK: - Save / Load

    /// Save session to a JSON file alongside the video
    func save(in directory: URL) throws -> URL {
        let baseName = (videoFile as NSString).deletingPathExtension
        let sessionFile = "\(baseName)_session.json"
        let sessionURL = directory.appendingPathComponent(sessionFile)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(to: sessionURL, options: .atomic)

        print("📦 Session saved: \(sessionFile)")
        return sessionURL
    }

    /// Load a session from a JSON file
    static func load(from url: URL) throws -> RecordingSession {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordingSession.self, from: data)
    }
}
