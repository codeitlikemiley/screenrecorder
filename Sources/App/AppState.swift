import SwiftUI
import Combine
import ScreenCaptureKit

/// Central observable state object for the entire app.
/// All UI components and managers reference this to stay in sync.
/// Persists user preferences via UserDefaults.
@MainActor
class AppState: ObservableObject {
    // MARK: - UserDefaults Keys
    private enum Keys {
        static let isCameraEnabled = "isCameraEnabled"
        static let isMicrophoneEnabled = "isMicrophoneEnabled"
        static let isKeystrokeOverlayEnabled = "isKeystrokeOverlayEnabled"
        static let outputFormat = "outputFormat"
        static let saveDirectory = "saveDirectory"
        static let frameRate = "frameRate"
        static let cameraSize = "cameraSize"
        static let micVolume = "micVolume"
    }

    // MARK: - Recording State (runtime only, NOT persisted)
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var isCountingDown = false
    @Published var countdownValue = 3

    // MARK: - Feature Toggles (persisted)
    @Published var isCameraEnabled = false
    @Published var isKeystrokeOverlayEnabled = false
    @Published var isControlBarVisible = true
    @Published var isMicrophoneEnabled = false
    @Published var isMicMuted = false           // During-recording mute (doesn't disable mic)
    @Published var isCameraPreviewHidden = false // During-recording hide (doesn't disable camera)
    @Published var micVolume: Int = 5            // 0-10 scale, 0 = mute, 5 = default
    @Published var showVolumeOverlay = false      // Brief HUD when volume changes
    var volumeOverlayWorkItem: DispatchWorkItem?

    // MARK: - Camera (persisted)
    @Published var cameraPosition: CGPoint = .zero // 0,0 means "default" (bottom-right)
    @Published var cameraSize: CGFloat = 200

    // MARK: - Keystrokes (coalescing single-bar display)
    @Published var keystrokeDisplayText: String = ""
    @Published var keystrokeVisible: Bool = false
    var lastKeystrokeTime: Date = .distantPast
    var lastKeystrokeString: String = ""
    var lastRenderedSegment: String = ""
    var keystrokeRepeatCount: Int = 0
    var keystrokeFadeWorkItem: DispatchWorkItem?

    // MARK: - Output Settings (persisted)
    @Published var outputFormat: OutputFormat = .movHEVC
    @Published var saveDirectory: URL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        .appendingPathComponent("ScreenRecorder", isDirectory: true)
    @Published var frameRate: Int = 30

    // MARK: - Permissions (runtime only)
    @Published var hasScreenPermission = false
    @Published var hasCameraPermission = false
    @Published var hasMicrophonePermission = false
    @Published var hasAccessibilityPermission = false

    // MARK: - Current Recording
    @Published var currentRecordingURL: URL?

    // MARK: - Timer
    private var recordingTimer: Timer?
    private var saveCancellables = Set<AnyCancellable>()

    init() {
        // Load persisted settings
        loadSettings()

        // Ensure save directory exists
        try? FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)

        // Auto-save when settings change
        setupAutoSave()
    }

    // MARK: - Persistence

    private func loadSettings() {
        let defaults = UserDefaults.standard

        if defaults.object(forKey: Keys.isCameraEnabled) != nil {
            isCameraEnabled = defaults.bool(forKey: Keys.isCameraEnabled)
        }
        if defaults.object(forKey: Keys.isMicrophoneEnabled) != nil {
            isMicrophoneEnabled = defaults.bool(forKey: Keys.isMicrophoneEnabled)
        }
        if defaults.object(forKey: Keys.isKeystrokeOverlayEnabled) != nil {
            isKeystrokeOverlayEnabled = defaults.bool(forKey: Keys.isKeystrokeOverlayEnabled)
        }
        if let formatRaw = defaults.string(forKey: Keys.outputFormat),
           let format = OutputFormat(rawValue: formatRaw) {
            outputFormat = format
        }
        if let dirPath = defaults.string(forKey: Keys.saveDirectory) {
            saveDirectory = URL(fileURLWithPath: dirPath)
        }
        if defaults.object(forKey: Keys.frameRate) != nil {
            let rate = defaults.integer(forKey: Keys.frameRate)
            if rate > 0 { frameRate = rate }
        }
        if defaults.object(forKey: Keys.cameraSize) != nil {
            let size = defaults.double(forKey: Keys.cameraSize)
            if size > 0 { cameraSize = CGFloat(size) }
        }
        if defaults.object(forKey: Keys.micVolume) != nil {
            micVolume = defaults.integer(forKey: Keys.micVolume)
        }
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(isCameraEnabled, forKey: Keys.isCameraEnabled)
        defaults.set(isMicrophoneEnabled, forKey: Keys.isMicrophoneEnabled)
        defaults.set(isKeystrokeOverlayEnabled, forKey: Keys.isKeystrokeOverlayEnabled)
        defaults.set(outputFormat.rawValue, forKey: Keys.outputFormat)
        defaults.set(saveDirectory.path, forKey: Keys.saveDirectory)
        defaults.set(frameRate, forKey: Keys.frameRate)
        defaults.set(Double(cameraSize), forKey: Keys.cameraSize)
        defaults.set(micVolume, forKey: Keys.micVolume)
    }

    private func setupAutoSave() {
        // Combine all persisted property publishers and save on any change
        Publishers.MergeMany(
            $isCameraEnabled.map { _ in () }.eraseToAnyPublisher(),
            $isMicrophoneEnabled.map { _ in () }.eraseToAnyPublisher(),
            $isKeystrokeOverlayEnabled.map { _ in () }.eraseToAnyPublisher(),
            $outputFormat.map { _ in () }.eraseToAnyPublisher(),
            $saveDirectory.map { _ in () }.eraseToAnyPublisher(),
            $frameRate.map { _ in () }.eraseToAnyPublisher(),
            $cameraSize.map { _ in () }.eraseToAnyPublisher(),
            $micVolume.map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
        .sink { [weak self] in
            self?.saveSettings()
        }
        .store(in: &saveCancellables)
    }

    // MARK: - Mic Volume Control

    /// Adjust mic volume by delta, show HUD, auto-hide after 1.5s
    func adjustMicVolume(by delta: Int) {
        micVolume = max(0, min(10, micVolume + delta))
        isMicMuted = (micVolume == 0)
        flashVolumeHUD()
    }

    /// Reset mic volume to default (5)
    func resetMicVolume() {
        micVolume = 5
        isMicMuted = false
        flashVolumeHUD()
    }

    /// Show volume HUD briefly, auto-hide after 1.5s
    private func flashVolumeHUD() {
        showVolumeOverlay = true
        volumeOverlayWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.showVolumeOverlay = false
        }
        volumeOverlayWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
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
        lastKeystrokeTime = Date()
        keystrokeVisible = true

        let display = event.displayString

        // Coalesce repeated identical keys (e.g. "A ×3")
        if display == lastKeystrokeString && !event.isSpecialKey {
            keystrokeRepeatCount += 1
            // Replace the last entry with count
            if let range = keystrokeDisplayText.range(of: lastRenderedSegment, options: .backwards) {
                keystrokeDisplayText.replaceSubrange(range, with: "\(display) ×\(keystrokeRepeatCount)")
                lastRenderedSegment = "\(display) ×\(keystrokeRepeatCount)"
            }
        } else {
            // New key — append with separator
            let separator = keystrokeDisplayText.isEmpty ? "" : "  "
            keystrokeDisplayText += separator + display
            lastKeystrokeString = display
            lastRenderedSegment = display
            keystrokeRepeatCount = 1
        }

        // Trim if too long (keep last ~60 chars)
        if keystrokeDisplayText.count > 80 {
            let start = keystrokeDisplayText.index(keystrokeDisplayText.endIndex, offsetBy: -60)
            keystrokeDisplayText = String(keystrokeDisplayText[start...])
        }

        // Schedule fade-out after 2s of inactivity
        keystrokeFadeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.keystrokeVisible = false
            // Clear text after fade completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.keystrokeDisplayText = ""
                self?.lastKeystrokeString = ""
                self?.lastRenderedSegment = ""
                self?.keystrokeRepeatCount = 0
            }
        }
        keystrokeFadeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
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
