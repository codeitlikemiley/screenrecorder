import Foundation
import AppKit
import ImageIO

/// Converts a RecordingSession into structured workflow steps using an AI provider.
///
/// The model gets the grouped actions (numbered ACTION_n), the narration as timestamped
/// utterances, and one screenshot per selected action, each preceded by a caption naming the
/// action it shows. It answers in JSON; each step names the ACTION_n it covers so screenshots,
/// timestamps and click positions are attached deterministically rather than guessed.
class StepGenerator {
    private let aiService: AIService

    /// Screenshots sent per request.
    private let maxImages = 15
    /// Longest edge of screenshots sent to the model.
    private let imageMaxDimension: CGFloat = 1280
    /// Narration characters included in the prompt.
    private let maxNarrationCharacters = 8000

    init(aiService: AIService) {
        self.aiService = aiService
    }

    // MARK: - Generate Steps

    func generate(
        from session: RecordingSession,
        framesDirectory: URL,
        aggregatedActions: [AggregatedAction]? = nil
    ) async throws -> GeneratedWorkflow {
        guard aiService.isConfigured else {
            throw AIError.notConfigured("AI service not configured. Add your API key in Settings → AI.")
        }

        print("🧠 Generating workflow steps from session...")
        let actions = aggregatedActions ?? session.aggregatedActions ?? []

        // 1. Pick screenshots first so the prompt only references images that are really sent.
        let attachments = selectAttachments(actions: actions, session: session, framesDirectory: framesDirectory)

        // 2. Build the prompt
        let prompt = buildPrompt(from: session, actions: actions, attachments: attachments)

        // 3. Call AI
        let request = AIRequest(
            prompt: prompt,
            images: attachments.map(\.data),
            imageLabels: attachments.map(\.caption)
        )
        print("  📸 Sending \(attachments.count) screenshots to \(aiService.providerName)")
        let responseText = try await aiService.complete(request)

        // 4. Parse (JSON first, legacy marker format as a fallback)
        let workflow = parseResponse(responseText, session: session, actions: actions, model: aiService.providerName)
        print("🧠 Generated: \"\(workflow.title)\" — \(workflow.steps.count) steps")
        return workflow
    }

    // MARK: - Attachments

    private struct Attachment {
        let imageNumber: Int
        let actionIndex: Int?   // nil for the final "end" frame
        let data: Data
        let caption: String
    }

    private func selectAttachments(
        actions: [AggregatedAction],
        session: RecordingSession,
        framesDirectory: URL
    ) -> [Attachment] {
        var candidates: [(actionIndex: Int?, frame: RecordingSession.FrameReference)] = []

        if !actions.isEmpty {
            for action in actions {
                if let frame = frame(for: action, in: session.frames) {
                    candidates.append((action.sequenceNumber, frame))
                }
            }
            candidates = KeyFrameExtractor.evenlySample(candidates, count: maxImages - 1)
            if let end = session.frames.last(where: { $0.trigger == "end" }) {
                candidates.append((nil, end))
            }
        } else {
            candidates = KeyFrameExtractor.evenlySample(session.frames, count: maxImages).map { (nil, $0) }
        }

        var attachments: [Attachment] = []
        var usedFiles = Set<String>()
        for candidate in candidates where !usedFiles.contains(candidate.frame.filename) {
            let url = framesDirectory.appendingPathComponent(candidate.frame.filename)
            guard let data = loadForUpload(url) else { continue }
            usedFiles.insert(candidate.frame.filename)
            let number = attachments.count + 1
            let caption: String
            if let index = candidate.actionIndex {
                caption = "Image \(number): screen at ACTION_\(index) (t=\(formatTimestamp(candidate.frame.timestamp)))"
            } else if candidate.frame.trigger == "end" {
                caption = "Image \(number): final screen at the end of the recording"
            } else {
                caption = "Image \(number): screen at t=\(formatTimestamp(candidate.frame.timestamp))"
            }
            attachments.append(Attachment(imageNumber: number, actionIndex: candidate.actionIndex, data: data, caption: caption))
        }
        return attachments
    }

    /// Load an image and re-encode it as a JPEG no larger than `imageMaxDimension`.
    private func loadForUpload(_ url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: imageMaxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: - Prompt Construction

    private func buildPrompt(from session: RecordingSession, actions: [AggregatedAction], attachments: [Attachment]) -> String {
        let imageForAction = Dictionary(
            attachments.compactMap { a in a.actionIndex.map { ($0, a.imageNumber) } },
            uniquingKeysWith: { first, _ in first }
        )

        var prompt = """
        You turn screen recordings into clear, step-by-step instructions.

        The recording is \(formatDuration(session.duration)) long. Below are the user's actions (already \
        grouped: keystrokes into typed text, repeated scrolls into one), what they said while recording, \
        and screenshots. Each screenshot is preceded by a caption naming the action it shows.

        """

        if !actions.isEmpty {
            prompt += "\n## Actions\n"
            for action in actions {
                let index = action.sequenceNumber
                prompt += "ACTION_\(index) [\(action.actionType.rawValue)] t=\(formatTimestamp(action.startTimestamp))"
                if action.endTimestamp > action.startTimestamp + 0.5 {
                    prompt += "–\(formatTimestamp(action.endTimestamp))"
                }
                prompt += " | \(SecretRedactor.redact(action.description))"
                if let text = action.typedText, !text.isEmpty, action.actionType != .shortcut {
                    prompt += " | typed=\"\(SecretRedactor.redact(text))\""
                }
                if let image = imageForAction[index] {
                    prompt += " | see Image \(image)"
                }
                prompt += "\n"
            }
        } else {
            prompt += """

            ## Actions
            No input events were logged; rely on the screenshots and narration.
            Clicks: \(session.eventSummary.mouseClicks), keystrokes: \(session.eventSummary.keystrokes), \
            scrolls: \(session.eventSummary.scrolls), drags: \(session.eventSummary.drags).

            """
        }

        if let transcript = session.transcript, !transcript.fullText.isEmpty {
            prompt += "\n## Narration (what the user said, with start times)\n"
            var used = 0
            for segment in transcript.segments {
                let line = "- [\(formatTimestamp(segment.startTime))] \(SecretRedactor.redact(segment.text))\n"
                if used + line.count > maxNarrationCharacters {
                    prompt += "- … (narration truncated)\n"
                    break
                }
                prompt += line
                used += line.count
            }
        }

        prompt += """

        ## What to produce
        - A short title (max 10 words) and a one-line summary.
        - Steps a person could follow to repeat this workflow. Usually one step per meaningful action; \
        merge rapid actions that serve one goal (e.g. "Fill in the login form") and skip noise.
        - Use the narration to explain *why* a step is done when the user said so.
        - Name UI elements you can see in the screenshots (button labels, menu names, fields).
        - Don't copy secrets, passwords or personal data into steps; describe them ("Enter your API key").
        - An ai_agent_prompt: instructions an AI agent could follow to reproduce the workflow.

        ## Output
        Reply with only this JSON object, no prose and no code fences:
        {
          "title": "string",
          "summary": "string",
          "steps": [
            {
              "action_type": "click | doubleClick | rightClick | type | drag | scroll | navigate | wait | observe | speak",
              "title": "short imperative title",
              "description": "what to do and why",
              "ui_element": "visible UI element, or null",
              "action_index": "number n of the ACTION_n this step covers, or null"
            }
          ],
          "ai_agent_prompt": "string"
        }
        """
        return prompt
    }

    // MARK: - Parse Response

    private struct ResponseJSON: Decodable {
        struct Step: Decodable {
            let action_type: String?
            let title: String?
            let description: String?
            let ui_element: String?
            let action_index: FlexibleInt?
        }
        let title: String?
        let summary: String?
        let steps: [Step]?
        let ai_agent_prompt: String?
    }

    /// Accepts 3, "3", "ACTION_3" or null.
    private struct FlexibleInt: Decodable {
        let value: Int?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let int = try? container.decode(Int.self) {
                value = int
            } else if let string = try? container.decode(String.self) {
                value = Int(string.filter(\.isNumber))
            } else {
                value = nil
            }
        }
    }

    private func parseResponse(_ text: String, session: RecordingSession, actions: [AggregatedAction], model: String) -> GeneratedWorkflow {
        if let json = decodeJSON(text) {
            let steps = (json.steps ?? []).enumerated().map { offset, step in
                makeStep(
                    number: offset + 1,
                    actionType: step.action_type,
                    title: step.title ?? "Step \(offset + 1)",
                    description: step.description ?? step.title ?? "",
                    uiElement: step.ui_element,
                    actionIndex: step.action_index?.value,
                    session: session,
                    actions: actions
                )
            }
            return GeneratedWorkflow(
                title: json.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Untitled Workflow",
                summary: json.summary ?? "",
                steps: steps,
                aiAgentPrompt: json.ai_agent_prompt,
                modelUsed: model
            )
        }

        print("  ⚠️ AI reply was not valid JSON — falling back to the marker format")
        return parseLegacyResponse(text, session: session, actions: actions, model: model)
    }

    /// Extract the outermost JSON object, tolerating code fences or stray prose around it.
    private func decodeJSON(_ text: String) -> ResponseJSON? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        let data = Data(text[start...end].utf8)
        return try? JSONDecoder().decode(ResponseJSON.self, from: data)
    }

    private func makeStep(
        number: Int,
        actionType: String?,
        title: String,
        description: String,
        uiElement: String?,
        actionIndex: Int?,
        session: RecordingSession,
        actions: [AggregatedAction]
    ) -> WorkflowStep {
        let type = actionType.flatMap { raw in
            WorkflowStep.ActionType(rawValue: raw) ?? WorkflowStep.ActionType.allCases.first { $0.rawValue.lowercased() == raw.lowercased() }
        } ?? .observe

        var frame: RecordingSession.FrameReference?
        var position: CodablePoint?
        var start: TimeInterval = 0
        var end: TimeInterval?
        var validIndex: Int?

        if let actionIndex, let action = actions.first(where: { $0.sequenceNumber == actionIndex }) {
            validIndex = actionIndex
            start = action.startTimestamp
            end = action.endTimestamp > action.startTimestamp ? action.endTimestamp : nil
            frame = self.frame(for: action, in: session.frames)
            position = action.position.map(CodablePoint.init)
        }

        let element = uiElement?.trimmingCharacters(in: .whitespaces)
        return WorkflowStep(
            stepNumber: number,
            title: title,
            description: description,
            screenshotFile: frame?.filename,
            timestampStart: start,
            timestampEnd: end,
            actionType: type,
            uiElement: (element?.isEmpty ?? true) || element?.lowercased() == "none" || element?.lowercased() == "null" ? nil : element,
            interactionPosition: position,
            actionIndex: validIndex
        )
    }

    /// The frame captured for `action` (by index), else the nearest one in time.
    private func frame(for action: AggregatedAction, in frames: [RecordingSession.FrameReference]) -> RecordingSession.FrameReference? {
        if let exact = frames.first(where: { $0.actionIndex == action.sequenceNumber }) {
            return exact
        }
        return frames.min { abs($0.timestamp - action.bestFrameTimestamp) < abs($1.timestamp - action.bestFrameTimestamp) }
    }

    // MARK: - Legacy marker format

    private func parseLegacyResponse(_ text: String, session: RecordingSession, actions: [AggregatedAction], model: String) -> GeneratedWorkflow {
        let title = extractSection(from: text, start: "---TITLE---", end: "---SUMMARY---")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Untitled Workflow"
        let summary = extractSection(from: text, start: "---SUMMARY---", end: "---STEPS---")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stepsText = extractSection(from: text, start: "---STEPS---", end: "---AI_AGENT_PROMPT---") ?? ""
        let aiPrompt = extractSection(from: text, start: "---AI_AGENT_PROMPT---", end: "---END---")?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var steps: [WorkflowStep] = []
        for line in stepsText.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            guard let dot = line.firstIndex(of: "."), Int(line[..<dot].trimmingCharacters(in: .whitespaces)) != nil else { continue }
            var rest = String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
            var type: String?
            if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                type = String(rest[rest.index(after: rest.startIndex)..<close])
                rest = String(rest[rest.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
            let parts = rest.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            let number = steps.count + 1
            steps.append(makeStep(
                number: number,
                actionType: type,
                title: parts.first ?? "Step \(number)",
                description: parts.count > 1 ? parts[1] : (parts.first ?? ""),
                uiElement: parts.count > 2 ? parts[2] : nil,
                actionIndex: parts.count > 3 ? Int(parts[3].filter(\.isNumber)) : nil,
                session: session,
                actions: actions
            ))
        }
        return GeneratedWorkflow(title: title, summary: summary, steps: steps, aiAgentPrompt: aiPrompt, modelUsed: model)
    }

    private func extractSection(from text: String, start: String, end: String) -> String? {
        guard let startRange = text.range(of: start) else { return nil }
        let afterStart = text[startRange.upperBound...]
        if let endRange = afterStart.range(of: end) {
            return String(afterStart[..<endRange.lowerBound])
        }
        return String(afterStart)
    }

    // MARK: - Formatting Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        String(format: "%d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }
}

// MARK: - Secret redaction

/// Masks strings that look like credentials before they leave the machine.
/// Raw keystrokes stay in the local metadata file; only what is sent to the AI is redacted.
enum SecretRedactor {
    private static let patterns: [NSRegularExpression] = [
        #"sk-[A-Za-z0-9_\-]{16,}"#,                         // OpenAI / Anthropic style keys
        #"(?:ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}"#, // GitHub tokens
        #"AKIA[0-9A-Z]{16}"#,                               // AWS access key IDs
        #"xox[abprs]-[A-Za-z0-9\-]{10,}"#,                  // Slack tokens
        #"AIza[0-9A-Za-z_\-]{35}"#,                         // Google API keys
        #"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#, // JWTs
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// Long unbroken runs mixing letters and digits (random-looking tokens).
    private static let tokenLike = try? NSRegularExpression(pattern: #"[A-Za-z0-9_\-+/=]{28,}"#)

    static func redact(_ text: String) -> String {
        var result = text
        for pattern in patterns {
            result = pattern.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "[redacted]"
            )
        }
        if let tokenLike {
            let matches = tokenLike.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for match in matches {
                guard let range = Range(match.range, in: result) else { continue }
                let candidate = result[range]
                let hasLetter = candidate.contains(where: \.isLetter)
                let hasDigit = candidate.contains(where: \.isNumber)
                if (hasLetter && hasDigit && !candidate.contains("/")) || (candidate.count >= 40 && hasDigit) {
                    result.replaceSubrange(range, with: "[redacted]")
                }
            }
        }
        return result
    }
}
