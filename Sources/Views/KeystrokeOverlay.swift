import SwiftUI

/// KeyCastr-style keystroke overlay — glassmorphic bar at bottom of screen.
/// Shows sequential keystrokes centered, filling up to 90% screen width.
/// Once full, older text is pushed out from the left (head truncation).
/// Fades out 2 seconds after the last keypress.
/// Design: glassmorphic blur with upward gradient fade for readability.
struct KeystrokeOverlay: View {
    @ObservedObject var appState: AppState

    var body: some View {
        GeometryReader { geometry in
            VStack {
                Spacer()

                // Always render the text view (but hide via opacity).
                // Conditional rendering (`if`) prevents SwiftUI animations
                // from working on first appearance.
                Text(appState.keystrokeDisplayText.isEmpty ? " " : appState.keystrokeDisplayText)
                    .font(.system(size: 22, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: geometry.size.width * 0.9)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 16)
                    .background(
                        ZStack {
                            // Glassmorphic blur background
                            RoundedRectangle(cornerRadius: 14)
                                .fill(.ultraThinMaterial)
                                .environment(\.colorScheme, .dark)

                            // Dark tint for contrast
                            RoundedRectangle(cornerRadius: 14)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.black.opacity(0.5),
                                            Color.black.opacity(0.25),
                                            Color.black.opacity(0.1)
                                        ],
                                        startPoint: .bottom,
                                        endPoint: .top
                                    )
                                )

                            // Subtle border glow
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            .white.opacity(0.35),
                                            .white.opacity(0.1),
                                            .white.opacity(0.05)
                                        ],
                                        startPoint: .bottom,
                                        endPoint: .top
                                    ),
                                    lineWidth: 0.5
                                )
                        }
                    )
                    .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
                    .frame(maxWidth: .infinity) // Center in parent
                    .padding(.bottom, 30)
                    .opacity(appState.keystrokeVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.4), value: appState.keystrokeVisible)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
