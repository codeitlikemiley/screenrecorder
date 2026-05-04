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

                // Inline glassmorphic text editing field
                if annotationState.isEditingText {
                    textInputField
                        .position(
                            x: min(
                                max(annotationState.editingTextPosition.x + 140, 180),
                                geometry.size.width - 180
                            ),
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

    // MARK: - Glassmorphic Text Input Field

    private var textInputField: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Multi-line text editor
            TextEditor(text: $annotationState.editingTextContent)
                .font(.system(size: annotationState.textFontSize, weight: .semibold))
                .foregroundColor(.primary)
                .scrollContentBackground(.hidden)
                .focused($isTextFieldFocused)
                .frame(minWidth: 240, maxWidth: 400, minHeight: 40, maxHeight: 200)
                .fixedSize(horizontal: false, vertical: true)

            // Bottom bar with color indicator and actions
            HStack(spacing: 8) {
                // Color indicator
                Circle()
                    .fill(annotationState.selectedColor)
                    .frame(width: 12, height: 12)

                Text("⌘↩ to commit")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Spacer()

                // Font size indicator
                Text("\(Int(annotationState.textFontSize))pt")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)

                Button {
                    annotationState.commitText()
                    isTextFieldFocused = false
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.green)
                }
                .buttonStyle(.plain)

                Button {
                    annotationState.cancelTextEditing()
                    isTextFieldFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            ZStack {
                // Glassmorphic blur background
                RoundedRectangle(cornerRadius: 10)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)

                // Gradient tint: more visible at bottom, fading up
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.35),
                                Color.black.opacity(0.15),
                                Color.black.opacity(0.05)
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )

                // Color border
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                annotationState.selectedColor.opacity(0.7),
                                annotationState.selectedColor.opacity(0.3),
                                .white.opacity(0.15)
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        ),
                        lineWidth: 1.5
                    )
            }
        )
        .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
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
