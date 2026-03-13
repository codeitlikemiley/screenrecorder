import SwiftUI
import Combine
import ScreenCaptureKit

/// Central observable state object for the entire app.
/// All UI components and managers reference this to stay in sync.
@MainActor
class AppState: ObservableObject {
    // MARK: - Recording State
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var isCountingDown = false
    @Published var countdownValue = 3

    // MARK: - Feature Toggles
    @Published var isCameraEnabled = true
    @Published var isKeystrokeOverlayEnabled = false
    @Published var isControlBarVisible = true
    @Published var isMicrophoneEnabled = true

    // MARK: - Camera
    @Published var cameraPosition: CGPoint = .zero // 0,0 means "default" (bottom-right)
    @Published var cameraSize: CGFloat = 200

    // MARK: - Keystrokes
    @Published var activeKeystrokes: [KeystrokeEvent] = []

    // MARK: - Output Settings
    @Published var outputFormat: OutputFormat = .movHEVC
    @Published var saveDirectory: URL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        .appendingPathComponent("ScreenRecorder", isDirectory: true)
    @Published var frameRate: Int = 30

    // MARK: - Permissions
    @Published var hasScreenPermission = false
    @Published var hasCameraPermission = false
    @Published var hasMicrophonePermission = false
    @Published var hasAccessibilityPermission = false

    // MARK: - Current Recording
    @Published var currentRecordingURL: URL?

    // MARK: - Timer
    private var recordingTimer: Timer?

    init() {
        // Ensure save directory exists
        try? FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Recording Timer (wall-clock based — never pauses)

    private var recordingStartDate: Date?

    func startRecordingTimer() {
        recordingDuration = 0
        recordingStartDate = Date()

        // Use DispatchSourceTimer on common RunLoop modes so it doesn't
        // pause when the menu bar is open
        recordingTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let start = self.recordingStartDate else { return }
                self.recordingDuration = floor(Date().timeIntervalSince(start))
            }
        }
        // Add to .common mode so it fires even when tracking menus
        RunLoop.main.add(recordingTimer!, forMode: .common)
    }

    func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartDate = nil
    }

    func pauseRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    func resumeRecordingTimer() {
        recordingTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let start = self.recordingStartDate else { return }
                self.recordingDuration = floor(Date().timeIntervalSince(start))
            }
        }
        RunLoop.main.add(recordingTimer!, forMode: .common)
    }

    // MARK: - Formatted Duration

    var formattedDuration: String {
        let hours = Int(recordingDuration) / 3600
        let minutes = (Int(recordingDuration) % 3600) / 60
        let seconds = Int(recordingDuration) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Generate Output URL

    func generateOutputURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let filename = "Recording_\(timestamp).\(outputFormat.fileExtension)"
        return saveDirectory.appendingPathComponent(filename)
    }

    // MARK: - Add Keystroke

    func addKeystroke(_ event: KeystrokeEvent) {
        activeKeystrokes.append(event)
        // Auto-remove after 2 seconds
        let eventId = event.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.activeKeystrokes.removeAll { $0.id == eventId }
        }
    }
}

// MARK: - Supporting Types

struct KeystrokeEvent: Identifiable, Equatable {
    let id = UUID()
    let timestamp = Date()
    let keyString: String
    let modifiers: [ModifierKey]
    let isSpecialKey: Bool

    var displayString: String {
        let modifierStr = modifiers.map(\.symbol).joined()
        return "\(modifierStr)\(keyString)"
    }

    static func == (lhs: KeystrokeEvent, rhs: KeystrokeEvent) -> Bool {
        lhs.id == rhs.id
    }
}

enum ModifierKey: String, CaseIterable {
    case command = "⌘"
    case shift = "⇧"
    case option = "⌥"
    case control = "⌃"
    case fn = "fn"

    var symbol: String { rawValue }
}

enum OutputFormat: String, CaseIterable, Identifiable {
    case movHEVC = "mov_hevc"
    case mp4H264 = "mp4_h264"
    case movH264 = "mov_h264"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .movHEVC: return "MOV (HEVC) — Recommended"
        case .mp4H264: return "MP4 (H.264) — Compatible"
        case .movH264: return "MOV (H.264)"
        }
    }

    var fileExtension: String {
        switch self {
        case .movHEVC, .movH264: return "mov"
        case .mp4H264: return "mp4"
        }
    }
}
