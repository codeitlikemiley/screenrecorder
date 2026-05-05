import Foundation
import Combine
import QuartzCore

// MARK: - Voice Follow Engine

/// Professional voice-tracking teleprompter engine.
///
/// **Dual-path alignment:**
/// 1. **Fast path** — for sequential reading (the 90% case):
///    Check if the latest spoken word matches the next few script words.
///    If yes, advance immediately. Zero latency.
/// 2. **Slow path** — for skip detection:
///    Use LCS alignment to find where the speaker jumped to.
///    Only activates when fast-path fails for several consecutive words.
///
/// **Pause-on-silence**: When you stop talking, the teleprompter pauses.
/// **No momentum timer**: Nothing force-advances. Ever.
/// **Smooth scroll**: Position interpolates toward target at 30fps.
@MainActor
class VoiceFollowEngine: ObservableObject {

    // MARK: - State Machine

    enum FollowState: Equatable {
        case idle           // Not listening
        case tracking       // Confidently following the speaker
        case adlibbing      // Speaker went off-script, holding position
        case lost           // Low confidence, paused, waiting for strong match
    }

    @Published var state: FollowState = .idle

    /// The smoothed display position (0-based word index, fractional for interpolation)
    @Published var displayPosition: Double = 0

    /// Whether the speech provider is listening
    @Published var isListening: Bool = false

    // MARK: - Script Data

    /// Normalised words for matching
    private(set) var scriptWords: [String] = []

    /// Total word count
    var wordCount: Int { scriptWords.count }

    /// Word-level progress (0.0...1.0)
    var progress: Double {
        guard wordCount > 0 else { return 0 }
        return displayPosition / Double(max(1, wordCount - 1))
    }

    // MARK: - Configuration

    /// How many recent spoken words to use for LCS matching
    var phraseWindowSize: Int = 12

    /// Locale for speech recognition
    var speechLocale: String = "en-US"

    /// Which speech backend to use
    var speechBackend: SpeechBackend = .apple

    // MARK: - Scoring Thresholds

    /// LCS score below this → LOST (normalized by spoken words, so 0.25 = only 25% of spoken words matched)
    private let lostThreshold: Double = 0.25

    /// Required LCS for a long jump (> 20 words ahead)
    private let longJumpThreshold: Double = 0.55

    /// Max forward jump at moderate confidence
    private let maxNormalJump: Int = 20

    /// Distance penalty per word of distance from current position
    private let distancePenalty: Double = 0.001

    // MARK: - Fast Path Config

    /// How many words ahead to check in fast-path sequential matching
    private let fastPathLookAhead: Int = 6

    /// After this many consecutive fast-path misses, trigger slow-path LCS
    private let fastPathMissThreshold: Int = 4

    /// Consecutive spoken words that didn't match the fast path
    private var fastPathMissCount: Int = 0

    // MARK: - Scroll Smoothing

    /// Target position (the alignment-computed best match word index)
    private var targetPosition: Double = 0

    /// Smoothing factor for position interpolation
    private let positionSmoothing: Double = 0.82

    /// Timer for smooth position updates
    private var scrollTimer: Timer?

    // MARK: - Silence Detection

    private var lastSpeechTime: CFTimeInterval = 0
    private var scrollSpeedMultiplier: Double = 1.0
    private var currentRMS: Float = 0
    private let silenceThreshold: Float = 0.01

    // MARK: - Speech Provider

    /// Exposed so RecordingCoordinator can feed mic samples during screen recording
    private(set) var speechProvider: SpeechProvider?
    private var lastWordCount: Int = 0

    /// When true, the speech provider uses external audio (from ScreenCaptureKit mic)
    /// instead of creating its own AVAudioEngine tap.
    var useExternalAudioFeed: Bool = false

    // MARK: - Callbacks

    var onScriptComplete: (() -> Void)?

    // MARK: - Setup

    func loadScript(text: String) {
        let rawWords = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        scriptWords = rawWords.map { Self.normalise($0) }
        displayPosition = 0
        targetPosition = 0
        lastWordCount = 0
        fastPathMissCount = 0
        state = .idle
    }

    // MARK: - Lifecycle

    func start() {
        guard !scriptWords.isEmpty else {
            print("⚠️ VoiceFollowEngine: no script loaded")
            return
        }

        let provider: SpeechProvider
        switch speechBackend {
        case .apple:
            provider = AppleSpeechProvider()
        case .whisperKit:
            provider = WhisperKitProvider()
        }

        provider.useExternalAudioFeed = useExternalAudioFeed

        // Store the closure that will dispatch to main actor
        provider.onWords = { [weak self] words in
            Task { @MainActor [weak self] in
                self?.handleSpokenWords(words)
            }
        }

        speechProvider = provider
        provider.start(locale: speechLocale)

        isListening = true
        state = .tracking
        lastSpeechTime = CACurrentMediaTime()
        startScrollTimer()

        print("🎤 VoiceFollowEngine: started (backend: \(speechBackend), locale: \(speechLocale), words: \(scriptWords.count))")
    }

    func stop() {
        speechProvider?.stop()
        speechProvider = nil
        scrollTimer?.invalidate()
        scrollTimer = nil
        isListening = false
        state = .idle
    }

    // MARK: - Scroll Timer (30fps smooth interpolation)

    private func startScrollTimer() {
        scrollTimer?.invalidate()
        scrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickScroll()
            }
        }
    }

    private func tickScroll() {
        guard state != .idle else { return }

        updateSilenceState()

        let speed = scrollSpeedMultiplier
        if speed > 0 {
            let delta = targetPosition - displayPosition
            if delta > 0.1 {
                displayPosition += delta * (1.0 - positionSmoothing) * speed
            } else if delta > 0 {
                displayPosition = targetPosition // Snap for tiny deltas
            }
        }

        if displayPosition >= Double(scriptWords.count - 1) {
            onScriptComplete?()
        }
    }

    private func updateSilenceState() {
        if let apple = speechProvider as? AppleSpeechProvider {
            currentRMS = apple.currentRMS
        }

        let isSpeaking = currentRMS > silenceThreshold

        if isSpeaking {
            lastSpeechTime = CACurrentMediaTime()
            scrollSpeedMultiplier = 1.0
        } else {
            let silence = CACurrentMediaTime() - lastSpeechTime
            if silence > 2.0 {
                scrollSpeedMultiplier = 0.0
            } else if silence > 1.0 {
                scrollSpeedMultiplier = 0.3
            }
        }
    }

    // MARK: - Core: Dual-Path Alignment

    private func handleSpokenWords(_ rawWords: [String]) {
        guard !rawWords.isEmpty, !scriptWords.isEmpty else { return }
        guard rawWords.count > lastWordCount else { return }

        let newWords = rawWords.count - lastWordCount
        lastWordCount = rawWords.count

        // Get the newly spoken words (what just came in)
        let newSpoken = rawWords.suffix(newWords).map { Self.normalise($0) }
        let currentPos = Int(targetPosition)

        // ═══════════════════════════════════════════════════
        // FAST PATH: Sequential matching (90% of the time)
        // Check if the latest words match the next words in the script
        // ═══════════════════════════════════════════════════
        for spokenWord in newSpoken {
            if spokenWord.isEmpty { continue }

            let searchEnd = min(scriptWords.count, Int(targetPosition) + fastPathLookAhead)
            let searchStart = Int(targetPosition)

            var matched = false
            for idx in searchStart..<searchEnd {
                if Self.fuzzyWordMatch(spokenWord, scriptWords[idx]) {
                    // Match! Advance past this word.
                    targetPosition = Double(idx + 1)
                    state = .tracking
                    fastPathMissCount = 0
                    matched = true
                    print("✅ Fast match: \"\(spokenWord)\" → script[\(idx)] \"\(scriptWords[idx])\"")
                    break
                }
            }

            if !matched {
                fastPathMissCount += 1
            }
        }

        // ═══════════════════════════════════════════════════
        // SLOW PATH: LCS alignment (skip detection)
        // Only triggers after several consecutive misses
        // ═══════════════════════════════════════════════════
        if fastPathMissCount >= fastPathMissThreshold {
            let recent = rawWords.suffix(phraseWindowSize).map { Self.normalise($0) }
            performLCSAlignment(spoken: recent, currentPos: Int(targetPosition))
            fastPathMissCount = 0 // Reset after LCS attempt
        }
    }

    // MARK: - LCS Alignment (Slow Path)

    private func performLCSAlignment(spoken: [String], currentPos: Int) {
        guard !spoken.isEmpty else { return }

        // Search: 10 words behind, 40 words ahead
        let searchStart = max(0, currentPos - 10)
        let searchEnd = min(scriptWords.count, currentPos + 40)

        var bestScore: Double = 0
        var bestIndex = currentPos

        // Slide a window that matches the spoken word count
        let windowSize = min(spoken.count + 4, 16) // Slightly larger than spoken to allow for skips

        for start in searchStart..<searchEnd {
            let windowEnd = min(start + windowSize, scriptWords.count)
            let window = Array(scriptWords[start..<windowEnd])

            let textScore = Self.lcsScore(spoken, window)
            let distance = abs(start - currentPos)
            let penalty = Double(distance) * distancePenalty
            let finalScore = textScore - penalty

            if finalScore > bestScore {
                bestScore = finalScore
                bestIndex = start + (windowEnd - start) / 2 // Center of the matching window
            }
        }

        let jumpDistance = bestIndex - currentPos

        print("🔍 LCS: bestScore=\(String(format: "%.2f", bestScore)) bestIdx=\(bestIndex) jump=\(jumpDistance) spoken=\(spoken.suffix(4))")

        if bestScore < lostThreshold {
            state = .lost
            return
        }

        if jumpDistance > maxNormalJump && bestScore < longJumpThreshold {
            state = .adlibbing
            return
        }

        // Good match — move
        state = .tracking
        let newTarget = Double(bestIndex)
        if newTarget > targetPosition {
            targetPosition = newTarget
        }
    }

    // MARK: - LCS Scoring

    /// Longest Common Subsequence score between spoken and script words.
    /// **Normalized by spoken word count** (not max), because the script window
    /// is always larger than the spoken buffer and would unfairly suppress the score.
    static func lcsScore(_ spoken: [String], _ script: [String]) -> Double {
        guard !spoken.isEmpty, !script.isEmpty else { return 0 }

        let m = spoken.count
        let n = script.count

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

        for i in 1...m {
            for j in 1...n {
                if fuzzyWordMatch(spoken[i - 1], script[j - 1]) {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        let lcs = dp[m][n]
        // Normalize by SPOKEN word count — if 4/5 spoken words match, that's 0.80
        return Double(lcs) / Double(m)
    }

    /// Fuzzy word comparison — accounts for accent variations.
    static func fuzzyWordMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.isEmpty || b.isEmpty { return false }

        // Prefix match (≥3 chars)
        if a.count >= 3 && b.count >= 3 {
            if a.hasPrefix(b) || b.hasPrefix(a) { return true }
        }

        // Edit distance
        let maxLen = max(a.count, b.count)
        let allowed: Int
        if maxLen <= 3 { allowed = 1 }
        else if maxLen <= 6 { allowed = 2 }
        else { allowed = 3 }
        return levenshtein(a, b) <= allowed
    }

    // MARK: - Helpers

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
