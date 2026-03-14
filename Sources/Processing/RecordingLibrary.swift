import Foundation
import AVFoundation
import AppKit

// MARK: - Library Entry

/// Represents a single recording in the library — the video file plus any associated artifacts.
struct LibraryEntry: Identifiable {
    let id: String          // sessionId or video filename as fallback
    let videoURL: URL
    let sessionURL: URL?
    let workflowURL: URL?
    let framesDirectory: URL?
    let recordingDate: Date
    let duration: TimeInterval
    let title: String       // Workflow title or video filename
    let status: Status
    let eventCount: Int
    let stepCount: Int

    enum Status: String {
        case processed = "Steps Generated"
        case unprocessed = "Unprocessed"
        case processing = "Processing"
        case failed = "Failed"

        var icon: String {
            switch self {
            case .processed: return "checkmark.circle.fill"
            case .unprocessed: return "circle.dashed"
            case .processing: return "arrow.triangle.2.circlepath"
            case .failed: return "xmark.circle"
            }
        }

        var color: String {
            switch self {
            case .processed: return "green"
            case .unprocessed: return "secondary"
            case .processing: return "blue"
            case .failed: return "red"
            }
        }
    }
}

// MARK: - Recording Library

/// Scans the recordings directory and builds a library of all past recordings.
/// Pairs video files with their `_session.json` and `_workflow.json` sidecars.
@MainActor
class RecordingLibrary: ObservableObject {
    @Published var entries: [LibraryEntry] = []
    @Published var isScanning = false

    /// Thumbnail cache: video filename → NSImage
    private var thumbnailCache: [String: NSImage] = [:]
    private let fileManager = FileManager.default

    // MARK: - Scan

    /// Scan a directory for recordings and build the library entries.
    func scan(directory: URL) async {
        isScanning = true

        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else {
            isScanning = false
            return
        }

        let videoExtensions = Set(["mov", "mp4"])
        let videoFiles = contents.filter { videoExtensions.contains($0.pathExtension.lowercased()) }

        var newEntries: [LibraryEntry] = []

        for videoURL in videoFiles {
            let baseName = videoURL.deletingPathExtension().lastPathComponent
            let dir = videoURL.deletingLastPathComponent()

            // Look for sidecar files
            let sessionURL = dir.appendingPathComponent("\(baseName)_session.json")
            let workflowURL = dir.appendingPathComponent("\(baseName)_workflow.json")
            let framesDir = dir.appendingPathComponent("\(baseName)_frames")

            let hasSession = fileManager.fileExists(atPath: sessionURL.path)
            let hasWorkflow = fileManager.fileExists(atPath: workflowURL.path)
            let hasFrames = fileManager.fileExists(atPath: framesDir.path)

            // Load session metadata if available
            var sessionId = baseName
            var recordingDate = (try? videoURL.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            var duration: TimeInterval = 0
            var eventCount = 0
            var processingState: RecordingSession.ProcessingState?

            if hasSession {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let data = try? Data(contentsOf: sessionURL),
                   let session = try? decoder.decode(RecordingSession.self, from: data) {
                    sessionId = session.sessionId
                    recordingDate = session.recordingDate
                    duration = session.duration
                    eventCount = session.eventSummary.totalEvents
                    processingState = session.processingState
                }
            }

            // Load workflow metadata if available
            var title = baseName
                .replacingOccurrences(of: "Recording_", with: "")
                .replacingOccurrences(of: "_", with: " ")
            var stepCount = 0

            if hasWorkflow {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let data = try? Data(contentsOf: workflowURL),
                   let workflow = try? decoder.decode(GeneratedWorkflow.self, from: data) {
                    title = workflow.title
                    stepCount = workflow.steps.count
                }
            }

            // Determine status
            let status: LibraryEntry.Status
            if hasWorkflow && stepCount > 0 {
                status = .processed
            } else if let state = processingState {
                switch state {
                case .processing: status = .processing
                case .failed: status = .failed
                default: status = .unprocessed
                }
            } else {
                status = .unprocessed
            }

            // If no session exists but video does, estimate duration from video
            if duration == 0 {
                let asset = AVURLAsset(url: videoURL)
                if let durationValue = try? await asset.load(.duration) {
                    duration = CMTimeGetSeconds(durationValue)
                }
            }

            newEntries.append(LibraryEntry(
                id: sessionId,
                videoURL: videoURL,
                sessionURL: hasSession ? sessionURL : nil,
                workflowURL: hasWorkflow ? workflowURL : nil,
                framesDirectory: hasFrames ? framesDir : nil,
                recordingDate: recordingDate,
                duration: duration,
                title: title,
                status: status,
                eventCount: eventCount,
                stepCount: stepCount
            ))
        }

        entries = newEntries.sorted { $0.recordingDate > $1.recordingDate }
        isScanning = false
    }

    // MARK: - Thumbnails

    /// Get or generate a thumbnail for a recording.
    func thumbnail(for entry: LibraryEntry) -> NSImage? {
        let key = entry.videoURL.lastPathComponent

        if let cached = thumbnailCache[key] {
            return cached
        }

        // Try to load the first extracted frame
        if let framesDir = entry.framesDirectory,
           let frameFiles = try? fileManager.contentsOfDirectory(atPath: framesDir.path),
           let firstFrame = frameFiles.sorted().first {
            let frameURL = framesDir.appendingPathComponent(firstFrame)
            if let image = NSImage(contentsOf: frameURL) {
                thumbnailCache[key] = image
                return image
            }
        }

        // Fall back to AVAssetImageGenerator
        let asset = AVURLAsset(url: entry.videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)

        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            thumbnailCache[key] = image
            return image
        }

        return nil
    }

    // MARK: - Delete

    /// Delete a recording and all its associated files.
    func delete(entry: LibraryEntry) {
        // Remove video
        try? fileManager.removeItem(at: entry.videoURL)

        // Remove session JSON
        if let sessionURL = entry.sessionURL {
            try? fileManager.removeItem(at: sessionURL)
        }

        // Remove workflow JSON
        if let workflowURL = entry.workflowURL {
            try? fileManager.removeItem(at: workflowURL)
        }

        // Remove frames directory
        if let framesDir = entry.framesDirectory {
            try? fileManager.removeItem(at: framesDir)
        }

        // Remove metadata JSON (if it exists separately)
        let baseName = entry.videoURL.deletingPathExtension().lastPathComponent
        let metadataURL = entry.videoURL.deletingLastPathComponent()
            .appendingPathComponent("\(baseName)_metadata.json")
        try? fileManager.removeItem(at: metadataURL)

        // Update entries
        entries.removeAll { $0.id == entry.id }

        print("🗑️ Deleted recording: \(entry.videoURL.lastPathComponent)")
    }
}
