import SwiftUI

/// Full-screen SwiftUI Canvas view for drawing annotations.
/// Renders all committed strokes plus the in-progress stroke.
/// Handles mouse/trackpad input via DragGesture.
struct AnnotationCanvasView: View {
    @ObservedObject var annotationState: AnnotationState
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Drawing canvas
                Canvas { context, size in
                    // Draw all committed strokes
                    for stroke in annotationState.strokes {
                        drawStroke(stroke, in: &context)
                    }

                    // Draw the in-progress stroke
                    if let current = annotationState.currentStroke {
                        drawStroke(current, in: &context)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Selection highlight for move mode
                if annotationState.selectedTool == .move,
                   let selectedIndex = annotationState.selectedStrokeIndex,
                   selectedIndex < annotationState.strokes.count {
                    let stroke = annotationState.strokes[selectedIndex]
                    selectionHighlight(for: stroke)
                }

                // Gesture overlay
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { value in
                                if annotationState.selectedTool == .move {
                                    if annotationState.dragStartPoint == nil {
                                        annotationState.beginMove(at: value.startLocation)
                                    } else {
                                        annotationState.continueMove(to: value.location)
                                    }
                                    return
                                }
                                if annotationState.selectedTool == .text {
                                    return
                                }
                                if annotationState.currentStroke == nil {
                                    annotationState.beginStroke(at: value.startLocation)
                                }
                                annotationState.continueStroke(to: value.location)
                            }
                            .onEnded { value in
                                if annotationState.selectedTool == .move {
                                    annotationState.endMove()
                                } else if annotationState.selectedTool == .text {
                                    if annotationState.isEditingText {
                                        annotationState.commitText()
                                    }
                                    annotationState.beginTextEditing(at: value.location)
                                    isTextFieldFocused = true
                                } else {
                                    annotationState.endStroke()
                                }
                            }
                    )

                // Inline text editing field
                if annotationState.isEditingText {
                    textInputField
                        .position(
                            x: annotationState.editingTextPosition.x + 100,
                            y: annotationState.editingTextPosition.y
                        )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onChange(of: annotationState.selectedTool) { _, newTool in
                if newTool != .move {
                    annotationState.deselectStroke()
                }
                if newTool != .text && annotationState.isEditingText {
                    annotationState.commitText()
                    isTextFieldFocused = false
                }
            }
        }
    }

    // MARK: - Selection Highlight

    @ViewBuilder
    private func selectionHighlight(for stroke: AnnotationStroke) -> some View {
        let bounds = strokeBounds(stroke)
        let padding: CGFloat = 8
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
            .foregroundColor(.white.opacity(0.7))
            .frame(width: bounds.width + padding * 2, height: bounds.height + padding * 2)
            .position(x: bounds.midX, y: bounds.midY)
            .allowsHitTesting(false)
    }

    private func strokeBounds(_ stroke: AnnotationStroke) -> CGRect {
        guard !stroke.points.isEmpty else { return .zero }
        let xs = stroke.points.map(\.x)
        let ys = stroke.points.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!
        let minY = ys.min()!, maxY = ys.max()!
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 20), height: max(maxY - minY, 20))
    }

    // MARK: - Text Input Field

    private var textInputField: some View {
        HStack(spacing: 4) {
            TextField("Type annotation...", text: $annotationState.editingTextContent)
                .textFieldStyle(.plain)
                .font(.system(size: annotationState.textFontSize, weight: .semibold))
                .foregroundColor(annotationState.selectedColor)
                .focused($isTextFieldFocused)
                .frame(minWidth: 200, maxWidth: 400)
                .onSubmit {
                    annotationState.commitText()
                    isTextFieldFocused = false
                }

            Button {
                annotationState.commitText()
                isTextFieldFocused = false
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.green)
            }
            .buttonStyle(.plain)

            Button {
                annotationState.cancelTextEditing()
                isTextFieldFocused = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.red.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.black.opacity(0.75))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(annotationState.selectedColor.opacity(0.6), lineWidth: 1.5)
                )
        )
    }

    // MARK: - Stroke Rendering

    private func drawStroke(_ stroke: AnnotationStroke, in context: inout GraphicsContext) {
        let strokeStyle = StrokeStyle(
            lineWidth: stroke.lineWidth,
            lineCap: .round,
            lineJoin: .round
        )

        switch stroke.tool {
        case .pen:
            drawFreehand(stroke, style: strokeStyle, in: &context)
        case .line:
            drawLine(stroke, style: strokeStyle, in: &context)
        case .arrow:
            drawArrow(stroke, style: strokeStyle, in: &context)
        case .rectangle:
            drawRectangle(stroke, style: strokeStyle, in: &context)
        case .ellipse:
            drawEllipse(stroke, style: strokeStyle, in: &context)
        case .text:
            drawText(stroke, in: &context)
        }
    }

    private func drawFreehand(_ stroke: AnnotationStroke, style: StrokeStyle, in context: inout GraphicsContext) {
        guard stroke.points.count >= 2 else { return }

        var path = Path()
        path.move(to: stroke.points[0])
        for i in 1..<stroke.points.count {
            path.addLine(to: stroke.points[i])
        }

        context.stroke(path, with: .color(stroke.color), style: style)
    }

    private func drawLine(_ stroke: AnnotationStroke, style: StrokeStyle, in context: inout GraphicsContext) {
        guard stroke.points.count >= 2 else { return }

        var path = Path()
        path.move(to: stroke.points[0])
        path.addLine(to: stroke.points[stroke.points.count - 1])

        context.stroke(path, with: .color(stroke.color), style: style)
    }

    private func drawArrow(_ stroke: AnnotationStroke, style: StrokeStyle, in context: inout GraphicsContext) {
        guard stroke.points.count >= 2 else { return }

        let start = stroke.points[0]
        let end = stroke.points[stroke.points.count - 1]

        // Main line
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)

        // Arrowhead
        let angle = atan2(end.y - start.y, end.x - start.x)
        let arrowLength: CGFloat = max(12, stroke.lineWidth * 4)
        let arrowAngle: CGFloat = .pi / 6  // 30 degrees

        let arrow1 = CGPoint(
            x: end.x - arrowLength * cos(angle - arrowAngle),
            y: end.y - arrowLength * sin(angle - arrowAngle)
        )
        let arrow2 = CGPoint(
            x: end.x - arrowLength * cos(angle + arrowAngle),
            y: end.y - arrowLength * sin(angle + arrowAngle)
        )

        path.move(to: arrow1)
        path.addLine(to: end)
        path.addLine(to: arrow2)

        context.stroke(path, with: .color(stroke.color), style: style)
    }

    private func drawRectangle(_ stroke: AnnotationStroke, style: StrokeStyle, in context: inout GraphicsContext) {
        guard let rect = stroke.boundingRect else { return }

        let path = Path(roundedRect: rect, cornerRadius: 2)
        context.stroke(path, with: .color(stroke.color), style: style)
    }

    private func drawEllipse(_ stroke: AnnotationStroke, style: StrokeStyle, in context: inout GraphicsContext) {
        guard let rect = stroke.boundingRect else { return }

        let path = Path(ellipseIn: rect)
        context.stroke(path, with: .color(stroke.color), style: style)
    }

    private func drawText(_ stroke: AnnotationStroke, in context: inout GraphicsContext) {
        guard let position = stroke.points.first,
              let content = stroke.textContent, !content.isEmpty else { return }

        let fontSize = stroke.lineWidth // lineWidth doubles as fontSize for text
        let text = Text(content)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundColor(stroke.color)

        // Draw with background pill for readability
        let resolved = context.resolve(text)
        let textSize = resolved.measure(in: CGSize(width: 1000, height: 1000))

        // Background rounded rect
        let padding: CGFloat = 6
        let bgRect = CGRect(
            x: position.x - padding,
            y: position.y - padding,
            width: textSize.width + padding * 2,
            height: textSize.height + padding * 2
        )
        let bgPath = Path(roundedRect: bgRect, cornerRadius: 4)
        context.fill(bgPath, with: .color(.black.opacity(0.6)))
        context.stroke(bgPath, with: .color(stroke.color.opacity(0.5)), lineWidth: 1)

        // Text
        context.draw(resolved, at: CGPoint(x: position.x + textSize.width / 2, y: position.y + textSize.height / 2))
    }
}

