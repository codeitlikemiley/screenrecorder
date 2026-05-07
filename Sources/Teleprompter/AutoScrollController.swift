import Foundation
import Combine
import QuartzCore

// MARK: - Teleprompter Controller

/// Unified teleprompter controller — **Voice-Guided Slides**.
///
/// Slides are the unit of navigation. Voice tracking operates *within* each slide,
/// highlighting words as the speaker says them. When all words in a slide are
/// confirmed, the teleprompter auto-advances.
///
/// Manual override (⌘F1/F2) always works regardless of voice state.
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

    /// Whether voice tracking is enabled (vs pure manual slide navigation)
    @Published var isVoiceTrackingEnabled: Bool = false

    // MARK: - Slide State

    @Published var slides: [String] = []
    @Published var currentSlideIndex: Int = 0

    var currentSlide: String {
        guard !slides.isEmpty, currentSlideIndex < slides.count else { return "" }
        return slides[currentSlideIndex]
    }

    var slideCount: Int { slides.count }
    var isFirstSlide: Bool { currentSlideIndex == 0 }
    var isLastSlide: Bool { currentSlideIndex >= slides.count - 1 }

    var slideProgressText: String {
        "\(currentSlideIndex + 1) / \(slideCount)"
    }

    // MARK: - Voice Tracking Engine

    let voiceTracker = SlideVoiceTracker()
    let voiceFollowEngine = VoiceFollowEngine()

    /// Manual scroll target within the current slide (word index).
    /// When set, the viewport scrolls here instead of following voice.
    /// Auto-clears when voice tracking advances (user starts speaking).
    @Published var manualScrollTarget: Int? = nil

    /// How many words to jump per ⌘F1/⌘F2 press in voice follow mode
    private let scrollStepWords: Int = 8

    /// Delay before auto-advancing to next slide after all words confirmed (seconds)
    private let slideAdvanceDelay: TimeInterval = 0.6

    /// Work item for delayed slide advance
    private var slideAdvanceWorkItem: DispatchWorkItem?

    // MARK: - Mode (for settings persistence)

    /// Operating mode — maps to `isVoiceTrackingEnabled` at runtime.
    @Published var mode: TeleprompterMode = .manual {
        didSet {
            isVoiceTrackingEnabled = (mode == .voiceFollow)
        }
    }

    // MARK: - Progress

    var progress: Double {
        if slideCount == 0 { return 0 }

        let slideProgress = Double(currentSlideIndex) / Double(max(1, slideCount))
        let wordProgress: Double
        if isVoiceTrackingEnabled && voiceTracker.wordCount > 0 {
            wordProgress = Double(voiceTracker.confirmedUpTo) / Double(voiceTracker.wordCount)
        } else {
            wordProgress = 0
        }

        // Blend: slide-level + word-level within current slide
        let perSlideWeight = 1.0 / Double(max(1, slideCount))
        return slideProgress + wordProgress * perSlideWeight
    }

    var progressText: String {
        if isVoiceTrackingEnabled {
            return "\(voiceTracker.confirmedUpTo)/\(voiceTracker.wordCount)"
        }
        return slideProgressText
    }

    /// Status text for voice tracking state
    var voiceFollowStatus: String {
        switch voiceTracker.state {
        case .idle:       return "Ready"
        case .tracking:   return "Tracking"
        case .adlibbing:  return "Off-script"
        case .paused:     return "Paused"
        }
    }

    // MARK: - Slide Management

    func loadSlides(from script: TeleprompterScript, maxWords: Int) {
        slides = script.slides(maxWords: maxWords)
        currentSlideIndex = 0
        loadCurrentSlideForVoiceTracking()
    }

    func nextSlide() {
        slideAdvanceWorkItem?.cancel()
        guard !slides.isEmpty, currentSlideIndex < slides.count - 1 else {
            if !slides.isEmpty { state = .finished }
            return
        }
        currentSlideIndex += 1
        loadCurrentSlideForVoiceTracking()
    }

    func previousSlide() {
        slideAdvanceWorkItem?.cancel()
        
        if state == .finished {
            state = .active
            return // Just resume being active on the last slide
        }
        
        guard currentSlideIndex > 0 else { return }
        currentSlideIndex -= 1
        loadCurrentSlideForVoiceTracking()
    }

    func goToSlide(at index: Int) {
        slideAdvanceWorkItem?.cancel()
        guard !slides.isEmpty else { return }
        currentSlideIndex = max(0, min(slides.count - 1, index))
        manualScrollTarget = nil
        loadCurrentSlideForVoiceTracking()
    }

    // MARK: - In-Slide Scroll (Voice Follow mode)

    /// Scroll viewport forward within the current slide (⌘F2 in voice follow).
    /// If already at the end of the slide, advance to next slide.
    func scrollForwardInSlide() {
        let current = manualScrollTarget ?? voiceTracker.confirmedUpTo
        let maxWord = voiceTracker.wordCount - 1

        if current >= maxWord {
            // At end of slide — go to next slide
            nextSlide()
            return
        }

        let target = min(current + scrollStepWords, maxWord)
        manualScrollTarget = target
    }

    /// Scroll viewport backward within the current slide (⌘F1 in voice follow).
    /// If already at the beginning of the slide, go to previous slide.
    func scrollBackInSlide() {
        if state == .finished {
            state = .active
            manualScrollTarget = nil // Reset to end of last slide implicitly
            return
        }

        let current = manualScrollTarget ?? voiceTracker.confirmedUpTo

        if current <= 0 {
            // At start of slide — go to previous slide
            previousSlide()
            return
        }

        let target = max(0, current - scrollStepWords)
        manualScrollTarget = target
    }

    /// Clear manual scroll — lets voice tracking control viewport again
    func clearManualScroll() {
        manualScrollTarget = nil
    }

    /// Load the current slide's text into the voice tracker
    private func loadCurrentSlideForVoiceTracking() {
        guard isVoiceTrackingEnabled else { return }
        voiceTracker.loadSlide(text: currentSlide)
        if state == .active {
            voiceTracker.start()
        }
    }

    // MARK: - Controls

    func start(settings: TeleprompterSettings? = nil, script: TeleprompterScript? = nil) {
        currentSlideIndex = 0
        state = .active

        // Determine mode from settings
        let settingsMode = settings?.mode ?? mode
        isVoiceTrackingEnabled = (settingsMode == .voiceFollow)

        if isVoiceTrackingEnabled {
            guard let script, !script.isEmpty else { return }

            // Load first slide for voice tracking
            loadCurrentSlideForVoiceTracking()

            // Wire up voice tracker slide completion
            voiceTracker.onSlideComplete = { [weak self] in
                self?.handleSlideComplete()
            }

            // Configure and start the voice engine
            voiceFollowEngine.phraseWindowSize = settings?.phraseWindowSize ?? 12
            voiceFollowEngine.speechLocale = settings?.speechLocale ?? "en-US"


            // Wire speech provider words → slide voice tracker
            voiceFollowEngine.onRecognizedWords = { [weak self] words in
                self?.voiceTracker.handleRecognizedWords(words)
            }
            voiceFollowEngine.start()
            voiceTracker.start()
        }
    }

    func pause() {
        guard state == .active else { return }
        if isVoiceTrackingEnabled {
            voiceFollowEngine.stop()
            voiceTracker.stop()
        }
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        if isVoiceTrackingEnabled {
            voiceFollowEngine.start()
            voiceTracker.start()
        }
        state = .active
    }

    func stop() {
        slideAdvanceWorkItem?.cancel()
        voiceFollowEngine.stop()
        voiceTracker.stop()
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

    // MARK: - Slide Auto-Advance

    /// Called when the voice tracker confirms all words in the current slide.
    /// Waits a brief beat, then advances to the next slide.
    private func handleSlideComplete() {
        guard state == .active else { return }

        if isLastSlide {
            state = .finished
            voiceFollowEngine.stop()
            voiceTracker.stop()
            return
        }

        // Brief delay before auto-advancing (gives the speaker a beat to breathe)
        slideAdvanceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .active else { return }
            self.currentSlideIndex += 1
            self.loadCurrentSlideForVoiceTracking()
        }
        slideAdvanceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + slideAdvanceDelay, execute: work)
    }
}
