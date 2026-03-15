import Foundation
import SwiftUI
import AppKit

/// View model that loads and manages a complete recording session for the review UI.
@MainActor
class SessionViewerModel: ObservableObject {
    @Published var session: RecordingSession?
    @Published var workflow: GeneratedWorkflow?
    @Published var steps: [WorkflowStep] = []
    @Published var selectedStepIndex: Int? = nil
    @Published var showAnnotated: Bool = true  // Show annotated frames by default
    @Published var isLoading = false
    @Published var errorMessage: String?

    /// The base directory containing the recording artifacts
    private(set) var baseDirectory: URL?

    // MARK: - Load Session

    /// Load a session from the recording output directory.
    func load(videoURL: URL) {
        isLoading = true
        errorMessage = nil
        baseDirectory = videoURL.deletingLastPathComponent()

        let baseName = videoURL.deletingPathExtension().lastPathComponent

        // Load session JSON
        let sessionURL = videoURL.deletingLastPathComponent()
            .appendingPathComponent("\(baseName)_session.json")
        if let data = try? Data(contentsOf: sessionURL),
           let decoded = try? JSONDecoder().decode(RecordingSession.self, from: data) {
            session = decoded
        }

        // Load workflow JSON
        let workflowURL = videoURL.deletingLastPathComponent()
            .appendingPathComponent("\(baseName)_workflow.json")
        if let data = try? Data(contentsOf: workflowURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode(GeneratedWorkflow.self, from: data) {
                workflow = decoded
                steps = decoded.steps
            }
        }

        if session == nil && workflow == nil {
            errorMessage = "No session data found for this recording."
        }

        isLoading = false
    }

    /// Load directly from a session and optional workflow (used when processing just completed)
    func load(session: RecordingSession, workflow: GeneratedWorkflow?, baseDir: URL) {
        self.session = session
        self.workflow = workflow
        self.steps = workflow?.steps ?? []
        self.baseDirectory = baseDir
    }

    // MARK: - Selected Step

    var selectedStep: WorkflowStep? {
        guard let idx = selectedStepIndex, idx >= 0 && idx < steps.count else { return nil }
        return steps[idx]
    }

    /// URL for the screenshot of the selected step (annotated version if available and enabled)
    var selectedScreenshotURL: URL? {
        guard let step = selectedStep,
              let session = session,
              let framesDir = session.framesDirectory,
              let baseDir = baseDirectory else { return nil }

        let dir = baseDir.appendingPathComponent(framesDir)

        // Prefer annotated screenshot if toggle is on and file exists
        if showAnnotated,
           let annotatedFile = step.annotatedScreenshotFile {
            let annotatedURL = dir.appendingPathComponent(annotatedFile)
            if FileManager.default.fileExists(atPath: annotatedURL.path) {
                return annotatedURL
            }
        }

        // Fall back to original
        guard let filename = step.screenshotFile else { return nil }
        return dir.appendingPathComponent(filename)
    }

    /// URL for the original (non-annotated) screenshot
    var originalScreenshotURL: URL? {
        guard let step = selectedStep,
              let filename = step.screenshotFile,
              let session = session,
              let framesDir = session.framesDirectory,
              let baseDir = baseDirectory else { return nil }
        return baseDir.appendingPathComponent(framesDir).appendingPathComponent(filename)
    }

    // MARK: - Editing

    func updateStep(at index: Int, title: String, description: String) {
        guard index >= 0 && index < steps.count else { return }
        steps[index].title = title
        steps[index].description = description
    }

    func moveStep(from source: IndexSet, to destination: Int) {
        steps.move(fromOffsets: source, toOffset: destination)
        // Renumber
        for i in steps.indices {
            steps[i].stepNumber = i + 1
        }
    }

    func deleteStep(at offsets: IndexSet) {
        steps.remove(atOffsets: offsets)
        // Renumber
        for i in steps.indices {
            steps[i].stepNumber = i + 1
        }
        // Clear selection if it's now invalid
        if let idx = selectedStepIndex, idx >= steps.count {
            selectedStepIndex = steps.isEmpty ? nil : steps.count - 1
        }
    }
}
