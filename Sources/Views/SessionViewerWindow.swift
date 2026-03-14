import SwiftUI
import AppKit

/// The main session viewer that assembles StepListView, ScreenshotPreview, and PromptPreviewView
/// into a split-pane layout for reviewing and editing generated workflows.
struct SessionViewerView: View {
    @ObservedObject var model: SessionViewerModel

    @State private var activeTab: Tab = .steps
    @State private var exportFeedback: String?

    enum Tab: String, CaseIterable {
        case steps = "Steps"
        case prompt = "AI Prompt"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            titleBar

            Divider()

            // Main content
            HSplitView {
                // Left: Steps or Prompt (tabbed)
                VStack(spacing: 0) {
                    // Tab picker
                    HStack(spacing: 0) {
                        ForEach(Tab.allCases, id: \.rawValue) { tab in
                            Button(action: { activeTab = tab }) {
                                Text(tab.rawValue)
                                    .font(.system(size: 12, weight: activeTab == tab ? .semibold : .regular))
                                    .foregroundStyle(activeTab == tab ? .primary : .secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(
                                        activeTab == tab
                                            ? Color.accentColor.opacity(0.08)
                                            : Color.clear
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor))

                    Divider()

                    // Tab content
                    switch activeTab {
                    case .steps:
                        StepListView(model: model)
                    case .prompt:
                        PromptPreviewView(model: model)
                    }
                }
                .frame(minWidth: 300, idealWidth: 360)

                // Right: Screenshot preview
                ScreenshotPreview(model: model)
                    .frame(minWidth: 400, idealWidth: 500)
            }
        }
        .background(.ultraThickMaterial)
    }

    // MARK: - Title Bar

    private var titleBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.workflow?.title ?? "Recording Session")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)

                if let summary = model.workflow?.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Session metadata
            if let session = model.session {
                HStack(spacing: 12) {
                    metadataBadge(icon: "clock", value: formatDuration(session.duration))
                    metadataBadge(icon: "hand.tap", value: "\(session.eventSummary.totalEvents) events")
                    if let frameCount = model.session?.frames.count, frameCount > 0 {
                        metadataBadge(icon: "photo.stack", value: "\(frameCount) frames")
                    }
                }
            }

            // Export feedback
            if let feedback = exportFeedback {
                Text(feedback)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }

            // Export menu
            if model.workflow != nil {
                Menu {
                    Section("Copy to Clipboard") {
                        ForEach(WorkflowExporter.ExportFormat.allCases) { format in
                            Button {
                                copyExport(format: format)
                            } label: {
                                Label(format.displayName, systemImage: format.icon)
                            }
                        }
                    }

                    Divider()

                    Button {
                        saveExportToFile()
                    } label: {
                        Label("Save to File…", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Export")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(6)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }

    private func metadataBadge(icon: String, value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(value)
                .font(.system(size: 11))
        }
        .foregroundStyle(.tertiary)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins > 0 {
            return "\(mins)m \(secs)s"
        }
        return "\(secs)s"
    }

    // MARK: - Export Helpers

    private func makeExporter() -> WorkflowExporter? {
        guard let workflow = model.workflow else { return nil }
        return WorkflowExporter(workflow: workflow, session: model.session)
    }

    private func copyExport(format: WorkflowExporter.ExportFormat) {
        guard let exporter = makeExporter() else { return }

        let text: String
        switch format {
        case .markdown: text = exporter.exportAsMarkdown()
        case .aiPrompt: text = exporter.exportAsAIPrompt()
        case .githubIssue: text = exporter.exportAsGitHubIssue()
        case .json: text = exporter.exportAsJSON()
        }

        WorkflowExporter.copyToClipboard(text)

        withAnimation {
            exportFeedback = "✓ Copied \(format.displayName)"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { exportFeedback = nil }
        }
    }

    private func saveExportToFile() {
        guard let exporter = makeExporter(),
              let baseDir = model.baseDirectory else { return }

        let panel = NSSavePanel()
        panel.title = "Export Workflow"
        panel.nameFieldStringValue = "\(model.workflow?.title ?? "workflow")_steps.md"
        panel.allowedContentTypes = [.plainText, .json]
        panel.directoryURL = baseDir

        if panel.runModal() == .OK, let url = panel.url {
            let ext = url.pathExtension.lowercased()
            let format: WorkflowExporter.ExportFormat
            switch ext {
            case "json": format = .json
            case "txt": format = .aiPrompt
            default: format = .markdown
            }

            let text: String
            switch format {
            case .markdown: text = exporter.exportAsMarkdown()
            case .aiPrompt: text = exporter.exportAsAIPrompt()
            case .githubIssue: text = exporter.exportAsGitHubIssue()
            case .json: text = exporter.exportAsJSON()
            }

            try? text.write(to: url, atomically: true, encoding: .utf8)

            withAnimation {
                exportFeedback = "✓ Saved"
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { exportFeedback = nil }
            }
        }
    }
}

// MARK: - Window Manager

/// Manages the session viewer window lifecycle.
/// Opens a dedicated NSWindow with the SessionViewerView.
@MainActor
class SessionViewerWindowManager {
    static let shared = SessionViewerWindowManager()
    private var window: NSWindow?
    private let model = SessionViewerModel()

    /// Open the session viewer with session data loaded directly from processing.
    func open(session: RecordingSession, workflow: GeneratedWorkflow?, baseDirectory: URL) {
        model.load(session: session, workflow: workflow, baseDir: baseDirectory)
        showWindow()
    }

    /// Open the session viewer by loading from a video file URL.
    func open(videoURL: URL) {
        model.load(videoURL: videoURL)
        showWindow()
    }

    private func showWindow() {
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = SessionViewerView(model: model)
        let hostingView = NSHostingView(rootView: contentView)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        newWindow.contentView = hostingView
        newWindow.title = "Session Viewer"
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        newWindow.center()
        newWindow.setFrameAutosaveName("SessionViewer")
        newWindow.isReleasedWhenClosed = false

        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = newWindow
    }
}
