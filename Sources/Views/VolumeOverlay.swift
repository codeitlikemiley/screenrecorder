import SwiftUI

/// Centered volume HUD overlay — shows mic volume level bars.
/// Appears briefly when volume is adjusted via hotkeys, auto-fades after 1.5s.
struct VolumeOverlay: View {
    @ObservedObject var appState: AppState
    private let maxLevel = 10

    var body: some View {
        if appState.showVolumeOverlay {
            VStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: appState.micVolume == 0 ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(appState.micVolume == 0 ? .red : .white)

                    Text("Mic Volume")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }

                // Level bars like macOS System Preferences
                HStack(spacing: 3) {
                    ForEach(1...maxLevel, id: \.self) { level in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(level <= appState.micVolume
                                  ? barColor(for: level)
                                  : Color.white.opacity(0.2))
                            .frame(width: 18, height: 12)
                    }
                }

                Text("\(appState.micVolume)/\(maxLevel)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.black.opacity(0.7))
                    )
            )
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.3), value: appState.showVolumeOverlay)
        }
    }

    private func barColor(for level: Int) -> Color {
        if level <= 3 { return .green }
        if level <= 7 { return .yellow }
        return .orange
    }
}
