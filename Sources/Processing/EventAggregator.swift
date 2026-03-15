import Foundation
import CoreGraphics

/// Pre-processes raw interaction events into semantic action groups before AI generation.
/// Groups sequential keystrokes into typed text, merges scroll events, detects form navigation,
/// and correlates speech transcript segments with action time ranges.
class EventAggregator {

    /// Configuration for aggregation thresholds
    struct Config {
        /// Maximum gap between keystrokes to consider them part of the same typing sequence (seconds)
        var keystrokeGapThreshold: TimeInterval = 2.0
        /// Maximum gap between scroll events to merge them (seconds)
        var scrollMergeThreshold: TimeInterval = 1.0
        /// Maximum distance (pixels) between clicks to consider them as targeting the same area
        var clickProximityThreshold: CGFloat = 20.0
        /// Minimum number of raw events to warrant aggregation
        var minEventsToAggregate: Int = 2
    }

    private let config: Config

    init(config: Config = Config()) {
        self.config = config
    }

    // MARK: - Aggregate

    /// Aggregate raw events into semantic actions with optional speech correlation.
    func aggregate(
        events: [InteractionEvent],
        transcript: SpeechTranscriber.TranscriptResult? = nil
    ) -> [AggregatedAction] {
        guard !events.isEmpty else { return [] }

        // Sort by timestamp
        let sorted = events.sorted { $0.timestamp < $1.timestamp }

        // Phase 1: Group into preliminary clusters by type and proximity
        var actions: [AggregatedAction] = []
        var i = 0

        while i < sorted.count {
            let event = sorted[i]

            switch event {
            case .keystroke:
                // Collect consecutive keystrokes into typed text
                let (action, consumed) = aggregateKeystrokes(from: sorted, startingAt: i)
                actions.append(action)
                i += consumed

            case .mouseScroll:
                // Merge consecutive scrolls
                let (action, consumed) = aggregateScrolls(from: sorted, startingAt: i)
                actions.append(action)
                i += consumed

            case .mouseClick(let click):
                // Keep clicks as individual actions (they're usually meaningful)
                let action = AggregatedAction(
                    actionType: click.clickCount > 1 ? .doubleClick : .click,
                    startTimestamp: click.timestamp,
                    endTimestamp: click.timestamp,
                    description: click.button == .right ? "Right-click" : "Click",
                    position: click.position,
                    rawEvents: [event],
                    typedText: nil,
                    relatedSpeech: []
                )
                actions.append(action)
                i += 1

            case .mouseDrag(let drag):
                let action = AggregatedAction(
                    actionType: .drag,
                    startTimestamp: drag.timestamp,
                    endTimestamp: drag.timestamp + drag.duration,
                    description: "Drag",
                    position: drag.startPosition,
                    rawEvents: [event],
                    typedText: nil,
                    relatedSpeech: []
                )
                actions.append(action)
                i += 1
            }
        }

        // Phase 2: Detect form-fill patterns (click → type → click/tab → type)
        actions = detectFormFillPatterns(in: actions)

        // Phase 3: Attach speech segments to actions
        if let transcript = transcript {
            actions = attachSpeech(transcript: transcript, to: actions)
        }

        // Renumber
        for idx in actions.indices {
            actions[idx].sequenceNumber = idx + 1
        }

        print("  📦 Aggregated \(events.count) raw events → \(actions.count) semantic actions")
        return actions
    }

    // MARK: - Keystroke Aggregation

    /// Collects sequential keystrokes into a single "type" action.
    /// Boundaries: time gap > threshold, or a form-navigation key (Tab, Enter, Escape).
    private func aggregateKeystrokes(
        from events: [InteractionEvent],
        startingAt startIdx: Int
    ) -> (AggregatedAction, Int) {
        var keystrokes: [KeystrokeLogEvent] = []
        var rawEvents: [InteractionEvent] = []
        var i = startIdx

        while i < events.count {
            guard case .keystroke(let ks) = events[i] else { break }

            // Check time gap from previous keystroke
            if let last = keystrokes.last {
                let gap = ks.timestamp - last.timestamp
                if gap > config.keystrokeGapThreshold {
                    break // Too far apart — start a new group
                }
            }

            // Form-navigation keys break the sequence AFTER being included
            let isFormNav = isFormNavigationKey(ks)

            keystrokes.append(ks)
            rawEvents.append(events[i])
            i += 1

            // If this was a form-nav key, end the group here
            if isFormNav && !keystrokes.isEmpty {
                break
            }
        }

        let consumed = keystrokes.count
        let firstTs = keystrokes.first?.timestamp ?? 0
        let lastTs = keystrokes.last?.timestamp ?? firstTs

        // Build the typed text, handling special keys
        let typedText = buildTypedText(from: keystrokes)

        // Determine if this is a shortcut (modifier + single key)
        let isShortcut = keystrokes.count == 1 && !keystrokes[0].modifiers.isEmpty

        let description: String
        let actionType: AggregatedAction.ActionType

        if isShortcut {
            let ks = keystrokes[0]
            let mods = ks.modifiers.joined()
            description = "Shortcut: \(mods)\(ks.key)"
            actionType = .shortcut
        } else if typedText.count <= 3 && keystrokes.allSatisfy({ $0.isSpecialKey }) {
            // Just special keys (Enter, Tab, etc.)
            description = "Press \(typedText)"
            actionType = .keyPress
        } else {
            description = "Type \"\(typedText)\""
            actionType = .type
        }

        // Use position of any nearby click (for where the typing happened)
        let position: CGPoint? = nil // will be enriched in form-fill detection

        let action = AggregatedAction(
            actionType: actionType,
            startTimestamp: firstTs,
            endTimestamp: lastTs,
            description: description,
            position: position,
            rawEvents: rawEvents,
            typedText: typedText,
            relatedSpeech: []
        )

        return (action, consumed)
    }

    /// Build human-readable text from a sequence of keystrokes
    private func buildTypedText(from keystrokes: [KeystrokeLogEvent]) -> String {
        var text = ""
        for ks in keystrokes {
            if ks.isSpecialKey {
                switch ks.key.lowercased() {
                case "space", " ":
                    text += " "
                case "return", "enter", "↩":
                    text += "↩"
                case "tab", "⇥":
                    text += "⇥"
                case "delete", "backspace", "⌫":
                    // Remove last character if possible
                    if !text.isEmpty { text.removeLast() }
                case "escape", "⎋":
                    text += "⎋"
                default:
                    text += "[\(ks.key)]"
                }
            } else if !ks.modifiers.isEmpty {
                // Modifier combo — show as-is
                let mods = ks.modifiers.joined()
                text += "\(mods)\(ks.key)"
            } else {
                text += ks.key
            }
        }
        return text
    }

    /// Check if a keystroke is a form navigation key
    private func isFormNavigationKey(_ ks: KeystrokeLogEvent) -> Bool {
        let navKeys = ["tab", "⇥", "return", "enter", "↩", "escape", "⎋"]
        return ks.isSpecialKey && navKeys.contains(ks.key.lowercased())
    }

    // MARK: - Scroll Aggregation

    private func aggregateScrolls(
        from events: [InteractionEvent],
        startingAt startIdx: Int
    ) -> (AggregatedAction, Int) {
        var scrollEvents: [MouseScrollEvent] = []
        var rawEvents: [InteractionEvent] = []
        var i = startIdx

        while i < events.count {
            guard case .mouseScroll(let scroll) = events[i] else { break }

            if let last = scrollEvents.last {
                let gap = scroll.timestamp - last.timestamp
                if gap > config.scrollMergeThreshold { break }
            }

            scrollEvents.append(scroll)
            rawEvents.append(events[i])
            i += 1
        }

        let consumed = scrollEvents.count
        let firstTs = scrollEvents.first?.timestamp ?? 0
        let lastTs = scrollEvents.last?.timestamp ?? firstTs
        let totalDeltaY = scrollEvents.reduce(0.0) { $0 + $1.deltaY }
        let direction = totalDeltaY < 0 ? "down" : "up"
        let position = scrollEvents.first.map { CGPoint(x: $0.position.x, y: $0.position.y) }

        let action = AggregatedAction(
            actionType: .scroll,
            startTimestamp: firstTs,
            endTimestamp: lastTs,
            description: "Scroll \(direction)",
            position: position,
            rawEvents: rawEvents,
            typedText: nil,
            relatedSpeech: []
        )

        return (action, consumed)
    }

    // MARK: - Form Fill Detection

    /// Detect patterns like: click → type → tab → type → enter
    /// and merge them into a single "formFill" action.
    private func detectFormFillPatterns(in actions: [AggregatedAction]) -> [AggregatedAction] {
        guard actions.count >= 3 else { return actions }

        var result: [AggregatedAction] = []
        var i = 0

        while i < actions.count {
            // Look for: click → type (→ tab/enter → type)+ pattern
            if actions[i].actionType == .click,
               i + 1 < actions.count,
               actions[i + 1].actionType == .type || actions[i + 1].actionType == .keyPress {

                // Count how many type/keyPress actions follow with only tab/enter between them
                var formActions: [AggregatedAction] = [actions[i]]
                var j = i + 1
                var fieldCount = 0

                while j < actions.count {
                    let a = actions[j]
                    if a.actionType == .type {
                        formActions.append(a)
                        fieldCount += 1
                        j += 1
                    } else if a.actionType == .keyPress {
                        // Tab/Enter between fields
                        formActions.append(a)
                        j += 1
                    } else if a.actionType == .click && j + 1 < actions.count &&
                              (actions[j + 1].actionType == .type || actions[j + 1].actionType == .keyPress) {
                        // Click on next field
                        formActions.append(a)
                        j += 1
                    } else {
                        break
                    }
                }

                if fieldCount >= 2 {
                    // This is a form fill pattern — merge into one action
                    let allRaw = formActions.flatMap { $0.rawEvents }
                    let fields = formActions.compactMap { $0.typedText }.filter { !$0.isEmpty }
                    let description = "Fill form (\(fieldCount) fields)"

                    let merged = AggregatedAction(
                        actionType: .formFill,
                        startTimestamp: formActions.first?.startTimestamp ?? 0,
                        endTimestamp: formActions.last?.endTimestamp ?? 0,
                        description: description,
                        position: actions[i].position,
                        rawEvents: allRaw,
                        typedText: fields.joined(separator: " → "),
                        relatedSpeech: []
                    )
                    result.append(merged)
                    i = j
                } else {
                    // Not enough fields — keep as-is
                    result.append(actions[i])
                    i += 1
                }
            } else {
                result.append(actions[i])
                i += 1
            }
        }

        return result
    }

    // MARK: - Speech Correlation

    /// Attach transcript segments to actions whose time ranges overlap.
    private func attachSpeech(
        transcript: SpeechTranscriber.TranscriptResult,
        to actions: [AggregatedAction]
    ) -> [AggregatedAction] {
        guard !transcript.segments.isEmpty else { return actions }

        var updated = actions

        for (i, action) in actions.enumerated() {
            let actionStart = action.startTimestamp
            let actionEnd = action.endTimestamp

            // Find speech segments that overlap with this action's time range
            // Use a wider window to catch narration that starts slightly before/after
            let windowStart = max(0, actionStart - 1.0)
            let windowEnd = actionEnd + 1.0

            let overlapping = transcript.segments.filter { segment in
                segment.startTime < windowEnd && segment.endTime > windowStart
            }

            if !overlapping.isEmpty {
                updated[i].relatedSpeech = overlapping
            }
        }

        return updated
    }
}

// MARK: - Aggregated Action Model

/// A semantic action group produced by EventAggregator.
/// Represents a user-meaningful action (e.g., "Type a URL") rather than raw events.
struct AggregatedAction: Codable {
    enum ActionType: String, Codable {
        case click
        case doubleClick
        case rightClick
        case type           // Sequential typing
        case keyPress       // Single special key (Enter, Tab, etc.)
        case shortcut       // Modifier + key combo (⌘C, ⌘V, etc.)
        case scroll
        case drag
        case formFill       // Multi-field form interaction
    }

    let actionType: ActionType
    let startTimestamp: TimeInterval
    let endTimestamp: TimeInterval
    var description: String
    let position: CGPoint?              // Primary interaction location (for bounding box)
    let rawEvents: [InteractionEvent]   // The raw events that were aggregated
    let typedText: String?              // For type/formFill actions, the actual text typed
    var relatedSpeech: [SpeechTranscriber.TranscriptSegment]  // Speech during this action
    var sequenceNumber: Int = 0         // Assigned after aggregation

    /// The number of raw events that were combined into this action
    var rawEventCount: Int { rawEvents.count }

    /// The best frame timestamp to use for this action (midpoint for typing, start for clicks)
    var bestFrameTimestamp: TimeInterval {
        switch actionType {
        case .type, .formFill, .scroll:
            // Use the midpoint — shows the action in progress
            return (startTimestamp + endTimestamp) / 2.0
        default:
            // Use the exact moment for discrete actions
            return startTimestamp
        }
    }

    /// Human-readable summary including speech context
    var fullSummary: String {
        var summary = description
        if let text = typedText, !text.isEmpty {
            summary += ": \"\(text)\""
        }
        if !relatedSpeech.isEmpty {
            let speech = relatedSpeech.map { $0.text }.joined(separator: " ")
            summary += " [Narration: \"\(speech)\"]"
        }
        return summary
    }
}
