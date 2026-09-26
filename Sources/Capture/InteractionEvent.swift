import Foundation
import CoreGraphics

/// All types of user interactions captured during a recording session.
/// Each event carries a precise timestamp relative to recording start for synchronization with video frames.
enum InteractionEvent: Codable, Identifiable {
    case mouseClick(MouseClickEvent)
    case mouseDrag(MouseDragEvent)
    case mouseScroll(MouseScrollEvent)
    case keystroke(KeystrokeLogEvent)

    var id: UUID {
        switch self {
        case .mouseClick(let e): return e.id
        case .mouseDrag(let e): return e.id
        case .mouseScroll(let e): return e.id
        case .keystroke(let e): return e.id
        }
    }

    var timestamp: TimeInterval {
        switch self {
        case .mouseClick(let e): return e.timestamp
        case .mouseDrag(let e): return e.timestamp
        case .mouseScroll(let e): return e.timestamp
        case .keystroke(let e): return e.timestamp
        }
    }

    /// Copy with the timestamp moved by `delta` seconds (clamped at 0).
    func shifted(by delta: TimeInterval) -> InteractionEvent {
        switch self {
        case .mouseClick(var e): e.timestamp = max(0, e.timestamp + delta); return .mouseClick(e)
        case .mouseDrag(var e): e.timestamp = max(0, e.timestamp + delta); return .mouseDrag(e)
        case .mouseScroll(var e): e.timestamp = max(0, e.timestamp + delta); return .mouseScroll(e)
        case .keystroke(var e): e.timestamp = max(0, e.timestamp + delta); return .keystroke(e)
        }
    }

    /// Copy with every position passed through `transform`.
    func mappingPositions(_ transform: (CGPoint) -> CGPoint) -> InteractionEvent {
        switch self {
        case .mouseClick(var e): e.position = transform(e.position); return .mouseClick(e)
        case .mouseDrag(var e):
            e.startPosition = transform(e.startPosition)
            e.endPosition = transform(e.endPosition)
            return .mouseDrag(e)
        case .mouseScroll(var e): e.position = transform(e.position); return .mouseScroll(e)
        case .keystroke: return self
        }
    }

    /// Human-readable summary for the step generator
    var summary: String {
        switch self {
        case .mouseClick(let e):
            let btn = e.button == .left ? "Click" : (e.button == .right ? "Right-click" : "Middle-click")
            let count = e.clickCount > 1 ? " (×\(e.clickCount))" : ""
            return "\(btn) at (\(Int(e.position.x)), \(Int(e.position.y)))\(count)"
        case .mouseDrag(let e):
            return "Drag from (\(Int(e.startPosition.x)), \(Int(e.startPosition.y))) to (\(Int(e.endPosition.x)), \(Int(e.endPosition.y)))"
        case .mouseScroll(let e):
            let dir = e.deltaY < 0 ? "down" : "up"
            return "Scroll \(dir) at (\(Int(e.position.x)), \(Int(e.position.y)))"
        case .keystroke(let e):
            let mods = e.modifiers.isEmpty ? "" : e.modifiers.joined(separator: "") + " "
            return "Key: \(mods)\(e.key)"
        }
    }
}

// MARK: - Mouse Events

struct MouseClickEvent: Codable, Identifiable {
    let id: UUID
    var timestamp: TimeInterval       // Seconds on the video timeline
    var position: CGPoint             // Global top-left points (v2); Cocoa bottom-left in v1 files
    let button: MouseButton
    let clickCount: Int               // 1 = single, 2 = double, 3 = triple

    init(timestamp: TimeInterval, position: CGPoint, button: MouseButton, clickCount: Int = 1) {
        self.id = UUID()
        self.timestamp = timestamp
        self.position = position
        self.button = button
        self.clickCount = clickCount
    }
}

struct MouseDragEvent: Codable, Identifiable {
    let id: UUID
    var timestamp: TimeInterval
    var startPosition: CGPoint
    var endPosition: CGPoint
    let duration: TimeInterval        // How long the drag lasted

    init(timestamp: TimeInterval, startPosition: CGPoint, endPosition: CGPoint, duration: TimeInterval) {
        self.id = UUID()
        self.timestamp = timestamp
        self.startPosition = startPosition
        self.endPosition = endPosition
        self.duration = duration
    }
}

struct MouseScrollEvent: Codable, Identifiable {
    let id: UUID
    var timestamp: TimeInterval
    var position: CGPoint
    let deltaX: CGFloat
    let deltaY: CGFloat

    init(timestamp: TimeInterval, position: CGPoint, deltaX: CGFloat, deltaY: CGFloat) {
        self.id = UUID()
        self.timestamp = timestamp
        self.position = position
        self.deltaX = deltaX
        self.deltaY = deltaY
    }
}

enum MouseButton: String, Codable {
    case left
    case right
    case middle
}

// MARK: - Keystroke Log Event (structured version for metadata, separate from display)

struct KeystrokeLogEvent: Codable, Identifiable {
    let id: UUID
    var timestamp: TimeInterval
    let key: String                   // Display string (e.g. "A", "↩", "Space")
    let modifiers: [String]           // ["⌘", "⇧"] etc.
    let isSpecialKey: Bool

    init(timestamp: TimeInterval, key: String, modifiers: [String], isSpecialKey: Bool) {
        self.id = UUID()
        self.timestamp = timestamp
        self.key = key
        self.modifiers = modifiers
        self.isSpecialKey = isSpecialKey
    }
}


