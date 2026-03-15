import Foundation
import AppKit

/// Converts a RecordingSession into structured workflow steps using an AI provider.
/// Uses aggregated actions (from EventAggregator) for better context and deterministic frame mapping.
class StepGenerator {
    private let aiService: AIService

    init(aiService: AIService) {
        self.aiService = aiService
    }

    // MARK: - Generate Steps

    /// Generate a workflow from a recording session.
    /// Uses aggregated actions for better step quality and frame mapping.
    func generate(
        from session: RecordingSession,
        framesDirectory: URL,
        aggregatedActions: [AggregatedAction]? = nil
    ) async throws -> GeneratedWorkflow {
        guard aiService.isConfigured else {
            throw AIError.notConfigured("AI service not configured. Add your API key in Settings → AI.")
        }

        print("🧠 Generating workflow steps from session...")

        // Use aggregated actions if available, otherwise fall back to basic prompt
        let actions = aggregatedActions ?? session.aggregatedActions ?? []

        // 1. Build the prompt
        let prompt = buildPrompt(from: session, actions: actions)

        // 2. Prepare images — one per aggregated action for precise mapping
        let imageData = loadActionFrames(
            actions: actions,
            session: session,
            framesDirectory: framesDirectory,
            maxImages: 15
        )

        // 3. Call AI
        let responseText = try await aiService.complete(AIRequest(prompt: prompt, images: imageData))

        // 4. Parse response into structured steps with deterministic frame assignment
        let workflow = parseResponse(responseText, session: session, actions: actions, model: aiService.providerName)

        print("🧠 Generated: \"\(workflow.title)\" — \(workflow.steps.count) steps")
        return workflow
    }

    // MARK: - Prompt Construction

    private func buildPrompt(from session: RecordingSession, actions: [AggregatedAction]) -> String {
        var prompt = """
        You are an expert at analyzing screen recordings and generating clear, step-by-step instructions.
        
        I recorded a \(formatDuration(session.duration)) screen recording. Below is the structured interaction data captured during the session.
        
        ## Instructions
        
        Analyze the aggregated actions and screenshots, then generate:
        1. A short TITLE for this workflow (max 10 words)
        2. A one-line SUMMARY
        3. Numbered STEPS — one step per aggregated action (or merge/skip trivial ones)
        4. An AI_AGENT_PROMPT that a coding AI could use to replicate the workflow
        
        """

        if !actions.isEmpty {
            prompt += """
            ## Aggregated Actions (\(actions.count) semantic actions from \(session.eventSummary.totalEvents) raw events)
            
            Each action below represents a meaningful user interaction (sequential keystrokes are already grouped, scrolls merged, etc.):
            
            """

            for (i, action) in actions.enumerated() {
                prompt += "ACTION_\(i + 1) [\(action.actionType.rawValue)] "
                prompt += "t=\(formatTimestamp(action.startTimestamp))"
                if action.endTimestamp > action.startTimestamp {
                    prompt += "→\(formatTimestamp(action.endTimestamp))"
                }
                prompt += " | \(action.description)"

                if let text = action.typedText, !text.isEmpty {
                    prompt += " | typed=\"\(text)\""
                }
                if let pos = action.position {
                    prompt += " | pos=(\(Int(pos.x)),\(Int(pos.y)))"
                }
                if !action.relatedSpeech.isEmpty {
                    let speech = action.relatedSpeech.map { $0.text }.joined(separator: " ")
                    prompt += " | narration=\"\(speech)\""
                }
                prompt += " [image_\(i + 1)]\n"
            }
            prompt += "\n"
        } else {
            // Fallback: no aggregated actions, use event summary
            prompt += """
            ## Interaction Events (\(session.eventSummary.totalEvents) total)
            - Mouse clicks: \(session.eventSummary.mouseClicks)
            - Keystrokes: \(session.eventSummary.keystrokes)
            - Scrolls: \(session.eventSummary.scrolls)
            - Drags: \(session.eventSummary.drags)
            
            """
        }

        // Add transcript if available
        if let transcript = session.transcript, !transcript.fullText.isEmpty {
            prompt += """
            
            ## Speech Narration
            \(transcript.fullText)
            
            """

            if !transcript.segments.isEmpty {
                prompt += "### Timestamped Segments\n"
                for segment in transcript.segments.prefix(50) {
                    prompt += "- [\(formatTimestamp(segment.startTime))] \(segment.text)\n"
                }
                prompt += "\n"
            }
        }

        // Add frame references
        if !session.frames.isEmpty {
            prompt += "## Key Frames Captured\n"
            for frame in session.frames.prefix(20) {
                prompt += "- [\(formatTimestamp(frame.timestamp))] \(frame.trigger) → \(frame.filename)\n"
            }
            prompt += "\n"
        }

        // Output format
        prompt += """
        
        ## Output Format
        
        Respond in EXACTLY this format (including the markers):
        
        ---TITLE---
        <workflow title>
        ---SUMMARY---
        <one-line summary>
        ---STEPS---
        1. [ACTION_TYPE] <Title> | <Detailed description> | <ui_element or "none"> | <ACTION_INDEX>
        2. [ACTION_TYPE] <Title> | <Detailed description> | <ui_element or "none"> | <ACTION_INDEX>
        ...
        ---AI_AGENT_PROMPT---
        <A well-structured prompt that a coding AI agent could use to implement or reproduce this workflow>
        ---END---
        
        Valid ACTION_TYPE values: click, doubleClick, rightClick, type, drag, scroll, navigate, wait, observe, speak
        
        Rules:
        - The ACTION_INDEX should reference which ACTION_# from the list above this step corresponds to (e.g., "1", "2", "3"). Use "0" if it doesn't map to a specific action.
        - Each step should be a meaningful, user-facing action — NOT a low-level event.
        - Use GENERIC descriptions: say "Navigate to the repository page" NOT "Navigate to https://github.com/user/repo". Say "Enter the search query" NOT "Type 'specific text'". Reference what the user is doing conceptually, not the exact values.
        - For typing steps, mention what is being typed conceptually (e.g., "Enter the installation command"), not the literal text.
        - Group rapid sequential actions if they accomplish one goal (e.g., "Fill in the login form" instead of separate steps for each field).
        - If the user is narrating (speech segments are provided), incorporate their explanation into the step description.
        - Mention specific UI elements when visible in screenshots (buttons, menus, text fields).
        - If screenshots show code, reference specific file names and line numbers.
        - The AI agent prompt should be detailed enough for an AI to implement the feature or fix shown.
        """

        return prompt
    }

    // MARK: - Load Action Frames

    /// Load one frame per aggregated action for precise step-to-frame mapping.
    private func loadActionFrames(
        actions: [AggregatedAction],
        session: RecordingSession,
        framesDirectory: URL,
        maxImages: Int
    ) -> [Data] {
        var imageData: [Data] = []

        if !actions.isEmpty {
            // Send the frame closest to each aggregated action's best timestamp
            let actionsToSend = selectDistributedItems(actions, count: maxImages)

            for action in actionsToSend {
                let targetTs = action.bestFrameTimestamp
                if let frame = findNearestFrame(to: targetTs, in: session.frames) {
                    let imageURL = framesDirectory.appendingPathComponent(frame.filename)
                    if let data = loadAndResize(imageURL) {
                        imageData.append(data)
                    }
                }
            }
        } else {
            // Fallback: distributed frames
            let framesToSend = selectDistributedItems(session.frames, count: maxImages)
            for frame in framesToSend {
                let imageURL = framesDirectory.appendingPathComponent(frame.filename)
                if let data = loadAndResize(imageURL) {
                    imageData.append(data)
                }
            }
        }

        print("  📸 Sending \(imageData.count) key frames to AI")
        return imageData
    }

    private func loadAndResize(_ url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.count > 512_000, let downsized = downsizeImage(data, maxDimension: 1024) {
            return downsized
        }
        return data
    }

    /// Select items distributed across the array
    private func selectDistributedItems<T>(_ items: [T], count: Int) -> [T] {
        guard items.count > count else { return items }
        let step = items.count / count
        return stride(from: 0, to: items.count, by: step).prefix(count).map { items[$0] }
    }

    /// Downsize a PNG to reduce API payload
    private func downsizeImage(_ data: Data, maxDimension: CGFloat) -> Data? {
        guard let nsImage = NSImage(data: data) else { return nil }
        let size = nsImage.size
        let scale = min(maxDimension / max(size.width, size.height), 1.0)
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)

        let resized = NSImage(size: newSize)
        resized.lockFocus()
        nsImage.draw(in: NSRect(origin: .zero, size: newSize),
                     from: NSRect(origin: .zero, size: size),
                     operation: .copy,
                     fraction: 1.0)
        resized.unlockFocus()

        guard let tiff = resized.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [.compressionFactor: 0.8]) else {
            return nil
        }

        return png
    }

    // MARK: - Parse Response

    private func parseResponse(
        _ text: String,
        session: RecordingSession,
        actions: [AggregatedAction],
        model: String
    ) -> GeneratedWorkflow {
        let title = extractSection(from: text, start: "---TITLE---", end: "---SUMMARY---")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Untitled Workflow"

        let summary = extractSection(from: text, start: "---SUMMARY---", end: "---STEPS---")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let stepsText = extractSection(from: text, start: "---STEPS---", end: "---AI_AGENT_PROMPT---") ?? ""
        let steps = parseSteps(stepsText, frames: session.frames, actions: actions)

        let aiPrompt = extractSection(from: text, start: "---AI_AGENT_PROMPT---", end: "---END---")?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return GeneratedWorkflow(
            title: title,
            summary: summary,
            steps: steps,
            aiAgentPrompt: aiPrompt,
            modelUsed: model
        )
    }

    private func extractSection(from text: String, start: String, end: String) -> String? {
        guard let startRange = text.range(of: start) else { return nil }
        let afterStart = text[startRange.upperBound...]

        if let endRange = afterStart.range(of: end) {
            return String(afterStart[..<endRange.lowerBound])
        }
        return String(afterStart)
    }

    private func parseSteps(
        _ text: String,
        frames: [RecordingSession.FrameReference],
        actions: [AggregatedAction]
    ) -> [WorkflowStep] {
        var steps: [WorkflowStep] = []

        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for line in lines {
            // Match pattern: "1. [click] Title | Description | ui_element | ACTION_INDEX"
            guard let dotIndex = line.firstIndex(of: ".") else { continue }
            let numberStr = String(line[line.startIndex..<dotIndex]).trimmingCharacters(in: .whitespaces)
            guard let stepNumber = Int(numberStr) else { continue }

            let rest = String(line[line.index(after: dotIndex)...]).trimmingCharacters(in: .whitespaces)

            // Extract action type from brackets
            var actionType: WorkflowStep.ActionType = .click
            var content = rest
            if let openBracket = rest.firstIndex(of: "["),
               let closeBracket = rest.firstIndex(of: "]"),
               openBracket < closeBracket {
                let typeStr = String(rest[rest.index(after: openBracket)..<closeBracket]).lowercased()
                actionType = WorkflowStep.ActionType(rawValue: typeStr) ?? .click
                content = String(rest[rest.index(after: closeBracket)...]).trimmingCharacters(in: .whitespaces)
            }

            // Split by pipe separator
            let parts = content.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }

            let title = parts.count > 0 ? parts[0] : "Step \(stepNumber)"
            let description = parts.count > 1 ? parts[1] : title
            let uiElement = parts.count > 2 && parts[2].lowercased() != "none" ? parts[2] : nil

            // Parse ACTION_INDEX (last field) — maps to aggregated actions
            let actionIndexStr = parts.count > 3 ? parts[3] : "0"
            let actionIndex = Int(actionIndexStr) ?? 0

            // Determine frame and position from the matching aggregated action
            var matchingFrame: RecordingSession.FrameReference?
            var interactionPosition: CodablePoint?
            var timestampStart: TimeInterval = 0
            var timestampEnd: TimeInterval?

            if actionIndex > 0 && actionIndex <= actions.count {
                let action = actions[actionIndex - 1]
                timestampStart = action.startTimestamp
                timestampEnd = action.endTimestamp > action.startTimestamp ? action.endTimestamp : nil
                matchingFrame = findNearestFrame(to: action.bestFrameTimestamp, in: frames)
                if let pos = action.position {
                    interactionPosition = CodablePoint(pos)
                }
            } else {
                // Fallback: try to parse timestamp or use position in step list
                if let parsedTs = Double(actionIndexStr) {
                    timestampStart = parsedTs
                }
                matchingFrame = findNearestFrame(to: timestampStart, in: frames)
            }

            let step = WorkflowStep(
                stepNumber: stepNumber,
                title: title,
                description: description,
                screenshotFile: matchingFrame?.filename,
                timestampStart: timestampStart,
                timestampEnd: timestampEnd,
                actionType: actionType,
                uiElement: uiElement,
                interactionPosition: interactionPosition
            )
            steps.append(step)
        }

        return steps
    }

    private func findNearestFrame(
        to timestamp: TimeInterval,
        in frames: [RecordingSession.FrameReference]
    ) -> RecordingSession.FrameReference? {
        frames.min(by: { abs($0.timestamp - timestamp) < abs($1.timestamp - timestamp) })
    }

    // MARK: - Formatting Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins > 0 {
            return "\(mins)m \(secs)s"
        }
        return "\(secs)s"
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
