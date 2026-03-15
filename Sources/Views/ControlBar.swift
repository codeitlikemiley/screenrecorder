import SwiftUI
import AppKit

/// The floating translucent control bar.
/// Pill-shaped, always on top, with glass-morphism effect.
struct ControlBar: View {
    @ObservedObject var appState: AppState
    var onStartRecording: () -> Void
    var onStopRecording: () -> Void
    var onPauseRecording: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 16) {
            // Record / Stop Button
            recordButton

            if appState.isRecording {
                // Pause Button
                pauseButton

                // Duration
                Text(appState.formattedDuration)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)

                divider
            }

            // Camera Toggle
            toggleButton(
                icon: appState.isCameraEnabled ? "video.fill" : "video.slash.fill",
                isActive: appState.isCameraEnabled,
                tooltip: "Camera (⌘⇧C)"
            ) {
                appState.isCameraEnabled.toggle()
            }

            // Mic Toggle
            toggleButton(
                icon: appState.isMicrophoneEnabled ? "mic.fill" : "mic.slash.fill",
                isActive: appState.isMicrophoneEnabled,
                tooltip: "Microphone"
            ) {
                appState.isMicrophoneEnabled.toggle()
            }

            // Keystroke Toggle
            toggleButton(
                icon: "keyboard",
                isActive: appState.isKeystrokeOverlayEnabled,
                tooltip: "Keystrokes (⌘⇧K)"
            ) {
                appState.isKeystrokeOverlayEnabled.toggle()
            }

            // Annotation Toggle (works both during and outside recording)
            toggleButton(
                icon: "pencil.tip.crop.circle",
                isActive: appState.isAnnotationModeActive,
                tooltip: "Annotate (⌘⇧D)"
            ) {
                appState.isAnnotationModeActive.toggle()
            }

            divider

            // Settings
            Button(action: { /* settings */ }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)

            // Close
            Button(action: {
                appState.isControlBarVisible = false
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            ZStack {
                // Translucent glass background
                RoundedRectangle(cornerRadius: 28)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)

                // Subtle border glow
                RoundedRectangle(cornerRadius: 28)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.3), .white.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            }
        )
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        .scaleEffect(isHovering ? 1.02 : 1.0)
        .animation(.spring(response: 0.3), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    // MARK: - Record Button

    private var recordButton: some View {
        Button(action: {
            if appState.isRecording {
                onStopRecording()
            } else {
                onStartRecording()
            }
        }) {
            ZStack {
                Circle()
                    .fill(appState.isRecording
                        ? Color.red.opacity(0.9)
                        : Color.red)
                    .frame(width: 32, height: 32)
                    .shadow(color: .red.opacity(0.5), radius: appState.isRecording ? 8 : 4)

                if appState.isRecording {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.white)
                        .frame(width: 12, height: 12)
                } else {
                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                }
            }
        }
        .buttonStyle(.plain)
        .help(appState.isRecording ? "Stop Recording (⌘⇧R)" : "Start Recording (⌘⇧R)")
    }

    // MARK: - Pause Button

    private var pauseButton: some View {
        Button(action: onPauseRecording) {
            Image(systemName: appState.isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(.white.opacity(appState.isPaused ? 0.2 : 0.1))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Toggle Button

    private func toggleButton(icon: String, isActive: Bool, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(isActive ? .white : .white.opacity(0.4))
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(isActive ? .white.opacity(0.15) : .clear)
                )
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    // MARK: - Divider

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.2))
            .frame(width: 1, height: 20)
    }
}
