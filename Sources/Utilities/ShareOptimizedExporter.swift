import AVFoundation
import Foundation

/// Exports a screen recording to a Facebook/social-platform-compatible format.
///
/// Output spec:
/// - Container: MP4
/// - Video: H.264 (AVC) — avoids Facebook's HEVC→H.264 transcode bug
/// - Audio: Single AAC stereo track at 48kHz — avoids Facebook's multi-track MOV demuxer bug
///
/// Uses AVAssetExportSession which handles the transcode/remux reliably.
struct ShareOptimizedExporter {

    enum ExportError: LocalizedError {
        case invalidAsset
        case exportFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .invalidAsset: return "Invalid video asset"
            case .exportFailed(let msg): return "Export failed: \(msg)"
            case .cancelled: return "Export was cancelled"
            }
        }
    }

    /// Export a recording to a share-optimized MP4.
    /// - Parameters:
    ///   - sourceURL: Original recording file (MOV or MP4)
    ///   - outputURL: Destination MP4 file URL
    /// - Returns: The output URL on success
    static func export(sourceURL: URL, outputURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)

        // Verify asset is loadable
        let isPlayable = try? await asset.load(.isPlayable)
        guard isPlayable == true else {
            throw ExportError.invalidAsset
        }

        // Remove existing file
        try? FileManager.default.removeItem(at: outputURL)

        // Create export session
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.invalidAsset
        }

        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        // Audio mix: if multiple audio tracks exist, balance them so both are audible
        // in the final single-track output. AVAssetExportSession flattens multiple
        // tracks into a single stereo mix when an audioMix is applied.
        if let audioMix = createAudioMix(for: asset) {
            session.audioMix = audioMix
        }

        // Run export
        await session.export()

        switch session.status {
        case .completed:
            let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
            let fileSize = attrs?[.size] as? Int ?? 0
            print("  ✅ Share-optimized export complete: \(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file))")
            return outputURL
        case .failed:
            let errorMsg = session.error?.localizedDescription ?? "unknown"
            throw ExportError.exportFailed(errorMsg)
        case .cancelled:
            throw ExportError.cancelled
        default:
            throw ExportError.exportFailed("Unexpected status: \(session.status.rawValue)")
        }
    }

    /// Generate a share-optimized output URL alongside the original.
    /// e.g. Recording_2024-01-15_10-30-00.mov → Recording_2024-01-15_10-30-00_share.mp4
    static func shareOutputURL(for originalURL: URL) -> URL {
        let baseName = originalURL.deletingPathExtension().lastPathComponent
        let dir = originalURL.deletingLastPathComponent()
        return dir.appendingPathComponent("\(baseName)_share.mp4")
    }

    // MARK: - Private

    /// Creates an audio mix that ensures all audio tracks are audible in the exported mix.
    /// This also encourages the exporter to produce a single mixed audio track instead of
    /// preserving separate tracks.
    private static func createAudioMix(for asset: AVAsset) -> AVMutableAudioMix? {
        guard let audioTracks = try? asset.loadTracks(withMediaType: .audio),
              audioTracks.count > 1 else {
            // Single track — no mix needed
            return nil
        }

        var inputParameters: [AVMutableAudioMixInputParameters] = []

        for (index, track) in audioTracks.enumerated() {
            let params = AVMutableAudioMixInputParameters(track: track)
            // Track 0 = system audio (stereo), Track 1 = mic audio (mono)
            // Boost mic slightly so it doesn't get drowned out by system audio
            let volume: Float = (index == 0) ? 1.0 : 1.2
            params.setVolume(volume, at: .zero)
            params.setVolumeRamp(fromStartVolume: volume, toEndVolume: volume, timeRange: CMTimeRange(start: .zero, duration: CMTime.positiveInfinity))
            inputParameters.append(params)
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = inputParameters
        return mix
    }
}
