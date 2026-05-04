import SwiftUI

/// Premium keystroke overlay — glassmorphic floating pill at bottom of screen.
/// Shows sequential keystrokes with elegant typography and smooth animations.
/// Each keystroke segment is individually styled for readability.
struct KeystrokeOverlay: View {
    @ObservedObject var appState: AppState

    var body: some View {
        GeometryReader { geometry in
            VStack {
                Spacer()

                HStack(spacing: 0) {
                    // Parse keystroke display into segments for styled rendering
                    ForEach(Array(parseSegments(appState.keystrokeDisplayText).enumerated()), id: \.offset) { _, segment in
                        if segment.isModifier {
                            Text(segment.text)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                        } else if segment.isSeparator {
                            Text(segment.text)
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.2))
                        } else if segment.isRepeatCount {
                            Text(segment.text)
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(.white.opacity(0.45))
                        } else {
                            Text(segment.text)
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: geometry.size.width * 0.85)
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
                .background(
                    ZStack {
                        // Base blur
                        RoundedRectangle(cornerRadius: 16)
                            .fill(.ultraThinMaterial)
                            .environment(\.colorScheme, .dark)

                        // Inner gradient for depth
                        RoundedRectangle(cornerRadius: 16)
                            .fill(
                                LinearGradient(
                                    stops: [
                                        .init(color: .black.opacity(0.45), location: 0),
                                        .init(color: .black.opacity(0.2), location: 0.5),
                                        .init(color: .black.opacity(0.05), location: 1.0)
                                    ],
                                    startPoint: .bottom,
                                    endPoint: .top
                                )
                            )

                        // Top edge highlight (inner glow)
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(
                                LinearGradient(
                                    stops: [
                                        .init(color: .white.opacity(0.02), location: 0),
                                        .init(color: .white.opacity(0.15), location: 0.3),
                                        .init(color: .white.opacity(0.25), location: 1.0)
                                    ],
                                    startPoint: .bottom,
                                    endPoint: .top
                                ),
                                lineWidth: 1
                            )
                    }
                )
                .shadow(color: .black.opacity(0.45), radius: 30, y: 10)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 28)
                .opacity(appState.keystrokeVisible ? 1 : 0)
                .scaleEffect(appState.keystrokeVisible ? 1.0 : 0.95)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: appState.keystrokeVisible)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Segment Parsing

    /// Parse the flat keystroke string into styled segments
    private func parseSegments(_ text: String) -> [KeystrokeSegment] {
        guard !text.isEmpty else {
            return [KeystrokeSegment(text: " ", isModifier: false, isSeparator: false, isRepeatCount: false)]
        }

        var segments: [KeystrokeSegment] = []
        let parts = text.components(separatedBy: "  ")

        for (index, part) in parts.enumerated() {
            if index > 0 {
                // Separator between keystroke groups
                segments.append(KeystrokeSegment(text: "  ·  ", isModifier: false, isSeparator: true, isRepeatCount: false))
            }

            // Check for repeat count (e.g. "A ×3")
            if let repeatRange = part.range(of: " ×", options: .backwards) {
                let key = String(part[part.startIndex..<repeatRange.lowerBound])
                let count = String(part[repeatRange.upperBound...])
                appendStyledKey(key, to: &segments)
                segments.append(KeystrokeSegment(text: " ×\(count)", isModifier: false, isSeparator: false, isRepeatCount: true))
            } else {
                appendStyledKey(part, to: &segments)
            }
        }

        return segments
    }

    /// Style a single key entry — split modifier symbols from the key character
    private func appendStyledKey(_ key: String, to segments: inout [KeystrokeSegment]) {
        let modifierSymbols: Set<Character> = ["⌘", "⇧", "⌥", "⌃"]
        var modifierPart = ""
        var keyPart = ""

        for char in key {
            if modifierSymbols.contains(char) {
                modifierPart.append(char)
            } else {
                keyPart.append(char)
            }
        }

        if !modifierPart.isEmpty {
            segments.append(KeystrokeSegment(text: modifierPart, isModifier: true, isSeparator: false, isRepeatCount: false))
        }
        if !keyPart.isEmpty {
            segments.append(KeystrokeSegment(text: keyPart, isModifier: false, isSeparator: false, isRepeatCount: false))
        }
    }
}

// MARK: - Segment Model

private struct KeystrokeSegment {
    let text: String
    let isModifier: Bool
    let isSeparator: Bool
    let isRepeatCount: Bool
}
