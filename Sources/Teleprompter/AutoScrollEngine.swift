import Foundation
import Combine
import QuartzCore

// MARK: - Auto-Scroll Engine

/// Simple WPM-based constant-speed scrolling engine.
/// Text scrolls at a fixed words-per-minute rate.
/// Speed adjustable with nudge controls.
@MainActor
class AutoScrollEngine: ObservableObject {

    /// Whether the engine is currently running
    @Published var isRunning: Bool = false

    /// Words per minute (80...250)
    @Published var wordsPerMinute: Double = 150

    /// Total word count in the script
    var totalWords: Int = 0

    /// Current progress (0.0...1.0)
    @Published var progress: Double = 0.0

    // MARK: - Private

    private var scrollTimer: Timer?
    private var lastTickTime: CFTimeInterval = 0

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastTickTime = CACurrentMediaTime()
        scrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        print("▶ AutoScrollEngine: started at \(Int(wordsPerMinute)) WPM")
    }

    func pause() {
        isRunning = false
        scrollTimer?.invalidate()
        scrollTimer = nil
    }

    func stop() {
        pause()
        progress = 0.0
    }

    func toggle() {
        if isRunning { pause() } else { start() }
    }

    /// Nudge speed up or down by 10 WPM
    func nudgeSpeed(faster: Bool) {
        wordsPerMinute += faster ? 10 : -10
        wordsPerMinute = max(80, min(250, wordsPerMinute))
    }

    // MARK: - Private

    private func tick() {
        guard isRunning, totalWords > 0 else { return }

        let now = CACurrentMediaTime()
        let dt = now - lastTickTime
        lastTickTime = now

        let wordsPerSecond = wordsPerMinute / 60.0
        let progressIncrement = (wordsPerSecond * dt) / Double(totalWords)

        progress += progressIncrement

        if progress >= 1.0 {
            progress = 1.0
            pause()
        }
    }
}
