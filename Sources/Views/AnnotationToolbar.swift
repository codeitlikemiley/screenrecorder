import SwiftUI

/// Compact floating toolbar for annotation tools.
/// Appears when annotation mode is active.
/// Pill-shaped, matching the ControlBar aesthetic.
struct AnnotationToolbar: View {
    @ObservedObject var annotationState: AnnotationState
    var onClose: () -> Void
    var onClear: () -> Void
    var onScreenshot: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            // Tool buttons
            ForEach(AnnotationTool.allCases) { tool in
                toolButton(tool)
            }

            divider

            // Color presets
            HStack(spacing: 6) {
                ForEach(AnnotationColor.presets) { preset in
                    colorButton(preset)
                }
            }

            divider

            // Line width control
            HStack(spacing: 4) {
                Image(systemName: "lineweight")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))

                Slider(value: $annotationState.lineWidth, in: 1...8, step: 1)
                    .frame(width: 60)
                    .tint(.white.opacity(0.6))
            }

            divider

            // Undo / Redo
            Button(action: { annotationState.undo() }) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 13))
                    .foregroundStyle(annotationState.canUndo ? .white.opacity(0.8) : .white.opacity(0.25))
            }
            .buttonStyle(.plain)
            .disabled(!annotationState.canUndo)
            .help("Undo (⌘Z)")

            Button(action: { annotationState.redo() }) {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 13))
                    .foregroundStyle(annotationState.canRedo ? .white.opacity(0.8) : .white.opacity(0.25))
            }
            .buttonStyle(.plain)
            .disabled(!annotationState.canRedo)
            .help("Redo (⌘⇧Z)")

            divider

            // Clear all
            Button(action: onClear) {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundStyle(annotationState.hasContent ? .white.opacity(0.7) : .white.opacity(0.25))
            }
            .buttonStyle(.plain)
            .disabled(!annotationState.hasContent)
            .help("Clear All (⌘⇧X)")

            // Screenshot
            Button(action: onScreenshot) {
                Image(systemName: "camera")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Screenshot (⌘⇧3)")

            // Close annotation mode
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help("Exit Annotation Mode (⌘⇧D)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            ZStack {
                // Translucent glass background
                RoundedRectangle(cornerRadius: 24)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)

                // Subtle border glow
                RoundedRectangle(cornerRadius: 24)
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
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        .scaleEffect(isHovering ? 1.02 : 1.0)
        .animation(.spring(response: 0.3), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    // MARK: - Tool Button

    private func toolButton(_ tool: AnnotationTool) -> some View {
        Button(action: { annotationState.selectedTool = tool }) {
            Image(systemName: tool.icon)
                .font(.system(size: 14))
                .foregroundStyle(
                    annotationState.selectedTool == tool
                        ? .white
                        : .white.opacity(0.4)
                )
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(annotationState.selectedTool == tool
                            ? .white.opacity(0.15)
                            : .clear)
                )
        }
        .buttonStyle(.plain)
        .help("\(tool.label) (\(tool.shortcutHint))")
    }

    // MARK: - Color Button

    private func colorButton(_ preset: AnnotationColor) -> some View {
        Button(action: { annotationState.selectedColor = preset.color }) {
            Circle()
                .fill(preset.color)
                .frame(width: 16, height: 16)
                .overlay(
                    Circle()
                        .strokeBorder(
                            .white.opacity(isColorSelected(preset) ? 0.9 : 0.3),
                            lineWidth: isColorSelected(preset) ? 2 : 0.5
                        )
                )
        }
        .buttonStyle(.plain)
        .help(preset.name)
    }

    private func isColorSelected(_ preset: AnnotationColor) -> Bool {
        // Compare by name since Color doesn't conform to Equatable in a useful way
        let presetIndex = AnnotationColor.presets.firstIndex(where: { $0.name == preset.name })
        let selectedIndex = AnnotationColor.presets.firstIndex(where: {
            $0.color.description == annotationState.selectedColor.description
        })
        return presetIndex == selectedIndex
    }

    // MARK: - Divider

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.2))
            .frame(width: 1, height: 20)
    }
}
