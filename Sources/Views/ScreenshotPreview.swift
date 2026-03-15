import SwiftUI

/// Displays the key frame screenshot for the currently selected step.
/// Shows the image with an overlay of step info and timestamp.
struct ScreenshotPreview: View {
    @ObservedObject var model: SessionViewerModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "photo.on.rectangle")
                    .foregroundStyle(.secondary)
                Text("Screenshot")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()

                // Annotated/Original toggle
                if model.selectedStep?.annotatedScreenshotFile != nil {
                    Button {
                        model.showAnnotated.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: model.showAnnotated ? "target" : "photo")
                                .font(.system(size: 10))
                            Text(model.showAnnotated ? "Annotated" : "Original")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(model.showAnnotated ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                        )
                    }
                    .buttonStyle(.plain)
                }

                if let step = model.selectedStep {
                    Text(formatTimestamp(step.timestampStart))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Screenshot
            if let url = model.selectedScreenshotURL,
               let nsImage = NSImage(contentsOf: url) {
                ZStack(alignment: .bottomLeading) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .cornerRadius(6)
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)

                    // Step info overlay
                    if let step = model.selectedStep {
                        HStack(spacing: 6) {
                            Text("Step \(step.stepNumber)")
                                .font(.system(size: 10, weight: .bold))
                            Text(step.title)
                                .font(.system(size: 10))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.6))
                        .cornerRadius(4)
                        .padding(8)
                    }
                }
                .padding(16)
            } else {
                // Empty state
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.arrow.down")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    if model.selectedStep != nil {
                        Text("No screenshot for this step")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Select a step to preview its screenshot")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
