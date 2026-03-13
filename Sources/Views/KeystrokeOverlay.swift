import SwiftUI

/// KeyCastr-style keystroke overlay — single translucent bar at bottom of screen.
/// Shows sequential keystrokes centered, filling up to 90% screen width.
/// Once full, older text is pushed out from the left (head truncation).
/// Fades out 2 seconds after the last keypress.
struct KeystrokeOverlay: View {
    @ObservedObject var appState: AppState

    var body: some View {
        GeometryReader { geometry in
            VStack {
                Spacer()

                if !appState.keystrokeDisplayText.isEmpty {
                    Text(appState.keystrokeDisplayText)
                        .font(.system(size: 22, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: geometry.size.width * 0.9)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.black.opacity(0.75))
                        )
                        .frame(maxWidth: .infinity) // Center in parent
                        .padding(.bottom, 30)
                        .opacity(appState.keystrokeVisible ? 1 : 0)
                        .animation(.easeInOut(duration: 0.4), value: appState.keystrokeVisible)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}
