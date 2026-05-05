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
                    modeSection
                    Divider()
                    scriptEditorSection
                    Divider()
                    playbackSection
                    Divider()
                    appearanceSection
                    Divider()
                    behaviorSection
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

    // MARK: - Mode Picker

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Mode", icon: "slider.horizontal.3")

            Picker("", selection: settings.mode) {
                ForEach(TeleprompterMode.allCases) { mode in
                    Label(mode.displayName, systemImage: mode.icon).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .onChange(of: appState.teleprompterSettings.mode) { _, newMode in
                scrollController.mode = newMode
                scrollController.reset()
                reloadSlides()
            }

            Text(modeDescription)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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

            // Slide tools (Manual mode only)
            if appState.teleprompterSettings.mode == .manual {
                HStack(spacing: 8) {
                    Button(action: { reloadSlides() }) {
                        Label("Smart Split into Slides", systemImage: "scissors")
                    }
                    .controlSize(.small)

                    Text("\(scrollController.slideCount) slides")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(action: { slidePreviewVisible.toggle() }) {
                        Label(slidePreviewVisible ? "Hide Preview" : "Preview Slides", systemImage: "eye")
                    }
                    .controlSize(.small)
                }

                if slidePreviewVisible && !scrollController.slides.isEmpty {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(scrollController.slides.enumerated()), id: \.offset) { index, slide in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("\(index + 1)")
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20, alignment: .trailing)
                                    Text(slide)
                                        .font(.system(size: 11))
                                        .lineLimit(2)
                                        .foregroundStyle(.primary)
                                }
                                .padding(.vertical, 2)
                                if index < scrollController.slides.count - 1 {
                                    Divider()
                                }
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 180)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.3))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                Text("Tip: Insert \"---\" in your script to force a slide break.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Playback Controls

    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Playback", icon: "play.circle")

            switch appState.teleprompterSettings.mode {
            case .manual:
                manualPlaybackControls
            case .autoScroll:
                autoScrollPlaybackControls
            case .voiceFollow:
                voiceFollowPlaybackControls
            }
        }
    }

    private var manualPlaybackControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button(action: { scrollController.previousSlide() }) {
                    Label("Previous", systemImage: "chevron.left")
                }
                .controlSize(.small)
                .disabled(scrollController.isFirstSlide || scrollController.slides.isEmpty)

                Text(scrollController.slideProgressText)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .frame(width: 60)

                Button(action: { scrollController.nextSlide() }) {
                    Label("Next", systemImage: "chevron.right")
                }
                .controlSize(.small)
                .disabled(scrollController.isLastSlide || scrollController.slides.isEmpty)

                Spacer()

                Button(action: { scrollController.reset() }) {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .controlSize(.small)
            }

            HStack {
                Text("Words/Slide")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(appState.teleprompterSettings.maxWordsPerSlide) },
                    set: { appState.teleprompterSettings.maxWordsPerSlide = Int($0) }
                ), in: 20...120, step: 5)
                    .frame(maxWidth: .infinity)
                Text("\(appState.teleprompterSettings.maxWordsPerSlide)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
            .onChange(of: appState.teleprompterSettings.maxWordsPerSlide) { _, _ in
                reloadSlides()
            }

            HStack {
                Text("Transition")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                Picker("", selection: settings.slideTransition) {
                    ForEach(SlideTransition.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            Text("⌘F1 = Previous  ⌘F2 = Next")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var autoScrollPlaybackControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button(action: { scrollController.toggle() }) {
                    Label(
                        scrollController.autoScrollEngine.isRunning ? "Pause" : "Start",
                        systemImage: scrollController.autoScrollEngine.isRunning ? "pause.fill" : "play.fill"
                    )
                }
                .controlSize(.small)

                Spacer()

                Button(action: { scrollController.reset() }) {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .controlSize(.small)
            }

            HStack {
                Text("Speed")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                Slider(value: Binding(
                    get: { appState.teleprompterSettings.autoScrollWPM },
                    set: { appState.teleprompterSettings.autoScrollWPM = $0 }
                ), in: 80...250, step: 10)
                    .frame(maxWidth: .infinity)
                Text("\(Int(appState.teleprompterSettings.autoScrollWPM))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 35, alignment: .trailing)
            }

            Text("Words per minute. ⌘F1 = slower, ⌘F2 = faster.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var voiceFollowPlaybackControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Status
            HStack(spacing: 8) {
                Circle()
                    .fill(voiceFollowStatusColor)
                    .frame(width: 8, height: 8)
                Text(scrollController.voiceFollowStatus)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Spacer()

                Button(action: { scrollController.reset() }) {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .controlSize(.small)
                .disabled(scrollController.state == .idle)
            }

            HStack {
                Text("Match Window")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(appState.teleprompterSettings.phraseWindowSize) },
                    set: { appState.teleprompterSettings.phraseWindowSize = Int($0) }
                ), in: 8...20, step: 1)
                    .frame(maxWidth: .infinity)
                Text("\(appState.teleprompterSettings.phraseWindowSize)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 25, alignment: .trailing)
            }

            Text("How many recent spoken words to match against the script.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Language")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                Picker("", selection: Binding(
                    get: { appState.teleprompterSettings.speechLocale },
                    set: { appState.teleprompterSettings.speechLocale = $0 }
                )) {
                    Text("English (US)").tag("en-US")
                    Text("English (UK)").tag("en-GB")
                    Text("English (AU)").tag("en-AU")
                    Text("English (PH)").tag("en-PH")
                    Text("English (IN)").tag("en-IN")
                    Text("English (SG)").tag("en-SG")
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            HStack {
                Text("Backend")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                Picker("", selection: Binding(
                    get: { appState.teleprompterSettings.speechBackend },
                    set: { appState.teleprompterSettings.speechBackend = $0 }
                )) {
                    ForEach(SpeechBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            Text("Voice-follow starts when recording begins. Pauses when you pause, follows when you speak.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var voiceFollowStatusColor: Color {
        switch scrollController.voiceFollowEngine.state {
        case .idle:       return .gray
        case .tracking:   return .green
        case .adlibbing:  return .orange
        case .lost:       return .red.opacity(0.7)
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Appearance", icon: "paintbrush")

            HStack {
                Text("Font Size")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                Slider(value: settings.fontSize, in: 16...80, step: 2)
                    .frame(maxWidth: .infinity)
                Text("\(Int(appState.teleprompterSettings.fontSize))pt")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }

            HStack {
                Text("Opacity")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                Slider(value: settings.opacity, in: 0.3...1.0, step: 0.05)
                    .frame(maxWidth: .infinity)
                Text("\(Int(appState.teleprompterSettings.opacity * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }

            HStack {
                Text("Background")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                Picker("", selection: settings.backgroundStyle) {
                    ForEach(TeleprompterBackgroundStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            Toggle("Mirror Mode", isOn: settings.isMirrorMode)
                .font(.system(size: 12))
        }
    }

    // MARK: - Behavior

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Behavior", icon: "gearshape")

            Toggle("Always on Top", isOn: settings.isAlwaysOnTop)
                .font(.system(size: 12))

            Toggle("Click-Through Mode", isOn: settings.isClickThrough)
                .font(.system(size: 12))

            Toggle("Exclude from Recording", isOn: settings.isExcludedFromRecording)
                .font(.system(size: 12))
                .onChange(of: appState.teleprompterSettings.isExcludedFromRecording) { _, _ in
                    overlayManager?.updateTeleprompterSharingType()
                }

            Toggle("🎬 Demo Mode — Show in Screen Recordings", isOn: settings.isVisibleInRecordings)
                .font(.system(size: 12))
                .onChange(of: appState.teleprompterSettings.isVisibleInRecordings) { _, _ in
                    overlayManager?.updateTeleprompterSharingType()
                }

            if appState.teleprompterSettings.isVisibleInRecordings {
                Text("The teleprompter overlay will appear in your screen recordings and screen share — useful for demos.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !appState.teleprompterSettings.isExcludedFromRecording {
                Text("⚠️ The teleprompter will appear in your screen recordings")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
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

    private var modeDescription: String {
        switch appState.teleprompterSettings.mode {
        case .manual:
            return "Navigate slides manually with ⌘F1 (prev) and ⌘F2 (next). Best for prepared talks."
        case .autoScroll:
            return "Text scrolls at a fixed speed. Adjust WPM to match your pace. Starts when recording begins."
        case .voiceFollow:
            return "Listens to your voice and follows along. Pauses when you pause, skips when you skip. Starts when recording begins."
        }
    }
}
