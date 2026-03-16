import SwiftUI
import AppKit

/// Notification posted by the ⌘, hotkey to open Settings
extension Notification.Name {
    static let openSettings = Notification.Name("com.screenrecorder.openSettings")
}

/// Main application entry point.
/// Uses MenuBarExtra for always-accessible menu bar presence.
@main
struct ScreenRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState: AppState
    @StateObject private var coordinator: RecordingCoordinator

    init() {
        let state = AppState()
        let coord = RecordingCoordinator(appState: state)
        _appState = StateObject(wrappedValue: state)
        _coordinator = StateObject(wrappedValue: coord)
    }

    var body: some Scene {
        // Menu Bar
        MenuBarExtra {
            MenuBarView(appState: appState, coordinator: coordinator)
                .task {
                    // Wire up AppDelegate for global hotkeys
                    appDelegate.configure(appState: appState, coordinator: coordinator)
                    // Run setup when the menu first appears
                    await coordinator.setup()
                }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: appState.isRecording ? "record.circle.fill" : "record.circle")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(appState.isRecording ? .red : .primary)
                if appState.isRecording {
                    Text(appState.formattedDuration)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                }
            }
        }

        // Settings Window
        Settings {
            SettingsView(appState: appState)
        }
    }
}

// MARK: - Menu Bar View

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var coordinator: RecordingCoordinator
    @StateObject private var licenseActivator = LicenseActivator.shared
    @Environment(\.openSettings) private var openSettings

    /// Whether recording features are unlocked
    private var isLicensed: Bool { licenseActivator.isActivated }

    var body: some View {
        Group {
            // License gate — prominent activate button when not licensed
            if !isLicensed {
                Button("🔑 Activate License") {
                    openSettings()
                }
                Divider()
            }

            if appState.isCountingDown {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Starting in \(appState.countdownValue)...")
                }
            } else if appState.isRecording {

                Button("⏹ Stop Recording  ⌘⇧S") {
                    Task { await coordinator.stopRecording() }
                }
            } else {
                Button("⏺ Start Recording  ⌘⇧S") {
                    Task { await coordinator.startRecording() }
                }
                .disabled(!isLicensed)
            }

            Divider()

            Toggle("📷 Camera  ⌘⇧C", isOn: Binding(
                get: { appState.isCameraEnabled },
                set: { newValue in
                    if newValue {
                        Task {
                            let granted = await PermissionManager.shared.requestCameraPermission()
                            appState.hasCameraPermission = granted
                            appState.isCameraEnabled = granted
                            if granted { coordinator.toggleCamera() }
                        }
                    } else {
                        appState.isCameraEnabled = false
                        coordinator.toggleCamera()
                    }
                }
            ))
            .disabled(!isLicensed)

            Toggle("🎤 Microphone  ⌘⇧M", isOn: Binding(
                get: { appState.isMicrophoneEnabled },
                set: { newValue in
                    if newValue {
                        Task {
                            let granted = await PermissionManager.shared.requestMicrophonePermission()
                            appState.hasMicrophonePermission = granted
                            appState.isMicrophoneEnabled = granted
                        }
                    } else {
                        appState.isMicrophoneEnabled = false
                    }
                }
            ))
            .disabled(!isLicensed)

            Toggle("⌨️ Keystroke Overlay  ⌘⇧K", isOn: Binding(
                get: { appState.isKeystrokeOverlayEnabled },
                set: { newValue in
                    if newValue {
                        let granted = PermissionManager.shared.requestAccessibilityPermission()
                        appState.hasAccessibilityPermission = granted
                        appState.isKeystrokeOverlayEnabled = granted
                        if granted { coordinator.toggleKeystrokeMonitor() }
                    } else {
                        appState.isKeystrokeOverlayEnabled = false
                        coordinator.toggleKeystrokeMonitor()
                    }
                }
            ))
            .disabled(!isLicensed)

            // Show/hide camera preview during recording
            if appState.isRecording && appState.isCameraEnabled {
                Button(coordinator.overlayManager.isCameraVisible
                    ? "👁 Hide Camera Preview"
                    : "👁 Show Camera Preview"
                ) {
                    coordinator.overlayManager.toggleCamera()
                }
            }

            // Mute/unmute mic during recording
            if appState.isRecording && appState.isMicrophoneEnabled {
                Button(appState.isMicMuted
                    ? "🔇 Unmute Mic  ⌘⇧M"
                    : "🔊 Mute Mic  ⌘⇧M"
                ) {
                    appState.isMicMuted.toggle()
                }
            }

            // Annotation mode (works independently of recording)
            Divider()
            Toggle("✏️ Annotation Mode  ⌘⇧D", isOn: $appState.isAnnotationModeActive)
                .disabled(!isLicensed)
            Button("🗑 Clear Annotations  ⌘⇧X") {
                appState.annotationState.clearAll()
            }
            .disabled(!isLicensed || !appState.annotationState.hasContent)
            Button("📸 Screenshot  ⌘⇧3") {
                coordinator.captureAnnotationScreenshot()
            }
            .disabled(!isLicensed)

            Divider()

            Button("📂 Open Recordings  ⌘⇧F") {
                NSWorkspace.shared.open(appState.saveDirectory)
            }

            Button("📚 Recording Library  ⌘⇧L") {
                LibraryWindowManager.shared.open(directory: appState.saveDirectory)
            }

            SettingsLink {
                Text("⚙️ Settings...  ⌘,")
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            openSettings()
        }
    }
}
