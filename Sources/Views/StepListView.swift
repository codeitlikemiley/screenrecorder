import SwiftUI

/// Displays the list of generated workflow steps with inline editing.
struct StepListView: View {
    @ObservedObject var model: SessionViewerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "list.number")
                    .foregroundStyle(.secondary)
                Text("Steps")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(model.steps.count) steps")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if model.steps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.badge.xmark")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No steps generated")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("Add an OpenAI API key in Settings to enable AI step generation.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List(selection: $model.selectedStepIndex) {
                    ForEach(Array(model.steps.enumerated()), id: \.element.id) { index, step in
                        StepRow(step: step, isSelected: model.selectedStepIndex == index)
                            .tag(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selectedStepIndex = index
                            }
                    }
                    .onDelete(perform: model.deleteStep)
                    .onMove(perform: model.moveStep)
                }
                .listStyle(.sidebar)
            }
        }
    }
}

// MARK: - Step Row

struct StepRow: View {
    let step: WorkflowStep
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Step number badge
            Text("\(step.stepNumber)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(actionColor)
                )

            VStack(alignment: .leading, spacing: 3) {
                // Title
                Text(step.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)

                // Action type + UI element
                HStack(spacing: 6) {
                    actionBadge

                    if let uiElement = step.uiElement {
                        Text(uiElement)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                // Description (truncated)
                if step.description != step.title {
                    Text(step.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            // Screenshot indicator
            if step.screenshotFile != nil {
                Image(systemName: "photo")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private var actionBadge: some View {
        Text(step.actionType.rawValue)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(actionColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(actionColor.opacity(0.12))
            )
    }

    private var actionColor: Color {
        switch step.actionType {
        case .click, .doubleClick, .rightClick: return .blue
        case .type: return .green
        case .drag: return .orange
        case .scroll: return .purple
        case .navigate: return .cyan
        case .wait: return .gray
        case .observe: return .indigo
        case .speak: return .pink
        }
    }
}
