import SwiftUI

/// Full-screen SwiftUI Canvas view for drawing annotations.
/// Renders all committed strokes plus the in-progress stroke.
/// Handles mouse/trackpad input via DragGesture.
struct AnnotationCanvasView: View {
    @ObservedObject var annotationState: AnnotationState
    @FocusState private var isTextFieldFocused: Bool
    @State private var clickCount: Int = 0
    @State private var lastClickTime: Date = .distantPast
    @State private var lastClickLocation: CGPoint = .zero

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
                Color.white.opacity(0.001)
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

                                    // Double-click detection for re-editing text strokes
                                    let now = Date()
                                    let distance = hypot(
                                        value.location.x - lastClickLocation.x,
                                        value.location.y - lastClickLocation.y
                                    )
                                    if now.timeIntervalSince(lastClickTime) < 0.4 && distance < 20 {
                                        // Double-click — check if clicked on a text stroke
                                        if let index = annotationState.hitTestStroke(at: value.location),
                                           annotationState.strokes[index].tool == .text {
                                            annotationState.beginReEditingText(strokeIndex: index)
                                            isTextFieldFocused = true
                                        }
                                    }
                                    lastClickTime = now
                                    lastClickLocation = value.location
                                } else if annotationState.selectedTool == .text {
                                    if annotationState.isEditingText {
                                        // Clicking away from active editor — commit
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
                        .padding(.leading, annotationState.editingTextPosition.x)
                        .padding(.top, annotationState.editingTextPosition.y)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            // Keyboard handling for delete and font size
            .background(
                KeyEventHandlingView(
                    onDelete: {
                        if annotationState.selectedTool == .move,
                           annotationState.selectedStrokeIndex != nil {
                            annotationState.deleteSelectedStroke()
                        }
                    },
                    onFontIncrease: {
                        annotationState.increaseTextSize()
                    },
                    onFontDecrease: {
                        annotationState.decreaseTextSize()
                    },
                    onFontReset: {
                        annotationState.resetTextSize()
                    }
                )
                .frame(width: 0, height: 0)
            )
        }
    }

    // MARK: - Selection Highlight

    @ViewBuilder
    private func selectionHighlight(for stroke: AnnotationStroke) -> some View {
        if let bounds = stroke.boundingRect {
            ZStack {
                // Dashed box
                Rectangle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: bounds.width, height: bounds.height)
                    .position(x: bounds.midX, y: bounds.midY)
                
                // 4 Corner Handles
                let handleSize: CGFloat = 10
                let points = [
                    CGPoint(x: bounds.minX, y: bounds.minY),
                    CGPoint(x: bounds.maxX, y: bounds.minY),
                    CGPoint(x: bounds.minX, y: bounds.maxY),
                    CGPoint(x: bounds.maxX, y: bounds.maxY)
                ]
                
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(Color.white)
                        .frame(width: handleSize, height: handleSize)
                        .overlay(Circle().stroke(Color.blue, lineWidth: 2))
                        .shadow(radius: 1)
                        .position(x: points[i].x, y: points[i].y)
                }
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Glassmorphic Text Input Field

    private var textInputField: some View {
        ZStack(alignment: .topLeading) {
            // Hidden text to size the container properly, with a default width for empty state
            let displayText = annotationState.editingTextContent.isEmpty ? "      " : annotationState.editingTextContent + "  "
            Text(displayText)
                .font(.system(size: annotationState.textFontSize, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 8)
                .opacity(0)
                .layoutPriority(1)

            TextEditor(text: $annotationState.editingTextContent)
                .font(.system(size: annotationState.textFontSize, weight: .semibold))
                .foregroundColor(annotationState.selectedColor)
                .scrollContentBackground(.hidden)
                .focused($isTextFieldFocused)
        }
        .fixedSize()
        .background(Color.black.opacity(0.5))
        .cornerRadius(3)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(annotationState.selectedColor, lineWidth: 1)
        )
        // Handle keyboard shortcuts in the text field
        .onKeyPress(phases: .down) { press in
            // Cmd+Enter to commit
            if press.key == .return && press.modifiers.contains(.command) {
                annotationState.commitText()
                isTextFieldFocused = false
                return .handled
            }
            // Cmd+= to increase font
            if press.key == KeyEquivalent("=") && press.modifiers.contains(.command) {
                annotationState.increaseTextSize()
                return .handled
            }
            // Cmd+- to decrease font
            if press.key == KeyEquivalent("-") && press.modifiers.contains(.command) {
                annotationState.decreaseTextSize()
                return .handled
            }
            // Cmd+0 to reset font
            if press.key == KeyEquivalent("0") && press.modifiers.contains(.command) {
                annotationState.resetTextSize()
                return .handled
            }
            return .ignored
        }
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
        case .move:
            break // Move tool doesn't draw — strokes keep their original tool type
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

        // Draw each line of text
        let lines = content.components(separatedBy: "\n")
        let lineHeight = fontSize * 1.3

        for (index, line) in lines.enumerated() {
            guard !line.isEmpty else { continue }
            let text = Text(line)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundColor(stroke.color)

            let resolved = context.resolve(text)
            let textSize = resolved.measure(in: CGSize(width: 1000, height: 1000))
            let y = position.y + CGFloat(index) * lineHeight

            // Background pill for readability
            let padding: CGFloat = 4
            let bgRect = CGRect(
                x: position.x - padding,
                y: y - padding,
                width: textSize.width + padding * 2,
                height: textSize.height + padding * 2
            )
            let bgPath = Path(roundedRect: bgRect, cornerRadius: 3)
            context.fill(bgPath, with: .color(.black.opacity(0.5)))

            // Text
            context.draw(resolved, at: CGPoint(x: position.x + textSize.width / 2, y: y + textSize.height / 2))
        }
    }
}

// MARK: - Key Event Handler (NSView wrapper for Delete key)

/// NSView-based key event handler since SwiftUI's .onKeyPress doesn't
/// reliably intercept Delete/Backspace in overlay windows.
struct KeyEventHandlingView: NSViewRepresentable {
    var onDelete: () -> Void
    var onFontIncrease: () -> Void
    var onFontDecrease: () -> Void
    var onFontReset: () -> Void

    func makeNSView(context: Context) -> KeyEventNSView {
        let view = KeyEventNSView()
        view.onDelete = onDelete
        view.onFontIncrease = onFontIncrease
        view.onFontDecrease = onFontDecrease
        view.onFontReset = onFontReset
        return view
    }

    func updateNSView(_ nsView: KeyEventNSView, context: Context) {
        nsView.onDelete = onDelete
        nsView.onFontIncrease = onFontIncrease
        nsView.onFontDecrease = onFontDecrease
        nsView.onFontReset = onFontReset
    }
}

class KeyEventNSView: NSView {
    var onDelete: (() -> Void)?
    var onFontIncrease: (() -> Void)?
    var onFontDecrease: (() -> Void)?
    var onFontReset: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let keyCode = event.keyCode
        let hasCmd = event.modifierFlags.contains(.command)

        // Delete (51) or Forward Delete (117)
        if keyCode == 51 || keyCode == 117 {
            onDelete?()
            return
        }

        // Cmd+= or Cmd+Shift+= (plus)
        if hasCmd && (event.charactersIgnoringModifiers == "=" || event.charactersIgnoringModifiers == "+") {
            onFontIncrease?()
            return
        }

        // Cmd+-
        if hasCmd && event.charactersIgnoringModifiers == "-" {
            onFontDecrease?()
            return
        }

        // Cmd+0
        if hasCmd && event.charactersIgnoringModifiers == "0" {
            onFontReset?()
            return
        }

        super.keyDown(with: event)
    }
}
