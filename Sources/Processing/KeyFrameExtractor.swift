import AVFoundation
import CoreImage
import AppKit

/// Extracts key frames from a recorded video at specified timestamps.
/// Uses AVAssetImageGenerator for efficient frame-accurate extraction.
/// Extracted frames are saved as PNG files in a subdirectory alongside the video.
class KeyFrameExtractor {

    /// Strategy for selecting which timestamps to extract frames at
    enum ExtractionStrategy {
        /// Extract at every interaction event timestamp
        case atInteractions([InteractionEvent])
        /// Extract at fixed intervals (e.g. every 2 seconds)
        case atInterval(TimeInterval)
        /// Extract at specific timestamps
        case atTimestamps([TimeInterval])
    }

    struct ExtractedFrame {
        let timestamp: TimeInterval
        let imageURL: URL
        let trigger: String  // What caused this frame to be extracted (e.g. "mouseClick", "keystroke")
    }

    // MARK: - Extract Frames

    /// Extract key frames from a video file and save them as PNGs.
    /// Returns the list of extracted frames with their file URLs.
    func extractFrames(
        from videoURL: URL,
        strategy: ExtractionStrategy,
        outputDirectory: URL
    ) async throws -> [ExtractedFrame] {
        let asset = AVURLAsset(url: videoURL)

        // Get video duration
        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)

        // Determine timestamps based on strategy
        let requests = buildTimestampRequests(strategy: strategy, totalDuration: totalSeconds)

        guard !requests.isEmpty else {
            print("⚠️ No timestamps to extract frames at")
            return []
        }

        // Create output directory
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // Configure image generator
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)

        // Use a reasonable max size to avoid huge PNGs
        generator.maximumSize = CGSize(width: 1920, height: 1920)

        print("📸 Extracting \(requests.count) key frames...")

        var extractedFrames: [ExtractedFrame] = []

        for (index, request) in requests.enumerated() {
            let cmTime = CMTime(seconds: request.timestamp, preferredTimescale: 600)

            do {
                let (cgImage, actualTime) = try await generator.image(at: cmTime)
                let actualSeconds = CMTimeGetSeconds(actualTime)

                // Save as PNG
                let filename = String(format: "frame_%03d_%.1fs.png", index, actualSeconds)
                let fileURL = outputDirectory.appendingPathComponent(filename)

                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                if let tiffData = nsImage.tiffRepresentation,
                   let bitmapRep = NSBitmapImageRep(data: tiffData),
                   let pngData = bitmapRep.representation(using: .png, properties: [:]) {
                    try pngData.write(to: fileURL)
                }

                let frame = ExtractedFrame(
                    timestamp: actualSeconds,
                    imageURL: fileURL,
                    trigger: request.trigger
                )
                extractedFrames.append(frame)

                if (index + 1) % 10 == 0 || index == requests.count - 1 {
                    print("  📸 Extracted \(index + 1)/\(requests.count) frames")
                }
            } catch {
                print("  ⚠️ Failed to extract frame at \(request.timestamp)s: \(error.localizedDescription)")
                continue
            }
        }

        print("📸 Extraction complete: \(extractedFrames.count) frames saved to \(outputDirectory.lastPathComponent)/")
        return extractedFrames
    }

    // MARK: - Build Timestamp Requests

    private struct TimestampRequest {
        let timestamp: TimeInterval
        let trigger: String
    }

    private func buildTimestampRequests(strategy: ExtractionStrategy, totalDuration: TimeInterval) -> [TimestampRequest] {
        var requests: [TimestampRequest] = []

        switch strategy {
        case .atInteractions(let events):
            // For each interaction event, extract frames slightly before and after
            var timestamps = Set<Double>()  // Deduplicate close timestamps

            for event in events {
                let ts = event.timestamp

                // Frame just before the interaction (context)
                let before = max(0, ts - 0.3)
                // Frame at the interaction
                let at = ts
                // Frame after the interaction (result)
                let after = min(totalDuration, ts + 0.5)

                // Only add if not too close to an existing timestamp (within 0.2s)
                for candidate in [before, at, after] {
                    let rounded = (candidate * 5).rounded() / 5  // Round to 0.2s
                    if !timestamps.contains(rounded) {
                        timestamps.insert(rounded)
                        requests.append(TimestampRequest(
                            timestamp: candidate,
                            trigger: event.summary
                        ))
                    }
                }
            }

            // Sort by timestamp
            requests.sort { $0.timestamp < $1.timestamp }

            // Cap at a reasonable limit to avoid extracting hundreds of frames
            if requests.count > 100 {
                // Subsample: keep every Nth frame
                let step = requests.count / 100
                requests = stride(from: 0, to: requests.count, by: step).map { requests[$0] }
            }

        case .atInterval(let interval):
            var t: TimeInterval = 0
            while t < totalDuration {
                requests.append(TimestampRequest(timestamp: t, trigger: "interval"))
                t += interval
            }
            // Always include the last frame
            if let last = requests.last, last.timestamp < totalDuration - 0.5 {
                requests.append(TimestampRequest(timestamp: totalDuration - 0.1, trigger: "end"))
            }

        case .atTimestamps(let timestamps):
            requests = timestamps.map { TimestampRequest(timestamp: $0, trigger: "manual") }
        }

        return requests
    }
}
