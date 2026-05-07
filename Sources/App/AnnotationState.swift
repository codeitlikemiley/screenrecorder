import SwiftUI

// MARK: - Drawing Tool Types

enum AnnotationTool: String, CaseIterable, Identifiable, Codable {
    case pen
    case line
    case arrow
    case rectangle
    case ellipse
    case text
    case move

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .pen: return "pencil.tip"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "textformat"
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
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
        case .move: return "Move"
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
        case .move: return "⌘7"
        }
    }

    /// Whether this tool is a drawing tool (vs utility like move)
    var isDrawingTool: Bool {
        self != .move
    }
}

// Note: CodablePoint is defined in WorkflowStep.swift

// MARK: - Stroke Model

struct AnnotationStroke: Identifiable, Codable {
    let id: UUID
    var tool: AnnotationTool
    var codablePoints: [CodablePoint]
    var colorRGB: [Double]     // [r, g, b] 0-1 range
    var lineWidth: CGFloat
    var textContent: String?

    /// CGPoint array (computed convenience)
    var points: [CGPoint] {
        get { codablePoints.map(\.cgPoint) }
        set { codablePoints = newValue.map(CodablePoint.init) }
    }

    /// SwiftUI Color (computed, not stored)
    var color: Color {
        get { Color(red: colorRGB[0], green: colorRGB[1], blue: colorRGB[2]) }
        set {
            if let cgColor = NSColor(newValue).usingColorSpace(.sRGB) {
                colorRGB = [Double(cgColor.redComponent), Double(cgColor.greenComponent), Double(cgColor.blueComponent)]
            }
        }
    }

    init(tool: AnnotationTool, points: [CGPoint], color: Color, lineWidth: CGFloat, textContent: String? = nil) {
        self.id = UUID()
        self.tool = tool
        self.codablePoints = points.map(CodablePoint.init)
        self.lineWidth = lineWidth
        self.textContent = textContent
        if let cgColor = NSColor(color).usingColorSpace(.sRGB) {
            self.colorRGB = [Double(cgColor.redComponent), Double(cgColor.greenComponent), Double(cgColor.blueComponent)]
        } else {
            self.colorRGB = [1, 0, 0]
        }
    }

    /// For shape tools, the bounding rect defined by first and last point
    var boundingRect: CGRect? {
        if tool == .text {
            guard let pos = points.first, let content = textContent else { return nil }
            // Calculate actual rendered size
            #if os(macOS)
            let font = NSFont.systemFont(ofSize: lineWidth, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            let size = (content as NSString).size(withAttributes: attributes)
            let width = size.width
            let height = size.height
            #else
            let height = CGFloat(lines.count) * lineWidth * 1.3
            let width = CGFloat(maxChars) * lineWidth * 0.6
            #endif
            
            // Padding added in drawText
            let padding: CGFloat = 4
            return CGRect(
                x: pos.x - padding,
                y: pos.y - padding,
                width: width + padding * 2,
                height: height + padding * 2
            )
        }

        let pts = points
        guard pts.count >= 2 else { return nil }
        let origin = pts.first!
        let end = pts.last!
        return CGRect(
            x: min(origin.x, end.x),
            y: min(origin.y, end.y),
            width: abs(end.x - origin.x),
            height: abs(end.y - origin.y)
        )
    }
}

enum DragHandle {
    case topLeft, topRight, bottomLeft, bottomRight
}

// MARK: - Annotation Session

struct AnnotationSession: Identifiable, Codable {
    let id: UUID
    var name: String
    var strokes: [AnnotationStroke]
    var createdAt: Date
    var updatedAt: Date

    init(name: String, strokes: [AnnotationStroke] = []) {
        self.id = UUID()
        self.name = name
        self.strokes = strokes
        self.createdAt = Date()
        self.updatedAt = Date()
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
/// Manages strokes, tool selection, undo/redo, and named sessions.
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
    var editingExistingStrokeIndex: Int? = nil

    // MARK: - Move Mode State
    @Published var selectedStrokeIndex: Int? = nil
    @Published var dragStartPoint: CGPoint? = nil
    @Published var activeDragHandle: DragHandle? = nil
    var dragStartStroke: AnnotationStroke? = nil

    // MARK: - Session Management
    @Published var sessions: [AnnotationSession] = []
    @Published var activeSessionId: UUID? = nil

    var activeSession: AnnotationSession? {
        sessions.first { $0.id == activeSessionId }
    }

    // MARK: - Drawing Actions

    func beginStroke(at point: CGPoint) {
        currentStroke = AnnotationStroke(
            tool: selectedTool,
            points: [point],
            color: selectedColor,
            lineWidth: lineWidth
        )
    }

    func continueStroke(to point: CGPoint) {
        guard currentStroke != nil else { return }
        if selectedTool == .pen {
            currentStroke?.points.append(point)
        } else {
            if currentStroke!.points.count == 1 {
                currentStroke?.points.append(point)
            } else {
                currentStroke?.points[1] = point
            }
        }
    }

    func endStroke() {
        guard let stroke = currentStroke else { return }
        if stroke.tool == .pen && stroke.points.count >= 2 {
            strokes.append(stroke)
            undoneStrokes.removeAll()
        } else if stroke.tool != .pen && stroke.points.count >= 2 {
            strokes.append(stroke)
            undoneStrokes.removeAll()
        }
        currentStroke = nil
    }

    // MARK: - Undo / Redo

    func undo() {
        guard let last = strokes.popLast() else { return }
        undoneStrokes.append(last)
    }

    func redo() {
        guard let last = undoneStrokes.popLast() else { return }
        strokes.append(last)
    }

    func clearAll() {
        strokes.removeAll()
        undoneStrokes.removeAll()
        currentStroke = nil
    }

    // MARK: - Text Input

    func beginTextEditing(at point: CGPoint) {
        editingTextPosition = point
        editingTextContent = ""
        editingExistingStrokeIndex = nil
        isEditingText = true
    }

    /// Begin re-editing an existing text stroke
    func beginReEditingText(strokeIndex: Int) {
        guard strokeIndex < strokes.count, strokes[strokeIndex].tool == .text else { return }
        let stroke = strokes[strokeIndex]
        editingTextPosition = stroke.points.first ?? .zero
        editingTextContent = stroke.textContent ?? ""
        editingExistingStrokeIndex = strokeIndex
        isEditingText = true
    }

    func commitText() {
        guard isEditingText, !editingTextContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isEditingText = false
            editingTextContent = ""
            editingExistingStrokeIndex = nil
            return
        }

        if let existingIndex = editingExistingStrokeIndex, existingIndex < strokes.count {
            // Update existing stroke in-place
            strokes[existingIndex].textContent = editingTextContent
            strokes[existingIndex].lineWidth = textFontSize
            strokes[existingIndex].color = selectedColor
        } else {
            // Create new text stroke
            let stroke = AnnotationStroke(
                tool: .text,
                points: [editingTextPosition],
                color: selectedColor,
                lineWidth: textFontSize,
                textContent: editingTextContent
            )
            strokes.append(stroke)
            undoneStrokes.removeAll()
        }

        isEditingText = false
        editingTextContent = ""
        editingExistingStrokeIndex = nil
    }

    func cancelTextEditing() {
        isEditingText = false
        editingTextContent = ""
        editingExistingStrokeIndex = nil
    }

    // MARK: - Text Font Size Controls

    func increaseTextSize() {
        textFontSize = min(textFontSize + 4, 120)
    }

    func decreaseTextSize() {
        textFontSize = max(textFontSize - 4, 12)
    }

    func resetTextSize() {
        textFontSize = 24
    }

    // MARK: - Delete Selected Stroke

    func deleteSelectedStroke() {
        guard let index = selectedStrokeIndex, index < strokes.count else { return }
        strokes.remove(at: index)
        selectedStrokeIndex = nil
    }

    // MARK: - Move Mode

    func hitTestHandle(at point: CGPoint, rect: CGRect, threshold: CGFloat = 12) -> DragHandle? {
        let handles: [(DragHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY))
        ]
        
        for (handle, handlePos) in handles {
            let distance = hypot(handlePos.x - point.x, handlePos.y - point.y)
            if distance <= threshold {
                return handle
            }
        }
        return nil
    }

    func hitTestStroke(at point: CGPoint, threshold: CGFloat = 20) -> Int? {
        // If a stroke is already selected, check its handles first
        if let selectedIndex = selectedStrokeIndex, selectedIndex < strokes.count {
            if let rect = strokes[selectedIndex].boundingRect, hitTestHandle(at: point, rect: rect) != nil {
                return selectedIndex
            }
        }
        
        for i in stride(from: strokes.count - 1, through: 0, by: -1) {
            let stroke = strokes[i]
            for strokePoint in stroke.points {
                let distance = hypot(strokePoint.x - point.x, strokePoint.y - point.y)
                if distance <= threshold {
                    return i
                }
            }
            if let rect = stroke.boundingRect {
                let expanded = rect.insetBy(dx: -threshold, dy: -threshold)
                if expanded.contains(point) {
                    return i
                }
            }
        }
        return nil
    }

    func beginMove(at point: CGPoint) {
        if let index = hitTestStroke(at: point) {
            selectedStrokeIndex = index
            dragStartPoint = point
            dragStartStroke = strokes[index]
            
            if let rect = strokes[index].boundingRect {
                activeDragHandle = hitTestHandle(at: point, rect: rect)
            } else {
                activeDragHandle = nil
            }
        } else {
            selectedStrokeIndex = nil
            dragStartPoint = nil
            dragStartStroke = nil
            activeDragHandle = nil
        }
    }

    func continueMove(to point: CGPoint) {
        guard let index = selectedStrokeIndex,
              let start = dragStartPoint,
              let originalStroke = dragStartStroke,
              index < strokes.count else { return }
              
        if let handle = activeDragHandle, let originalRect = originalStroke.boundingRect {
            // Resize mode
            var newRect = originalRect
            
            switch handle {
            case .topLeft:
                newRect.origin.x += (point.x - start.x)
                newRect.origin.y += (point.y - start.y)
                newRect.size.width -= (point.x - start.x)
                newRect.size.height -= (point.y - start.y)
            case .topRight:
                newRect.origin.y += (point.y - start.y)
                newRect.size.width += (point.x - start.x)
                newRect.size.height -= (point.y - start.y)
            case .bottomLeft:
                newRect.origin.x += (point.x - start.x)
                newRect.size.width -= (point.x - start.x)
                newRect.size.height += (point.y - start.y)
            case .bottomRight:
                newRect.size.width += (point.x - start.x)
                newRect.size.height += (point.y - start.y)
            }
            
            // Prevent flipping
            if newRect.width < 10 {
                newRect.origin.x = strokes[index].boundingRect?.origin.x ?? newRect.origin.x
                newRect.size.width = 10
            }
            if newRect.height < 10 {
                newRect.origin.y = strokes[index].boundingRect?.origin.y ?? newRect.origin.y
                newRect.size.height = 10
            }
            
            if originalStroke.tool == .text {
                // For text, scale the font size based on the height change
                let scaleY = newRect.height / originalRect.height
                strokes[index].lineWidth = max(12, originalStroke.lineWidth * scaleY)
                
                // Adjust position so the text scales nicely
                if let originalPos = originalStroke.points.first {
                    var newX = originalPos.x
                    var newY = originalPos.y
                    if handle == .topLeft || handle == .bottomLeft {
                        newX += (point.x - start.x)
                    }
                    if handle == .topLeft || handle == .topRight {
                        newY += (point.y - start.y)
                    }
                    strokes[index].points = [CGPoint(x: newX, y: newY)]
                }
            } else {
                // For shapes, scale all points
                let scaleX = newRect.width / originalRect.width
                let scaleY = newRect.height / originalRect.height
                
                strokes[index].points = originalStroke.points.map { p in
                    let normX = (p.x - originalRect.minX) / originalRect.width
                    let normY = (p.y - originalRect.minY) / originalRect.height
                    
                    return CGPoint(
                        x: newRect.minX + normX * newRect.width,
                        y: newRect.minY + normY * newRect.height
                    )
                }
            }
        } else {
            // Translate mode
            let dx = point.x - start.x
            let dy = point.y - start.y
            strokes[index].points = originalStroke.points.map { p in
                CGPoint(x: p.x + dx, y: p.y + dy)
            }
        }
    }

    func endMove() {
        dragStartPoint = nil
        dragStartStroke = nil
        activeDragHandle = nil
        // Keep selectedStrokeIndex so it stays highlighted
    }

    func deselectStroke() {
        selectedStrokeIndex = nil
    }

    // MARK: - Session Management

    private static var sessionsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("ScreenRecorder/sessions")
    }

    /// Create a new named session, optionally from current strokes
    func createSession(name: String, fromCurrent: Bool = false) -> AnnotationSession {
        let session = AnnotationSession(name: name, strokes: fromCurrent ? strokes : [])
        sessions.append(session)
        saveSession(session)
        return session
    }

    /// Switch to a session (saves current, loads target)
    func switchToSession(id: UUID) {
        if let currentId = activeSessionId,
           let idx = sessions.firstIndex(where: { $0.id == currentId }) {
            sessions[idx].strokes = strokes
            sessions[idx].updatedAt = Date()
            saveSession(sessions[idx])
        }
        if let session = sessions.first(where: { $0.id == id }) {
            strokes = session.strokes
            undoneStrokes.removeAll()
            currentStroke = nil
            activeSessionId = id
        }
    }

    /// Switch to a session by name
    func switchToSession(name: String) -> Bool {
        if let session = sessions.first(where: { $0.name.lowercased() == name.lowercased() }) {
            switchToSession(id: session.id)
            return true
        }
        return false
    }

    /// Delete a session
    func deleteSession(id: UUID) {
        if activeSessionId == id {
            activeSessionId = nil
            strokes.removeAll()
            undoneStrokes.removeAll()
        }
        sessions.removeAll { $0.id == id }
        let url = Self.sessionsDirectory.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
    }

    /// Save current strokes to the active session
    func saveCurrentSession() {
        guard let currentId = activeSessionId,
              let idx = sessions.firstIndex(where: { $0.id == currentId }) else { return }
        sessions[idx].strokes = strokes
        sessions[idx].updatedAt = Date()
        saveSession(sessions[idx])
    }

    /// Export a session as JSON data
    func exportSession(id: UUID) -> Data? {
        guard let session = sessions.first(where: { $0.id == id }) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(session)
    }

    /// Import a session from JSON data
    func importSession(from data: Data) -> AnnotationSession? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(AnnotationSession.self, from: data) else { return nil }
        let session = AnnotationSession(name: decoded.name, strokes: decoded.strokes)
        sessions.append(session)
        saveSession(session)
        return session
    }

    // MARK: - Persistence

    private func saveSession(_ session: AnnotationSession) {
        let dir = Self.sessionsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(session.id.uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(session) {
            try? data.write(to: url)
        }
    }

    func loadSessions() {
        let dir = Self.sessionsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        sessions = files.compactMap { url -> AnnotationSession? in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(AnnotationSession.self, from: data)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - State Queries

    var canUndo: Bool { !strokes.isEmpty }
    var canRedo: Bool { !undoneStrokes.isEmpty }
    var hasContent: Bool { !strokes.isEmpty || currentStroke != nil }
}
