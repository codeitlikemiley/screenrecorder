import Foundation
import Combine
import QuartzCore

// MARK: - Slide Voice Tracker

/// Tracks the speaker's position **within a single slide** using speech recognition.
///
/// Algorithm: **Incremental delta with restart detection**.
/// - Each callback delivers the CUMULATIVE word list from Apple Speech.
/// - We extract only the NEW words (delta) since the last callback.
/// - Each new word tries to match script[confirmedUpTo] with lookahead=1.
/// - If the recognizer restarts (word count drops), we reset and reprocess.
/// - Forward-only: no backward movement. Use ⌘F1 to go back.
@MainActor
class SlideVoiceTracker: ObservableObject {

    // MARK: - State

    enum TrackingState: Equatable {
        case idle
        case tracking
        case adlibbing
        case paused
    }

    @Published var state: TrackingState = .idle
    @Published var confirmedUpTo: Int = 0
    @Published var tentativeWord: Int? = nil

    // MARK: - Slide Data

    private(set) var displayWords: [String] = []
    private(set) var normalizedWords: [String] = []
    var wordCount: Int { displayWords.count }

    // MARK: - Configuration

    /// Consecutive NEW words that fail to match before entering adlib state
    private let adlibMissThreshold: Int = 3 // Reduced from 6 for faster resync

    // MARK: - Internal

    /// Word count from the last callback (for delta extraction)
    private var lastCumulativeCount: Int = 0

    /// Consecutive new spoken words with no forward progress
    private var consecutiveMisses: Int = 0

    /// Last time we received speech input
    private var lastSpeechTime: CFTimeInterval = 0

    /// Timer for silence detection
    private var silenceTimer: Timer?

    // MARK: - Callbacks

    var onSlideComplete: (() -> Void)?

    // MARK: - Load Slide

    func loadSlide(text: String) {
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        displayWords = words
        normalizedWords = words.map { Self.normalise($0) }
        confirmedUpTo = 0
        tentativeWord = nil
        consecutiveMisses = 0
        lastCumulativeCount = 0
        lastSpeechTime = CACurrentMediaTime()

        if state != .idle {
            state = .tracking
        }
    }

    func resetTracking() {
        confirmedUpTo = 0
        tentativeWord = nil
        consecutiveMisses = 0
        lastCumulativeCount = 0
    }

    // MARK: - Lifecycle

    func start() {
        guard !normalizedWords.isEmpty else { return }
        state = .tracking
        lastSpeechTime = CACurrentMediaTime()
        startSilenceTimer()
    }

    func stop() {
        state = .idle
        silenceTimer?.invalidate()
        silenceTimer = nil
        tentativeWord = nil
    }

    // MARK: - Process Recognised Words (Incremental Delta)

    func handleRecognizedWords(_ words: [RecognizedWord]) {
        guard !words.isEmpty, !normalizedWords.isEmpty else { return }
        guard state != .idle else { return }
        guard confirmedUpTo < normalizedWords.count else { return }

        lastSpeechTime = CACurrentMediaTime()
        if state == .paused { state = .tracking }

        // ── Restart detection ──
        // Apple Speech restarts recognition every ~60s. When it does,
        // the cumulative word count drops back to a small number.
        // We detect this and reset our counter so we reprocess the new list.
        if words.count < lastCumulativeCount / 2 {
            print("🔄 SlideVoiceTracker: recognizer restart detected (\(lastCumulativeCount)→\(words.count))")
            lastCumulativeCount = 0
        }

        // ── Extract delta (only NEW words) ──
        guard words.count > lastCumulativeCount else { return }
        let newCount = words.count - lastCumulativeCount
        let newWords = words.suffix(newCount)
        lastCumulativeCount = words.count

        // ── Forward-only matching ──
        for word in newWords {
            guard confirmedUpTo < normalizedWords.count else { break }

            let spoken = Self.normalise(word.text)
            if spoken.isEmpty { continue }

            // Evaluate lookahead dynamically per word (in case state changes mid-burst)
            let isResyncMode = (state == .adlibbing || state == .paused)
            let currentLookAhead = isResyncMode ? (normalizedWords.count - confirmedUpTo) : 8

            let pos = confirmedUpTo
            let searchEnd = min(normalizedWords.count, pos + currentLookAhead)

            var matched = false
            for idx in pos..<searchEnd {
                if Self.wordMatch(spoken, normalizedWords[idx]) {
                    confirmedUpTo = idx + 1
                    consecutiveMisses = 0
                    if state == .adlibbing { state = .tracking }
                    matched = true
                    print("✅ [\(confirmedUpTo)/\(wordCount)] \"\(spoken)\" → \"\(normalizedWords[idx])\"")
                    break
                }
            }

            if !matched {
                consecutiveMisses += 1
                print("❌ miss [\(consecutiveMisses)] \"\(spoken)\" ≠ \"\(pos < normalizedWords.count ? normalizedWords[pos] : "END")\"")
                if consecutiveMisses >= adlibMissThreshold && state != .adlibbing {
                    state = .adlibbing
                    print("🎭 SlideVoiceTracker: adlibbing (missed \(consecutiveMisses) words)")
                }
            }
        }

        // Update tentative (the next expected word)
        tentativeWord = confirmedUpTo < normalizedWords.count ? confirmedUpTo : nil

        // Slide complete?
        if confirmedUpTo >= normalizedWords.count {
            print("🏁 SlideVoiceTracker: slide complete!")
            state = .idle
            onSlideComplete?()
        }
    }

    // MARK: - Silence Detection

    private func startSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSilence() }
        }
    }

    private func checkSilence() {
        guard state == .tracking || state == .adlibbing else { return }
        if CACurrentMediaTime() - lastSpeechTime > 3.0 {
            state = .paused
        }
    }

    // MARK: - Word Matching

    /// Match spoken word against script word.
    /// Short words (≤3 chars): exact match only after normalisation.
    /// 4-5 char words: edit distance ≤ 1.
    /// 6+ char words: edit distance ≤ 2 or 4-char prefix match.
    static func wordMatch(_ spoken: String, _ script: String) -> Bool {
        if spoken == script { return true }
        if spoken.isEmpty || script.isEmpty { return false }

        let minLen = min(spoken.count, script.count)

        // Short words: exact only (prevents "the"≈"too", "was"≈"we")
        if minLen <= 3 { return false }

        let maxLen = max(spoken.count, script.count)
        if maxLen <= 5 { return levenshtein(spoken, script) <= 1 }

        // 6+ chars: prefix match or edit distance
        if spoken.count >= 4 && script.count >= 4 {
            if String(spoken.prefix(4)) == String(script.prefix(4)) { return true }
        }
        return levenshtein(spoken, script) <= 2
    }

    static func normalise(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .joined()
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var dp = Array(0...b.count)
        for i in 1...a.count {
            var prev = dp[0]
            dp[0] = i
            for j in 1...b.count {
                let temp = dp[j]
                dp[j] = a[i-1] == b[j-1] ? prev : min(prev, min(dp[j], dp[j-1])) + 1
                prev = temp
            }
        }
        return dp[b.count]
    }
}
