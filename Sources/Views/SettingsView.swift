import SwiftUI
import KeyboardShortcuts

/// Settings / Preferences view.
struct SettingsView: View {
    @ObservedObject var appState: AppState
    @StateObject private var aiManager = AIProviderManager.shared
    @StateObject private var licenseActivator = LicenseActivator.shared
    @StateObject private var cliInstaller = CLIInstaller.shared
    @State private var licenseKeyInput: String = ""
    @State private var serverURLInput: String = SharedDefaults.licenseServerURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                Text("Settings")
                    .font(.system(size: 18, weight: .semibold))
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // License
                    settingsSection(title: "License", icon: "key") {
                        if licenseActivator.isActivated {
                            // Active license display
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Text(licenseActivator.plan.uppercased())
                                        .font(.system(size: 11, weight: .bold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(licenseActivator.plan == "pro"
                                            ? Color.blue.opacity(0.2)
                                            : Color.gray.opacity(0.2))
                                        .foregroundStyle(licenseActivator.plan == "pro"
                                            ? .blue
                                            : .secondary)
                                        .clipShape(Capsule())

                                    Text(licenseActivator.email)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }

                                if licenseActivator.plan == "pro" {
                                    Text("Unlimited MCP tool calls")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.green)
                                } else {
                                    Text("10,000 MCP tool calls / day")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }

                                Button("Deactivate License") {
                                    licenseActivator.deactivate()
                                }
                                .controlSize(.small)
                                .foregroundStyle(.red)
                            }
                        } else {
                            // License key input
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Paste your license key to activate")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)

                                HStack(spacing: 8) {
                                    TextField("SR-XXXX-XXXX-XXXX-XXXX", text: $licenseKeyInput)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 12, design: .monospaced))
                                        .frame(maxWidth: 260)

                                    Button(action: {
                                        Task {
                                            await licenseActivator.activate(key: licenseKeyInput)
                                            if licenseActivator.isActivated {
                                                licenseKeyInput = ""
                                            }
                                        }
                                    }) {
                                        if licenseActivator.isLoading {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Text("Activate")
                                        }
                                    }
                                    .disabled(licenseKeyInput.isEmpty || licenseActivator.isLoading)
                                    .controlSize(.small)
                                }
                            }
                        }

                        // Status messages
                        if let error = licenseActivator.errorMessage {
                            Text(error)
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                        }
                        if let success = licenseActivator.successMessage {
                            Text(success)
                                .font(.system(size: 11))
                                .foregroundStyle(.green)
                        }

                        // Server URL
                        VStack(alignment: .leading, spacing: 4) {
                            Text("License Server")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                TextField("https://license.screenrecorder.dev", text: $serverURLInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(maxWidth: 300)
                                    .onSubmit {
                                        SharedDefaults.setLicenseServerURL(serverURLInput)
                                    }
                                if serverURLInput != SharedDefaults.licenseServerURL {
                                    Button("Save") {
                                        SharedDefaults.setLicenseServerURL(serverURLInput)
                                    }
                                    .controlSize(.mini)
                                }
                            }
                        }
                    }

                    // CLI Tools
                    settingsSection(title: "CLI Tools", icon: "terminal") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: cliInstaller.srInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(cliInstaller.srInstalled ? .green : .secondary)
                                    .font(.system(size: 14))
                                Text("sr")
                                    .font(.system(size: 13, design: .monospaced))
                                Spacer()
                                if cliInstaller.srInstalled {
                                    Text("/usr/local/bin/sr")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }

                            HStack(spacing: 8) {
                                Image(systemName: cliInstaller.mcpInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(cliInstaller.mcpInstalled ? .green : .secondary)
                                    .font(.system(size: 14))
                                Text("sr-mcp")
                                    .font(.system(size: 13, design: .monospaced))
                                Spacer()
                                if cliInstaller.mcpInstalled {
                                    Text("/usr/local/bin/sr-mcp")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }

                            HStack(spacing: 8) {
                                if cliInstaller.srInstalled && cliInstaller.mcpInstalled {
                                    Button("Uninstall CLI Tools") {
                                        cliInstaller.uninstall()
                                    }
                                    .controlSize(.small)
                                    .foregroundStyle(.red)
                                } else {
                                    Button(action: { cliInstaller.install() }) {
                                        if cliInstaller.isInstalling {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Text("Install CLI Tools")
                                        }
                                    }
                                    .disabled(cliInstaller.isInstalling)
                                    .controlSize(.small)
                                }
                            }

                            if let msg = cliInstaller.statusMessage {
                                Text(msg)
                                    .font(.system(size: 11))
                                    .foregroundStyle(msg.contains("success") ? .green : .red)
                            }
                        }
                    }

                    // Output Format
                    settingsSection(title: "Output Format", icon: "film") {
                        Picker("Format", selection: $appState.outputFormat) {
                            ForEach(OutputFormat.allCases) { format in
                                Text(format.displayName).tag(format)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.radioGroup)
                    }

                    // Share-Optimized Export
                    settingsSection(title: "Sharing", icon: "square.and.arrow.up") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Share-Optimized Export", isOn: $appState.isShareOptimizedExportEnabled)
                                .font(.system(size: 13))

                            Text("After each recording, automatically export a Facebook-compatible MP4 (H.264 + AAC) alongside the original. Fixes the known Facebook audio bug where MOV/HEVC recordings lose sound after upload.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .lineLimit(nil)
                        }
                    }

                    // Save Location
                    settingsSection(title: "Save Location", icon: "folder") {
                        HStack {
                            Text(appState.saveDirectory.path)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            Button("Choose...") {
                                chooseSaveDirectory()
                            }
                            .controlSize(.small)
                        }
                    }

                    // Frame Rate
                    settingsSection(title: "Frame Rate", icon: "speedometer") {
                        Picker("FPS", selection: $appState.frameRate) {
                            Text("24 FPS").tag(24)
                            Text("30 FPS").tag(30)
                            Text("60 FPS").tag(60)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 240)
                    }

                    // Camera Size
                    settingsSection(title: "Camera Size", icon: "person.crop.circle") {
                        HStack {
                            Slider(value: $appState.cameraSize, in: 100...400, step: 20)
                                .frame(width: 200)
                            Text("\(Int(appState.cameraSize))px")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 50)
                        }
                    }

                    // Teleprompter Defaults
                    settingsSection(title: "Teleprompter", icon: "text.justify.leading") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Default Mode")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 110, alignment: .leading)
                                Picker("", selection: $appState.teleprompterSettings.mode) {
                                    Text("Manual").tag(TeleprompterMode.manual)
                                    Text("Voice-Follow").tag(TeleprompterMode.voiceFollow)
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                            }

                            HStack {
                                Text("Default Font Size")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 110, alignment: .leading)
                                Slider(value: $appState.teleprompterSettings.fontSize, in: 16...80, step: 2)
                                    .frame(maxWidth: .infinity)
                                Text("\(Int(appState.teleprompterSettings.fontSize))pt")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40, alignment: .trailing)
                            }

                            HStack {
                                Text("Background")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 110, alignment: .leading)
                                Picker("", selection: $appState.teleprompterSettings.backgroundStyle) {
                                    ForEach(TeleprompterBackgroundStyle.allCases) { style in
                                        Text(style.displayName).tag(style)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                            }

                            HStack {
                                Text("Placement")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 110, alignment: .leading)
                                Picker("", selection: $appState.teleprompterSettings.placementMode) {
                                    ForEach(TeleprompterPlacementMode.allCases) { mode in
                                        Label(mode.displayName, systemImage: mode.icon).tag(mode)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .onChange(of: appState.teleprompterSettings.placementMode) { _, _ in
                                    NotificationCenter.default.post(name: .teleprompterPlacementChanged, object: nil)
                                }
                            }

                            HStack {
                                Text("Words/Slide")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 110, alignment: .leading)
                                TextField("e.g. 60", value: Binding(
                                    get: { appState.teleprompterSettings.maxWordsPerSlide },
                                    set: { val in appState.teleprompterSettings.maxWordsPerSlide = max(1, val) }
                                ), format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                                Spacer()
                            }

                            HStack {
                                Text("Match Window")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 110, alignment: .leading)
                                TextField("e.g. 12", value: Binding(
                                    get: { appState.teleprompterSettings.phraseWindowSize },
                                    set: { val in appState.teleprompterSettings.phraseWindowSize = max(1, val) }
                                ), format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                                Spacer()
                            }

                            Toggle("Click-Through Mode", isOn: $appState.teleprompterSettings.isClickThrough)
                                .font(.system(size: 12))

                            Toggle("Demo Mode (Show on Streams)", isOn: $appState.teleprompterSettings.isVisibleInRecordings)
                                .font(.system(size: 12))

                            Text("⌘F3 = Toggle teleprompter  ⌘F5 = Edit script  ⌘F1/F2 = Prev/Next slide")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }

                    // AI Providers
                    settingsSection(title: "AI Providers", icon: "brain") {
                        AIProviderSettingsView(manager: aiManager)
                    }

                    // Keyboard Shortcuts (user-customizable)
                    settingsSection(title: "Keyboard Shortcuts", icon: "keyboard") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(KeyboardShortcuts.Name.allCases, id: \.rawValue) { name in
                                HStack {
                                    Text(name.label)
                                        .font(.system(size: 13))
                                        .frame(width: 180, alignment: .leading)
                                    Spacer()
                                    KeyboardShortcuts.Recorder(for: name)
                                        .frame(width: 160)
                                }
                            }
                        }
                    }

                    // Permissions
                    settingsSection(title: "Permissions", icon: "lock.shield") {
                        VStack(alignment: .leading, spacing: 8) {
                            permissionRow(name: "Screen Recording", granted: appState.hasScreenPermission)
                            permissionRow(name: "Camera", granted: appState.hasCameraPermission)
                            permissionRow(name: "Microphone", granted: appState.hasMicrophonePermission)
                            permissionRow(name: "Accessibility", granted: appState.hasAccessibilityPermission)
                        }
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 480, height: 780)
        .background(.ultraThickMaterial)
        .onAppear {
            DispatchQueue.main.async {
                for window in NSApplication.shared.windows {
                    if window.title == "Settings" || window.title == "ScreenRecorder" {
                        window.level = .floating
                    }
                }
            }
        }
    }

    // MARK: - Section Builder

    private func settingsSection<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            content()
        }
    }

    // MARK: - Permission Row

    private func permissionRow(name: String, granted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(granted ? .green : .red)
                    .font(.system(size: 14))
                Text(name)
                    .font(.system(size: 13))
                Spacer()
                if !granted {
                    Button("Grant") {
                        switch name {
                        case "Screen Recording":
                            PermissionManager.shared.openSystemSettings(pane: "Privacy_ScreenCapture")
                        case "Camera":
                            Task { _ = await PermissionManager.shared.requestCameraPermission() }
                        case "Microphone":
                            Task { _ = await PermissionManager.shared.requestMicrophonePermission() }
                        case "Accessibility":
                            PermissionManager.shared.openAccessibilitySettings()
                        default:
                            PermissionManager.shared.openSystemSettings(pane: "Privacy")
                        }
                    }
                    .controlSize(.mini)

                    if name == "Accessibility" {
                        Button("Restart App") {
                            PermissionManager.shared.restartApp()
                        }
                        .controlSize(.mini)
                        .foregroundStyle(.blue)
                    }
                }
            }
            if !granted && name == "Accessibility" {
                Text("If the toggle is already ON: toggle it OFF, wait 2 seconds, then toggle it back ON. This re-authorizes the app after a rebuild.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Choose Directory

    private func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            appState.saveDirectory = url
        }
    }
}
