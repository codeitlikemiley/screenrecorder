import Foundation
import AppKit

/// Converts a RecordingSession into structured workflow steps using an AI provider.
/// Handles prompt construction, image preparation, AI invocation, and response parsing.
class StepGenerator {
    private let aiService: AIService

    init(aiService: AIService) {
        self.aiService = aiService
    }

    // MARK: - Generate Steps

    /// Generate a workflow from a recording session.
    /// Sends interaction metadata, transcript, and key frame screenshots to the AI.
    func generate(from session: RecordingSession, framesDirectory: URL) async throws -> GeneratedWorkflow {
        guard aiService.isConfigured else {
            throw AIError.notConfigured("AI service not configured. Add your API key in Settings → AI.")
        }

        print("🧠 Generating workflow steps from session...")

        // 1. Build the prompt
        let prompt = buildPrompt(from: session)

        // 2. Prepare key frame images (up to 10 for cost/context reasons)
        let imageData = loadKeyFrames(from: session, framesDirectory: framesDirectory, maxImages: 10)

        // 3. Call AI
        let responseText = try await aiService.complete(AIRequest(prompt: prompt, images: imageData))

        // 4. Parse response into structured steps
        let workflow = parseResponse(responseText, session: session, model: aiService.providerName)

        print("🧠 Generated: \"\(workflow.title)\" — \(workflow.steps.count) steps")
        return workflow
    }

    // MARK: - Prompt Construction

    private func buildPrompt(from session: RecordingSession) -> String {
        var prompt = """
        You are an expert at analyzing screen recordings and generating clear, step-by-step instructions.

        I recorded a \(formatDuration(session.duration)) screen recording. Below is the structured interaction data captured during the session. Analyze it and generate:

        1. A short TITLE for this workflow (max 10 words)
        2. A one-line SUMMARY
        3. Numbered STEPS with clear, actionable instructions
        4. An AI_AGENT_PROMPT that a coding AI could use to replicate the workflow

        ## Interaction Events (\(session.eventSummary.totalEvents) total)
        - Mouse clicks: \(session.eventSummary.mouseClicks)
        - Keystrokes: \(session.eventSummary.keystrokes)
        - Scrolls: \(session.eventSummary.scrolls)
        - Drags: \(session.eventSummary.drags)

        """

        // Add transcript if available
        if let transcript = session.transcript, !transcript.fullText.isEmpty {
            prompt += """

            ## Speech Narration
            \(transcript.fullText)

            """

            // Add timestamped segments for context
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

        // Add the output format instructions
        prompt += """

        ## Output Format

        Respond in EXACTLY this format (including the markers):

        ---TITLE---
        <workflow title>
        ---SUMMARY---
        <one-line summary>
        ---STEPS---
        1. [ACTION_TYPE] <Title> | <Detailed description> | <ui_element or "none"> | <start_timestamp>
        2. [ACTION_TYPE] <Title> | <Detailed description> | <ui_element or "none"> | <start_timestamp>
        ...
        ---AI_AGENT_PROMPT---
        <A well-structured prompt that a coding AI agent (like Cursor, Codex, or Copilot) could use to implement or reproduce the workflow shown in this recording. Include specific UI elements, interactions, and expected outcomes.>
        ---END---

        Valid ACTION_TYPE values: click, doubleClick, rightClick, type, drag, scroll, navigate, wait, observe, speak

        Rules:
        - Each step should be a single atomic action
        - Use timestamps from the interaction data to order steps
        - Group rapid sequential keystrokes into a single "type" step with the full text
        - Mention specific UI elements when visible in screenshots
        - The AI agent prompt should be detailed enough for an AI to implement the feature or fix shown
        - If screenshots show code, reference specific file names and line numbers
        """

        return prompt
    }

    // MARK: - Load Key Frames

    private func loadKeyFrames(from session: RecordingSession, framesDirectory: URL, maxImages: Int) -> [Data] {
        var imageData: [Data] = []

        // Select a subset of frames distributed across the session
        let framesToSend = selectDistributedFrames(session.frames, count: maxImages)

        for frame in framesToSend {
            let imageURL = framesDirectory.appendingPathComponent(frame.filename)
            if let data = try? Data(contentsOf: imageURL) {
                // Downscale if too large (keep under 512KB per image for API efficiency)
                if data.count > 512_000, let downsized = downsizeImage(data, maxDimension: 1024) {
                    imageData.append(downsized)
                } else {
                    imageData.append(data)
                }
            }
        }

        print("  📸 Sending \(imageData.count) key frames to AI")
        return imageData
    }

    /// Select frames distributed across the timeline rather than clustered
    private func selectDistributedFrames(_ frames: [RecordingSession.FrameReference], count: Int) -> [RecordingSession.FrameReference] {
        guard frames.count > count else { return frames }

        let step = frames.count / count
        return stride(from: 0, to: frames.count, by: step).prefix(count).map { frames[$0] }
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

    private func parseResponse(_ text: String, session: RecordingSession, model: String) -> GeneratedWorkflow {
        // Extract sections using markers
        let title = extractSection(from: text, start: "---TITLE---", end: "---SUMMARY---")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Untitled Workflow"

        let summary = extractSection(from: text, start: "---SUMMARY---", end: "---STEPS---")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let stepsText = extractSection(from: text, start: "---STEPS---", end: "---AI_AGENT_PROMPT---") ?? ""
        let steps = parseSteps(stepsText, frames: session.frames)

        let aiPrompt = extractSection(from: text, start: "---AI_AGENT_PROMPT---", end: "---END---")?.trimmingCharacters(in: .whitespacesAndNewlines)

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
        // If no end marker found, take everything after start
        return String(afterStart)
    }

    private func parseSteps(_ text: String, frames: [RecordingSession.FrameReference]) -> [WorkflowStep] {
        var steps: [WorkflowStep] = []

        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for line in lines {
            // Match pattern: "1. [click] Title | Description | ui_element | timestamp"
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
            let timestamp = parts.count > 3 ? (Double(parts[3]) ?? 0) : 0

            // Find a matching frame near this timestamp
            let matchingFrame = findNearestFrame(to: timestamp, in: frames)

            let step = WorkflowStep(
                stepNumber: stepNumber,
                title: title,
                description: description,
                screenshotFile: matchingFrame?.filename,
                timestampStart: timestamp,
                actionType: actionType,
                uiElement: uiElement
            )
            steps.append(step)
        }

        return steps
    }

    private func findNearestFrame(to timestamp: TimeInterval, in frames: [RecordingSession.FrameReference]) -> RecordingSession.FrameReference? {
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
