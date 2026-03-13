import SwiftUI

/// KeyCastr-style keystroke overlay — single translucent bar at bottom of screen.
/// Shows sequential keystrokes flowing left-to-right with ×N multiplier for repeats.
/// Fades out 2 seconds after the last keypress.
struct KeystrokeOverlay: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack {
            Spacer()

            if !appState.keystrokeDisplayText.isEmpty {
                HStack {
                    Spacer()

                    Text(appState.keystrokeDisplayText)
                        .font(.system(size: 22, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.75))
                )
                .padding(.horizontal, 50)
                .padding(.bottom, 30)
                .opacity(appState.keystrokeVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.4), value: appState.keystrokeVisible)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
