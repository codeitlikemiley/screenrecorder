import Foundation

/// Manages file storage, directory creation, and filename generation for recordings.
class StorageManager {
    static let shared = StorageManager()

    private let fileManager = FileManager.default

    /// Ensure the save directory exists
    func ensureSaveDirectory(at url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// Generate a timestamped filename
    func generateFilename(prefix: String = "Recording", format: OutputFormat) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        return "\(prefix)_\(timestamp).\(format.fileExtension)"
    }

    /// Get the full output URL for a new recording
    func outputURL(in directory: URL, format: OutputFormat) throws -> URL {
        try ensureSaveDirectory(at: directory)
        let filename = generateFilename(format: format)
        return directory.appendingPathComponent(filename)
    }

    /// Calculate directory size in bytes
    func directorySize(at url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += Int64(size)
            }
        }
        return totalSize
    }

    /// Format bytes to human-readable string
    func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// List recent recordings
    func recentRecordings(in directory: URL, limit: Int = 10) -> [URL] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return []
        }

        let videoExtensions = ["mov", "mp4"]
        return contents
            .filter { videoExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { url1, url2 in
                let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                return date1 > date2
            }
            .prefix(limit)
            .map { $0 }
    }
}
