import SwiftUI

// MARK: - Teleprompter Control Panel

/// A floating editor / control panel for managing the teleprompter.
/// Hosted in a separate NSPanel, opened via ⌘F5 or menu bar.
/// Can be opened independently of the teleprompter overlay.
struct TeleprompterControlPanel: View {
    @ObservedObject var appState: AppState
    @ObservedObject var scrollController: AutoScrollController
    var overlayManager: OverlayWindowManager?
    var onClose: (() -> Void)?

    @State private var scriptText: String = ""
    @State private var isImporting = false
    @State private var slidePreviewVisible = false

    private var settings: Binding<TeleprompterSettings> {
        $appState.teleprompterSettings
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    scriptEditorSection
                    Divider()
                    statsSection
                }
                .padding(20)
            }
        }
        .frame(width: 400, height: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            scriptText = appState.teleprompterScript.text
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.plainText],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                if url.startAccessingSecurityScopedResource() {
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let text = try? String(contentsOf: url, encoding: .utf8) {
                        scriptText = text
                        commitScript()
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "text.justify.leading")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text("Teleprompter")
                .font(.system(size: 16, weight: .semibold))
            Spacer()

            Toggle(isOn: Binding(
                get: { appState.isTeleprompterEnabled },
                set: { appState.isTeleprompterEnabled = $0 }
            )) {
                Image(systemName: "eye")
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Enable Teleprompter Service")

            Button(action: { onClose?() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }



    // MARK: - Script Editor

    private var scriptEditorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Script", icon: "doc.text")

            TextEditor(text: $scriptText)
                .font(.system(size: 13))
                .frame(minHeight: 120, maxHeight: 200)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
                .onChange(of: scriptText) { _, _ in
                    commitScript()
                }

            HStack(spacing: 8) {
                Button(action: { isImporting = true }) {
                    Label("Import .txt", systemImage: "doc.badge.plus")
                }
                .controlSize(.small)

                Button(action: {
                    if let clipboard = NSPasteboard.general.string(forType: .string) {
                        scriptText = clipboard
                        commitScript()
                    }
                }) {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .controlSize(.small)

                Spacer()

                Button(action: {
                    scriptText = ""
                    commitScript()
                }) {
                    Label("Clear", systemImage: "trash")
                }
                .controlSize(.small)
                .foregroundStyle(.red)
                .disabled(scriptText.isEmpty)
            }
        }
    }




    // MARK: - Stats

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Script Info", icon: "info.circle")

            HStack(spacing: 20) {
                statItem(label: "Words", value: "\(appState.teleprompterScript.wordCount)")
                statItem(label: "Est. Duration", value: appState.teleprompterScript.formattedDuration)
                statItem(label: "Slides", value: "\(scrollController.slideCount)")
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func statItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    private func commitScript() {
        appState.teleprompterScript.text = scriptText
        appState.teleprompterScript.saveToDisk()
        reloadSlides()
    }

    private func reloadSlides() {
        scrollController.loadSlides(
            from: appState.teleprompterScript,
            maxWords: appState.teleprompterSettings.maxWordsPerSlide
        )
    }

}
