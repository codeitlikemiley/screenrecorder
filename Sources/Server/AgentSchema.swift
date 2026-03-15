import Foundation
import CoreGraphics

// MARK: - Agent Annotation Schema (JSON ↔ Swift)

/// Codable annotation types matching the agent JSON schema.
/// AI agents send these to programmatically place drawings on screen.
enum AgentAnnotation: Codable {
    case arrow(ArrowAnnotation)
    case rectangle(RectAnnotation)
    case ellipse(EllipseAnnotation)
    case line(LineAnnotation)
    case pen(PenAnnotation)
    case text(TextAnnotation)

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "arrow":     self = .arrow(try ArrowAnnotation(from: decoder))
        case "rectangle": self = .rectangle(try RectAnnotation(from: decoder))
        case "ellipse":   self = .ellipse(try EllipseAnnotation(from: decoder))
        case "line":      self = .line(try LineAnnotation(from: decoder))
        case "pen":       self = .pen(try PenAnnotation(from: decoder))
        case "text":      self = .text(try TextAnnotation(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown annotation type: \(type). Valid types: arrow, rectangle, ellipse, line, pen, text"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .arrow(let a):     try a.encode(to: encoder)
        case .rectangle(let a): try a.encode(to: encoder)
        case .ellipse(let a):   try a.encode(to: encoder)
        case .line(let a):      try a.encode(to: encoder)
        case .pen(let a):       try a.encode(to: encoder)
        case .text(let a):      try a.encode(to: encoder)
        }
    }
}

// MARK: - Point / Size

struct AgentPoint: Codable {
    let x: CGFloat
    let y: CGFloat

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

struct AgentSize: Codable {
    let width: CGFloat
    let height: CGFloat

    var cgSize: CGSize { CGSize(width: width, height: height) }
}

// MARK: - Specific Annotation Types

struct ArrowAnnotation: Codable {
    let type: String
    let from: AgentPoint
    let to: AgentPoint
    var color: String?
    var lineWidth: CGFloat?

    init(from: AgentPoint, to: AgentPoint, color: String? = nil, lineWidth: CGFloat? = nil) {
        self.type = "arrow"
        self.from = from
        self.to = to
        self.color = color
        self.lineWidth = lineWidth
    }
}

struct RectAnnotation: Codable {
    let type: String
    let origin: AgentPoint
    let size: AgentSize
    var color: String?
    var lineWidth: CGFloat?

    init(origin: AgentPoint, size: AgentSize, color: String? = nil, lineWidth: CGFloat? = nil) {
        self.type = "rectangle"
        self.origin = origin
        self.size = size
        self.color = color
        self.lineWidth = lineWidth
    }
}

struct EllipseAnnotation: Codable {
    let type: String
    let origin: AgentPoint
    let size: AgentSize
    var color: String?
    var lineWidth: CGFloat?

    init(origin: AgentPoint, size: AgentSize, color: String? = nil, lineWidth: CGFloat? = nil) {
        self.type = "ellipse"
        self.origin = origin
        self.size = size
        self.color = color
        self.lineWidth = lineWidth
    }
}

struct LineAnnotation: Codable {
    let type: String
    let from: AgentPoint
    let to: AgentPoint
    var color: String?
    var lineWidth: CGFloat?

    init(from: AgentPoint, to: AgentPoint, color: String? = nil, lineWidth: CGFloat? = nil) {
        self.type = "line"
        self.from = from
        self.to = to
        self.color = color
        self.lineWidth = lineWidth
    }
}

struct PenAnnotation: Codable {
    let type: String
    let points: [AgentPoint]
    var color: String?
    var lineWidth: CGFloat?

    init(points: [AgentPoint], color: String? = nil, lineWidth: CGFloat? = nil) {
        self.type = "pen"
        self.points = points
        self.color = color
        self.lineWidth = lineWidth
    }
}

struct TextAnnotation: Codable {
    let type: String
    let at: AgentPoint
    let text: String
    var color: String?
    var fontSize: CGFloat?

    init(at: AgentPoint, text: String, color: String? = nil, fontSize: CGFloat? = nil) {
        self.type = "text"
        self.at = at
        self.text = text
        self.color = color
        self.fontSize = fontSize
    }
}

// MARK: - Batch Request

struct AgentAnnotationBatch: Codable {
    let annotations: [AgentAnnotation]
}

// MARK: - Color Resolution

extension AgentAnnotation {
    /// Parse a color name or hex string into a SwiftUI-compatible CGColor.
    static func resolveColor(_ name: String?) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        guard let name = name?.lowercased() else {
            return (1, 0, 0) // default: red
        }

        switch name {
        case "red":     return (1.0, 0.2, 0.2)
        case "green":   return (0.2, 0.8, 0.3)
        case "blue":    return (0.2, 0.5, 1.0)
        case "yellow":  return (1.0, 0.9, 0.1)
        case "orange":  return (1.0, 0.6, 0.1)
        case "purple":  return (0.6, 0.2, 0.8)
        case "white":   return (1.0, 1.0, 1.0)
        case "black":   return (0.0, 0.0, 0.0)
        case "cyan":    return (0.0, 0.8, 0.8)
        case "magenta": return (0.8, 0.2, 0.6)
        case "pink":    return (1.0, 0.4, 0.7)
        default:
            // Try hex: #RRGGBB
            if name.hasPrefix("#"), name.count == 7 {
                let hex = name.dropFirst()
                if let val = UInt64(hex, radix: 16) {
                    return (
                        CGFloat((val >> 16) & 0xFF) / 255.0,
                        CGFloat((val >> 8) & 0xFF) / 255.0,
                        CGFloat(val & 0xFF) / 255.0
                    )
                }
            }
            return (1, 0, 0) // fallback: red
        }
    }
}
