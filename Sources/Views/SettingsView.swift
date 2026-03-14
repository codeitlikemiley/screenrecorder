import SwiftUI
import KeyboardShortcuts

/// Settings / Preferences view.
struct SettingsView: View {
    @ObservedObject var appState: AppState
    @StateObject private var aiManager = AIProviderManager.shared

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
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
                .font(.system(size: 14))
            Text(name)
                .font(.system(size: 13))
            Spacer()
            if !granted {
                Button("Grant") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
                }
                .controlSize(.mini)
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
