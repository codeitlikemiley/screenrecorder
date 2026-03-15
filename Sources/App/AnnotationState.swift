import SwiftUI

// MARK: - Drawing Tool Types

enum AnnotationTool: String, CaseIterable, Identifiable {
    case pen
    case line
    case arrow
    case rectangle
    case ellipse
    case text

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .pen: return "pencil.tip"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "textformat"
        }
    }

    var label: String {
        switch self {
        case .pen: return "Pen"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .text: return "Text"
        }
    }

    var shortcutHint: String {
        switch self {
        case .pen: return "⌘1"
        case .line: return "⌘2"
        case .arrow: return "⌘3"
        case .rectangle: return "⌘4"
        case .ellipse: return "⌘5"
        case .text: return "⌘6"
        }
    }
}

// MARK: - Stroke Model

struct AnnotationStroke: Identifiable {
    let id = UUID()
    var tool: AnnotationTool
    var points: [CGPoint]      // For pen: all points. For shapes: [origin, endPoint]. For text: [position]
    var color: Color
    var lineWidth: CGFloat
    var textContent: String?   // Only used for .text tool

    /// For shape tools, the bounding rect defined by first and last point
    var boundingRect: CGRect? {
        guard points.count >= 2 else { return nil }
        let origin = points.first!
        let end = points.last!
        return CGRect(
            x: min(origin.x, end.x),
            y: min(origin.y, end.y),
            width: abs(end.x - origin.x),
            height: abs(end.y - origin.y)
        )
    }
}

// MARK: - Preset Colors

struct AnnotationColor: Identifiable {
    let id = UUID()
    let color: Color
    let name: String

    static let presets: [AnnotationColor] = [
        .init(color: .red, name: "Red"),
        .init(color: .yellow, name: "Yellow"),
        .init(color: .green, name: "Green"),
        .init(color: .blue, name: "Blue"),
        .init(color: .white, name: "White"),
        .init(color: .black, name: "Black"),
    ]
}

// MARK: - Annotation State

/// Observable state for the annotation/doodle overlay.
/// Manages strokes, tool selection, and undo/redo history.
@MainActor
class AnnotationState: ObservableObject {
    // MARK: - Committed & In-Progress Strokes
    @Published var strokes: [AnnotationStroke] = []
    @Published var currentStroke: AnnotationStroke?

    // MARK: - Undo/Redo Stack
    @Published var undoneStrokes: [AnnotationStroke] = []

    // MARK: - Tool Settings
    @Published var selectedTool: AnnotationTool = .pen
    @Published var selectedColor: Color = .red
    @Published var lineWidth: CGFloat = 3.0

    // MARK: - Text Editing State
    @Published var isEditingText: Bool = false
    @Published var editingTextPosition: CGPoint = .zero
    @Published var editingTextContent: String = ""
    @Published var textFontSize: CGFloat = 24.0

    // MARK: - Drawing Actions

    /// Begin a new stroke at the given point
    func beginStroke(at point: CGPoint) {
        currentStroke = AnnotationStroke(
            tool: selectedTool,
            points: [point],
            color: selectedColor,
            lineWidth: lineWidth
        )
    }

    /// Continue the current stroke to a new point
    func continueStroke(to point: CGPoint) {
        guard currentStroke != nil else { return }

        if selectedTool == .pen {
            // Freehand: accumulate all points
            currentStroke?.points.append(point)
        } else {
            // Shape tools: keep origin + current endpoint
            if currentStroke!.points.count == 1 {
                currentStroke?.points.append(point)
            } else {
                currentStroke?.points[1] = point
            }
        }
    }

    /// Commit the current stroke to the strokes array
    func endStroke() {
        guard let stroke = currentStroke else { return }
        // Only commit strokes that have actual content
        if stroke.tool == .pen && stroke.points.count >= 2 {
            strokes.append(stroke)
            undoneStrokes.removeAll() // Clear redo stack on new stroke
        } else if stroke.tool != .pen && stroke.points.count >= 2 {
            strokes.append(stroke)
            undoneStrokes.removeAll()
        }
        currentStroke = nil
    }

    // MARK: - Undo / Redo

    /// Undo the last stroke (⌘Z)
    func undo() {
        guard let last = strokes.popLast() else { return }
        undoneStrokes.append(last)
    }

    /// Redo the last undone stroke (⌘⇧Z)
    func redo() {
        guard let last = undoneStrokes.popLast() else { return }
        strokes.append(last)
    }

    /// Clear all strokes and undo history
    func clearAll() {
        strokes.removeAll()
        undoneStrokes.removeAll()
        currentStroke = nil
    }

    // MARK: - Text Input

    /// Start text editing at a position (called when clicking with text tool)
    func beginTextEditing(at point: CGPoint) {
        editingTextPosition = point
        editingTextContent = ""
        isEditingText = true
    }

    /// Commit the current text as a stroke
    func commitText() {
        guard isEditingText, !editingTextContent.trimmingCharacters(in: .whitespaces).isEmpty else {
            isEditingText = false
            editingTextContent = ""
            return
        }

        let stroke = AnnotationStroke(
            tool: .text,
            points: [editingTextPosition],
            color: selectedColor,
            lineWidth: textFontSize,
            textContent: editingTextContent
        )
        strokes.append(stroke)
        undoneStrokes.removeAll()

        isEditingText = false
        editingTextContent = ""
    }

    /// Cancel text editing without committing
    func cancelTextEditing() {
        isEditingText = false
        editingTextContent = ""
    }

    // MARK: - State Queries

    var canUndo: Bool { !strokes.isEmpty }
    var canRedo: Bool { !undoneStrokes.isEmpty }
    var hasContent: Bool { !strokes.isEmpty || currentStroke != nil }
}
