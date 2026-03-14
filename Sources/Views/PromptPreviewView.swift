import SwiftUI

/// Shows the AI-generated agent prompt with a copy button.
/// This is the prompt that can be fed to Cursor, Codex, or Copilot.
struct PromptPreviewView: View {
    @ObservedObject var model: SessionViewerModel
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                Text("AI Agent Prompt")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()

                if let prompt = model.workflow?.aiAgentPrompt, !prompt.isEmpty {
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(prompt, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copied = false
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            Text(copied ? "Copied!" : "Copy")
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(copied ? .green : .accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if let prompt = model.workflow?.aiAgentPrompt, !prompt.isEmpty {
                ScrollView {
                    Text(prompt)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No AI agent prompt generated")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("Generate steps with AI to create a prompt for coding agents.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
