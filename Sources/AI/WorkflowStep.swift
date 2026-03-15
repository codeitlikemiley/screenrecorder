import Foundation
import CoreGraphics

/// A Codable wrapper for CGPoint, since CGPoint's Codable conformance
/// is not always reliable across frameworks.
struct CodablePoint: Codable {
    let x: CGFloat
    let y: CGFloat

    init(_ point: CGPoint) {
        self.x = point.x
        self.y = point.y
    }

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

/// A single step in a generated workflow.
/// Produced by the AI StepGenerator from recording session data.
struct WorkflowStep: Codable, Identifiable {
    let id: UUID
    var stepNumber: Int
    var title: String              // e.g. "Click the Settings gear icon"
    var description: String        // Detailed instruction text
    var screenshotFile: String?           // Reference to key frame PNG
    var annotatedScreenshotFile: String?  // Reference to annotated version with bounding boxes
    var timestampStart: TimeInterval
    var timestampEnd: TimeInterval?
    var actionType: ActionType
    var uiElement: String?                // The UI element involved (e.g. "Settings button", "Search field")
    var interactionPosition: CodablePoint? // Screen coordinates where the interaction occurred

    enum ActionType: String, Codable {
        case click
        case doubleClick
        case rightClick
        case type
        case drag
        case scroll
        case navigate
        case wait
        case observe
        case speak           // Narration / voice instruction
    }

    init(
        stepNumber: Int,
        title: String,
        description: String,
        screenshotFile: String? = nil,
        annotatedScreenshotFile: String? = nil,
        timestampStart: TimeInterval,
        timestampEnd: TimeInterval? = nil,
        actionType: ActionType = .click,
        uiElement: String? = nil,
        interactionPosition: CodablePoint? = nil
    ) {
        self.id = UUID()
        self.stepNumber = stepNumber
        self.title = title
        self.description = description
        self.screenshotFile = screenshotFile
        self.annotatedScreenshotFile = annotatedScreenshotFile
        self.timestampStart = timestampStart
        self.timestampEnd = timestampEnd
        self.actionType = actionType
        self.uiElement = uiElement
        self.interactionPosition = interactionPosition
    }
}

/// The complete output of AI step generation — steps + optional AI agent prompt.
struct GeneratedWorkflow: Codable {
    let title: String              // AI-generated workflow title
    let summary: String            // One-line summary
    let steps: [WorkflowStep]
    let aiAgentPrompt: String?     // Formatted prompt for coding agents
    let generatedAt: Date
    let modelUsed: String

    init(
        title: String,
        summary: String,
        steps: [WorkflowStep],
        aiAgentPrompt: String?,
        modelUsed: String
    ) {
        self.title = title
        self.summary = summary
        self.steps = steps
        self.aiAgentPrompt = aiAgentPrompt
        self.generatedAt = Date()
        self.modelUsed = modelUsed
    }

    /// Save workflow to JSON alongside the recording
    func save(in directory: URL, baseName: String) throws -> URL {
        let filename = "\(baseName)_workflow.json"
        let url = directory.appendingPathComponent(filename)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)

        print("📝 Workflow saved: \(filename) (\(steps.count) steps)")
        return url
    }
}
