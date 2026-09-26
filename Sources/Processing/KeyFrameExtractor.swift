import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Extracts key frames from a recorded video at specified timestamps.
/// Frames are saved as JPEGs in a subdirectory alongside the video.
class KeyFrameExtractor {

    /// Strategy for selecting which timestamps to extract frames at
    enum ExtractionStrategy {
        /// One frame per aggregated action (at its best moment) plus the final frame.
        case atActions([AggregatedAction])
        /// Extract at fixed intervals (e.g. every 2 seconds)
        case atInterval(TimeInterval)
        /// Extract at specific timestamps
        case atTimestamps([TimeInterval])
    }

    struct ExtractedFrame {
        let timestamp: TimeInterval
        let imageURL: URL
        let trigger: String   // What caused this frame to be extracted
        let actionIndex: Int? // 1-based sequence number of the aggregated action, if any
    }

    /// Hard cap on frames per recording. Actions beyond this are sampled evenly.
    let maxFrames: Int
    /// Longest edge of saved frames, in pixels.
    let maxDimension: CGFloat
    /// JPEG quality (0...1).
    let jpegQuality: CGFloat

    init(maxFrames: Int = 60, maxDimension: CGFloat = 1920, jpegQuality: CGFloat = 0.82) {
        self.maxFrames = maxFrames
        self.maxDimension = maxDimension
        self.jpegQuality = jpegQuality
    }

    // MARK: - Extract Frames

    func extractFrames(
        from videoURL: URL,
        strategy: ExtractionStrategy,
        outputDirectory: URL
    ) async throws -> [ExtractedFrame] {
        let asset = AVURLAsset(url: videoURL)
        let totalSeconds = try await asset.load(.duration).seconds

        let requests = buildTimestampRequests(strategy: strategy, totalDuration: totalSeconds)
        guard !requests.isEmpty else {
            print("⚠️ No timestamps to extract frames at")
            return []
        }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)

        print("📸 Extracting \(requests.count) key frames...")
        var extracted: [ExtractedFrame] = []

        for (index, request) in requests.enumerated() {
            let time = CMTime(seconds: request.timestamp, preferredTimescale: 600)
            do {
                let (cgImage, actualTime) = try await generator.image(at: time)
                let seconds = actualTime.seconds
                let filename = String(format: "frame_%03d_%.1fs.jpg", index, seconds)
                let fileURL = outputDirectory.appendingPathComponent(filename)
                try Self.writeJPEG(cgImage, to: fileURL, quality: jpegQuality)
                extracted.append(ExtractedFrame(
                    timestamp: seconds,
                    imageURL: fileURL,
                    trigger: request.trigger,
                    actionIndex: request.actionIndex
                ))
            } catch {
                print("  ⚠️ Failed to extract frame at \(String(format: "%.2f", request.timestamp))s: \(error.localizedDescription)")
            }
        }

        print("📸 Extraction complete: \(extracted.count) frames saved to \(outputDirectory.lastPathComponent)/")
        return extracted
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: CGFloat) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    // MARK: - Build Timestamp Requests

    private struct TimestampRequest {
        let timestamp: TimeInterval
        let trigger: String
        let actionIndex: Int?
    }

    private func buildTimestampRequests(strategy: ExtractionStrategy, totalDuration: TimeInterval) -> [TimestampRequest] {
        let lastFrameTime = max(0, totalDuration - 0.1)
        var requests: [TimestampRequest]

        switch strategy {
        case .atActions(let actions):
            requests = actions.map { action in
                TimestampRequest(
                    timestamp: min(max(0, action.bestFrameTimestamp), lastFrameTime),
                    trigger: action.description,
                    actionIndex: action.sequenceNumber
                )
            }
            requests = Self.evenlySample(requests, count: maxFrames - 1)
            // The final frame shows the end result of the workflow.
            if totalDuration > 0, (requests.last?.timestamp ?? -1) < lastFrameTime - 0.5 {
                requests.append(TimestampRequest(timestamp: lastFrameTime, trigger: "end", actionIndex: nil))
            }

        case .atInterval(let interval):
            requests = stride(from: 0.0, to: totalDuration, by: max(0.5, interval)).map {
                TimestampRequest(timestamp: $0, trigger: "interval", actionIndex: nil)
            }
            requests = Self.evenlySample(requests, count: maxFrames - 1)
            if let last = requests.last, last.timestamp < lastFrameTime - 0.5 {
                requests.append(TimestampRequest(timestamp: lastFrameTime, trigger: "end", actionIndex: nil))
            }

        case .atTimestamps(let timestamps):
            requests = Self.evenlySample(
                timestamps.sorted().map { TimestampRequest(timestamp: $0, trigger: "manual", actionIndex: nil) },
                count: maxFrames
            )
        }

        return requests.sorted { $0.timestamp < $1.timestamp }
    }

    /// Keep at most `count` items, spread evenly and always including the first and last.
    static func evenlySample<T>(_ items: [T], count: Int) -> [T] {
        guard count > 0 else { return [] }
        guard items.count > count else { return items }
        if count == 1 { return [items[0]] }
        let step = Double(items.count - 1) / Double(count - 1)
        return (0..<count).map { items[Int((Double($0) * step).rounded())] }
    }
}
