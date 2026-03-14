import Foundation

/// Accumulates interaction events during a recording session and flushes them to a JSON sidecar file.
/// Thread-safe — events can be logged from any queue (mouse/keyboard event handlers run on various queues).
class InteractionLogger {
    private let queue = DispatchQueue(label: "com.screenrecorder.interactionLogger", qos: .utility)
    private var events: [InteractionEvent] = []
    private var recordingStartDate: Date?

    /// Start a new logging session. Resets all accumulated events.
    func startSession() {
        queue.sync {
            events.removeAll()
            recordingStartDate = Date()
        }
    }

    /// The timestamp offset from recording start (in seconds).
    /// Call this from event handlers to get a consistent relative timestamp.
    var currentTimestamp: TimeInterval {
        queue.sync {
            guard let start = recordingStartDate else { return 0 }
            return Date().timeIntervalSince(start)
        }
    }

    // MARK: - Log Events

    func logMouseClick(position: CGPoint, button: MouseButton, clickCount: Int = 1) {
        let ts = currentTimestamp
        let event = InteractionEvent.mouseClick(
            MouseClickEvent(timestamp: ts, position: position, button: button, clickCount: clickCount)
        )
        append(event)
    }

    func logMouseDrag(startPosition: CGPoint, endPosition: CGPoint, duration: TimeInterval) {
        let ts = currentTimestamp
        let event = InteractionEvent.mouseDrag(
            MouseDragEvent(timestamp: ts, startPosition: startPosition, endPosition: endPosition, duration: duration)
        )
        append(event)
    }

    func logMouseScroll(position: CGPoint, deltaX: CGFloat, deltaY: CGFloat) {
        let ts = currentTimestamp
        let event = InteractionEvent.mouseScroll(
            MouseScrollEvent(timestamp: ts, position: position, deltaX: deltaX, deltaY: deltaY)
        )
        append(event)
    }

    func logKeystroke(key: String, modifiers: [String], isSpecialKey: Bool) {
        let ts = currentTimestamp
        let event = InteractionEvent.keystroke(
            KeystrokeLogEvent(timestamp: ts, key: key, modifiers: modifiers, isSpecialKey: isSpecialKey)
        )
        append(event)
    }

    // MARK: - Event Access

    /// Returns all events accumulated so far (thread-safe copy).
    var allEvents: [InteractionEvent] {
        queue.sync { events }
    }

    /// Number of events logged so far.
    var eventCount: Int {
        queue.sync { events.count }
    }

    // MARK: - Flush to Disk

    /// Write all accumulated events to a JSON file alongside the recording video.
    /// Returns the URL of the written file, or nil if writing failed.
    @discardableResult
    func flush(videoURL: URL) -> URL? {
        let eventsSnapshot = queue.sync { events }

        // Generate sidecar filename: Recording_2026-03-13_19-30-00.mov → Recording_2026-03-13_19-30-00_metadata.json
        let baseName = videoURL.deletingPathExtension().lastPathComponent
        let metadataFilename = "\(baseName)_metadata.json"
        let metadataURL = videoURL.deletingLastPathComponent().appendingPathComponent(metadataFilename)

        let metadata = RecordingMetadata(
            version: 1,
            recordingFile: videoURL.lastPathComponent,
            recordingStartDate: recordingStartDate ?? Date(),
            totalDuration: currentTimestamp,
            eventCount: eventsSnapshot.count,
            events: eventsSnapshot
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(metadata)
            try data.write(to: metadataURL, options: .atomic)
            print("📋 Interaction metadata saved: \(metadataFilename) (\(eventsSnapshot.count) events, \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))")
            return metadataURL
        } catch {
            print("❌ Failed to save interaction metadata: \(error)")
            return nil
        }
    }

    // MARK: - Private

    private func append(_ event: InteractionEvent) {
        queue.sync {
            events.append(event)
        }
    }
}

// MARK: - Recording Metadata (top-level JSON structure)

struct RecordingMetadata: Codable {
    let version: Int
    let recordingFile: String
    let recordingStartDate: Date
    let totalDuration: TimeInterval
    let eventCount: Int
    let events: [InteractionEvent]
}
