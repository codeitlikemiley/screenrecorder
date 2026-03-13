import SwiftUI

/// Floating HUD that displays recent keystrokes as animated pills.
/// Positioned at bottom-center of screen. Keystrokes fade out after 2 seconds.
struct KeystrokeOverlay: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack {
            Spacer()

            HStack(spacing: 8) {
                ForEach(appState.activeKeystrokes) { keystroke in
                    KeystrokePill(keystroke: keystroke)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.5).combined(with: .opacity),
                            removal: .opacity.combined(with: .move(edge: .bottom))
                        ))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: appState.activeKeystrokes)
            .padding(.bottom, 80)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Keystroke Pill

struct KeystrokePill: View {
    let keystroke: KeystrokeEvent
    @State private var opacity: Double = 1.0

    var body: some View {
        HStack(spacing: 4) {
            // Modifier keys
            ForEach(keystroke.modifiers, id: \.self) { modifier in
                Text(modifier.symbol)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
            }

            // Key
            Text(keystroke.keyString)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)

                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hue: 0.6, saturation: 0.5, brightness: 0.3).opacity(0.6),
                                Color(hue: 0.7, saturation: 0.4, brightness: 0.2).opacity(0.4)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
            }
        )
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        .opacity(opacity)
        .onAppear {
            withAnimation(.easeIn(duration: 0.5).delay(1.5)) {
                opacity = 0
            }
        }
    }
}
