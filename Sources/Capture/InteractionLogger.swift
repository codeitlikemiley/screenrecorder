import Foundation
import CoreMedia

/// Accumulates interaction events during a recording session and flushes them to a JSON sidecar file.
/// Thread-safe — events can be logged from any queue (mouse/keyboard event handlers run on various queues).
///
/// Timestamps are seconds on the **video timeline**: the logger runs on the host clock (the same
/// clock ScreenCaptureKit stamps frames with), excludes paused time, and is re-based onto the first
/// video frame when flushed. Positions are stored in global top-left points (see `CaptureGeometry`).
class InteractionLogger {
    private let queue = DispatchQueue(label: "com.screenrecorder.interactionLogger", qos: .utility)
    private var events: [InteractionEvent] = []
    private var recordingStartDate: Date?
    private var hostStart: Double?
    private var pausedAt: Double?
    private var pausedTotal: Double = 0
    private var geometry: CaptureGeometry?

    /// Current host-clock time in seconds (same timebase as ScreenCaptureKit sample buffers).
    static func hostNow() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    /// Start a new logging session. Resets all accumulated events.
    func startSession(geometry: CaptureGeometry?) {
        queue.sync {
            events.removeAll()
            recordingStartDate = Date()
            hostStart = Self.hostNow()
            pausedAt = nil
            pausedTotal = 0
            self.geometry = geometry
        }
    }

    /// Stop timestamping; events logged while paused are dropped.
    func pause() {
        queue.sync {
            if pausedAt == nil { pausedAt = Self.hostNow() }
        }
    }

    func resume() {
        queue.sync {
            if let pausedAt {
                pausedTotal += Self.hostNow() - pausedAt
                self.pausedAt = nil
            }
        }
    }

    /// Seconds since recording start, excluding paused time. Nil while paused or before start.
    private func timestampLocked() -> TimeInterval? {
        guard let hostStart, pausedAt == nil else { return nil }
        return Self.hostNow() - hostStart - pausedTotal
    }

    var currentTimestamp: TimeInterval {
        queue.sync { timestampLocked() ?? 0 }
    }

    // MARK: - Log Events

    /// Positions are `NSEvent.mouseLocation` values (Cocoa, bottom-left origin); they are
    /// converted to global top-left points here.
    func logMouseClick(position: CGPoint, button: MouseButton, clickCount: Int = 1) {
        let pos = CaptureGeometry.globalTopLeft(fromCocoa: position)
        append { .mouseClick(MouseClickEvent(timestamp: $0, position: pos, button: button, clickCount: clickCount)) }
    }

    func logMouseDrag(startPosition: CGPoint, endPosition: CGPoint, duration: TimeInterval) {
        let start = CaptureGeometry.globalTopLeft(fromCocoa: startPosition)
        let end = CaptureGeometry.globalTopLeft(fromCocoa: endPosition)
        // The drag is reported when it ends; stamp it with its start time.
        append { .mouseDrag(MouseDragEvent(timestamp: max(0, $0 - duration), startPosition: start, endPosition: end, duration: duration)) }
    }

    func logMouseScroll(position: CGPoint, deltaX: CGFloat, deltaY: CGFloat) {
        let pos = CaptureGeometry.globalTopLeft(fromCocoa: position)
        append { .mouseScroll(MouseScrollEvent(timestamp: $0, position: pos, deltaX: deltaX, deltaY: deltaY)) }
    }

    func logKeystroke(key: String, modifiers: [String], isSpecialKey: Bool) {
        append { .keystroke(KeystrokeLogEvent(timestamp: $0, key: key, modifiers: modifiers, isSpecialKey: isSpecialKey)) }
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
    /// - Parameter videoStartHostTime: host-clock time of the first video frame. Event timestamps are
    ///   shifted so that 0 is that frame (the logger starts a little after capture does).
    /// Returns the URL of the written file, or nil if writing failed.
    @discardableResult
    func flush(videoURL: URL, videoStartHostTime: Double?) -> URL? {
        let (snapshot, start, duration, geometry, hostStart) = queue.sync {
            (events, recordingStartDate, timestampLocked() ?? 0, self.geometry, self.hostStart)
        }

        // Offset between the logger clock and the video clock. Guard against nonsense values
        // (e.g. a missing first frame) — a few seconds at most is expected.
        var offset: Double = 0
        if let videoStartHostTime, let hostStart {
            let candidate = videoStartHostTime - hostStart
            if abs(candidate) < 10 { offset = candidate }
        }
        let rebased = offset == 0 ? snapshot : snapshot.map { $0.shifted(by: -offset) }

        // Generate sidecar filename: Recording_2026-03-13_19-30-00.mov → Recording_2026-03-13_19-30-00_metadata.json
        let baseName = videoURL.deletingPathExtension().lastPathComponent
        let metadataFilename = "\(baseName)_metadata.json"
        let metadataURL = videoURL.deletingLastPathComponent().appendingPathComponent(metadataFilename)

        let metadata = RecordingMetadata(
            version: RecordingMetadata.currentVersion,
            recordingFile: videoURL.lastPathComponent,
            recordingStartDate: start ?? Date(),
            totalDuration: max(0, duration - offset),
            eventCount: rebased.count,
            events: rebased,
            coordinateSpace: RecordingMetadata.globalTopLeftPoints,
            captureGeometry: geometry
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(metadata)
            try data.write(to: metadataURL, options: .atomic)
            print("📋 Interaction metadata saved: \(metadataFilename) (\(rebased.count) events, clock offset \(String(format: "%.3f", offset))s, \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))")
            return metadataURL
        } catch {
            print("❌ Failed to save interaction metadata: \(error)")
            return nil
        }
    }

    // MARK: - Private

    private func append(_ make: (TimeInterval) -> InteractionEvent) {
        queue.sync {
            guard let ts = timestampLocked() else { return } // not started, or paused
            events.append(make(ts))
        }
    }
}

// MARK: - Recording Metadata (top-level JSON structure)

struct RecordingMetadata: Codable {
    /// v1: Cocoa (bottom-left) positions, logger-clock timestamps, no geometry.
    /// v2: global top-left positions, video-clock timestamps, capture geometry.
    static let currentVersion = 2
    static let globalTopLeftPoints = "global_top_left_points"

    let version: Int
    let recordingFile: String
    let recordingStartDate: Date
    let totalDuration: TimeInterval
    let eventCount: Int
    let events: [InteractionEvent]
    var coordinateSpace: String?
    var captureGeometry: CaptureGeometry?

    /// Load a metadata file, upgrading v1 files to v2 semantics (flip positions, assume primary display).
    static func load(from url: URL) throws -> RecordingMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var metadata = try decoder.decode(RecordingMetadata.self, from: Data(contentsOf: url))
        if metadata.coordinateSpace != globalTopLeftPoints {
            metadata = RecordingMetadata(
                version: currentVersion,
                recordingFile: metadata.recordingFile,
                recordingStartDate: metadata.recordingStartDate,
                totalDuration: metadata.totalDuration,
                eventCount: metadata.eventCount,
                events: metadata.events.map { $0.mappingPositions(CaptureGeometry.globalTopLeft(fromCocoa:)) },
                coordinateSpace: globalTopLeftPoints,
                captureGeometry: metadata.captureGeometry ?? .legacyPrimaryDisplay()
            )
        }
        return metadata
    }
}
