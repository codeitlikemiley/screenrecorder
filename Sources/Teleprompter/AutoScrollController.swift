import Foundation
import Combine
import QuartzCore

// MARK: - Auto-Scroll Controller

/// Orchestrates the teleprompter display across three modes:
/// - **Manual**: Slide-by-slide, user navigates with ⌘F1/⌘F2
/// - **Auto-Scroll**: Fixed WPM continuous scroll
/// - **Voice-Follow**: LCS-based voice alignment continuous scroll
@MainActor
class AutoScrollController: ObservableObject {

    // MARK: State Machine

    enum ScrollState: Equatable {
        case idle
        case active
        case paused
        case finished
    }

    @Published var state: ScrollState = .idle

    /// Current operating mode
    @Published var mode: TeleprompterMode = .manual

    // MARK: - Slide State (Manual mode)

    @Published var slides: [String] = []
    @Published var currentSlideIndex: Int = 0

    var currentSlide: String {
        guard !slides.isEmpty, currentSlideIndex < slides.count else { return "" }
        return slides[currentSlideIndex]
    }

    var slideCount: Int { slides.count }
    var isFirstSlide: Bool { currentSlideIndex == 0 }
    var isLastSlide: Bool { currentSlideIndex >= slides.count - 1 }

    var slideProgress: Double {
        guard slideCount > 0 else { return 0 }
        return Double(currentSlideIndex) / Double(max(1, slideCount - 1))
    }

    var slideProgressText: String {
        "\(currentSlideIndex + 1) / \(slideCount)"
    }

    // MARK: - Engines

    let voiceFollowEngine = VoiceFollowEngine()
    let autoScrollEngine = AutoScrollEngine()

    /// Measured text height for voice-follow pixel offset calculation (set by view)
    var voiceFollowContentHeight: CGFloat = 0
    var voiceFollowViewportHeight: CGFloat = 0

    // MARK: - Mode-Aware Progress

    var progress: Double {
        switch mode {
        case .manual:      return slideProgress
        case .autoScroll:  return autoScrollEngine.progress
        case .voiceFollow: return voiceFollowEngine.progress
        }
    }

    var progressText: String {
        switch mode {
        case .manual:
            return slideProgressText
        case .autoScroll:
            return "\(Int(autoScrollEngine.wordsPerMinute)) WPM"
        case .voiceFollow:
            let engine = voiceFollowEngine
            let pos = Int(engine.displayPosition) + 1
            let total = engine.wordCount
            return "\(pos) / \(total)"
        }
    }

    /// Status text for the voice-follow state
    var voiceFollowStatus: String {
        switch voiceFollowEngine.state {
        case .idle:       return "Idle"
        case .tracking:   return "Tracking"
        case .adlibbing:  return "Off-script"
        case .lost:       return "Listening…"
        }
    }

    // MARK: - Full script text (for continuous scroll modes)
    private(set) var fullScriptText: String = ""

    /// Individual words for word-level scroll targeting
    var fullScriptWords: [String] {
        fullScriptText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    }

    // MARK: - Slide Management (Manual mode)

    func loadSlides(from script: TeleprompterScript, maxWords: Int) {
        slides = script.slides(maxWords: maxWords)
        currentSlideIndex = 0
        fullScriptText = script.text
    }

    func nextSlide() {
        guard !slides.isEmpty, currentSlideIndex < slides.count - 1 else {
            if !slides.isEmpty { state = .finished }
            return
        }
        currentSlideIndex += 1
    }

    func previousSlide() {
        guard currentSlideIndex > 0 else { return }
        currentSlideIndex -= 1
    }

    func goToSlide(at index: Int) {
        guard !slides.isEmpty else { return }
        currentSlideIndex = max(0, min(slides.count - 1, index))
    }

    // MARK: - Controls

    func start(settings: TeleprompterSettings? = nil, script: TeleprompterScript? = nil) {
        switch mode {
        case .manual:
            currentSlideIndex = 0
            state = .active

        case .autoScroll:
            guard let script, !script.isEmpty else {
                state = .active
                return
            }
            fullScriptText = script.text
            autoScrollEngine.totalWords = script.wordCount
            autoScrollEngine.wordsPerMinute = settings?.autoScrollWPM ?? 150
            autoScrollEngine.progress = 0
            autoScrollEngine.start()
            state = .active

        case .voiceFollow:
            guard let script, !script.isEmpty else {
                state = .active
                return
            }
            fullScriptText = script.text
            voiceFollowEngine.loadScript(text: script.text)
            voiceFollowEngine.phraseWindowSize = settings?.phraseWindowSize ?? 12
            voiceFollowEngine.speechLocale = settings?.speechLocale ?? "en-US"
            voiceFollowEngine.speechBackend = settings?.speechBackend ?? .apple
            voiceFollowEngine.onScriptComplete = { [weak self] in
                self?.state = .finished
            }
            voiceFollowEngine.start()
            state = .active
        }
    }

    func pause() {
        guard state == .active else { return }
        if mode == .autoScroll { autoScrollEngine.pause() }
        if mode == .voiceFollow { voiceFollowEngine.stop() }
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        if mode == .autoScroll { autoScrollEngine.start() }
        if mode == .voiceFollow { voiceFollowEngine.start() }
        state = .active
    }

    func stop() {
        autoScrollEngine.stop()
        voiceFollowEngine.stop()
        currentSlideIndex = 0
        state = .idle
    }

    func reset() {
        stop()
    }

    func toggle() {
        switch state {
        case .idle, .finished: start()
        case .active:          pause()
        case .paused:          resume()
        }
    }

    /// Nudge auto-scroll speed (⌘F1 = slower, ⌘F2 = faster)
    func nudgeSpeed(faster: Bool) {
        autoScrollEngine.nudgeSpeed(faster: faster)
    }
}
