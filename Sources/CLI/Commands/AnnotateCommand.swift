import ArgumentParser
import Foundation

struct Annotate: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage annotations.",
        subcommands: [
            Add.self, Clear.self, Undo.self, Redo.self, List.self,
            Activate.self, Deactivate.self,
        ]
    )

    // MARK: - Activate / Deactivate

    struct Activate: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Enter annotation mode.")

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            _ = try client.call("annotate.activate")
            print("✏️  Annotation mode activated")
        }
    }

    struct Deactivate: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Exit annotation mode.")

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            _ = try client.call("annotate.deactivate")
            print("✏️  Annotation mode deactivated")
        }
    }

    // MARK: - Add Annotations

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add annotations to the screen.",
            discussion: """
                Pass annotation JSON directly or use shorthand flags.

                Examples:
                  sr annotate add --arrow 100,200,300,400 --color red
                  sr annotate add --rect 50,50,200,150 --color blue --width 3
                  sr annotate add --text "Click here" --at 200,100 --color yellow
                  sr annotate add --json '[{"type":"arrow","from":{"x":0,"y":0},"to":{"x":100,"y":100}}]'
                """
        )

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        // Shorthand: --arrow fromX,fromY,toX,toY
        @Option(name: .long, help: "Arrow: fromX,fromY,toX,toY")
        var arrow: String?

        // Shorthand: --rect x,y,width,height
        @Option(name: .long, help: "Rectangle: x,y,width,height")
        var rect: String?

        // Shorthand: --ellipse x,y,width,height
        @Option(name: .long, help: "Ellipse: x,y,width,height")
        var ellipse: String?

        // Shorthand: --line fromX,fromY,toX,toY
        @Option(name: .long, help: "Line: fromX,fromY,toX,toY")
        var line: String?

        // Shorthand: --text "content" --at x,y
        @Option(name: .long, help: "Text content")
        var text: String?

        @Option(name: .long, help: "Position for text: x,y")
        var at: String?

        // Shared options
        @Option(name: .long, help: "Color name (red, blue, green, yellow, white, orange, cyan, magenta)")
        var color: String = "red"

        @Option(name: .long, help: "Line width / font size")
        var width: Double?

        // Raw JSON
        @Option(name: .long, help: "Raw annotation JSON array")
        var json: String?

        func run() throws {
            let client = RPCClient(port: port)
            var annotations: [[String: Any]] = []

            if let json = json {
                // Raw JSON mode
                guard let data = json.data(using: .utf8),
                      let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    throw ValidationError("Invalid JSON array")
                }
                annotations = parsed
            } else if let arrow = arrow {
                let coords = parseCoords(arrow, count: 4)
                var a: [String: Any] = [
                    "type": "arrow",
                    "from": ["x": coords[0], "y": coords[1]],
                    "to": ["x": coords[2], "y": coords[3]],
                    "color": color,
                ]
                if let w = width { a["lineWidth"] = w }
                annotations.append(a)
            } else if let rect = rect {
                let coords = parseCoords(rect, count: 4)
                var a: [String: Any] = [
                    "type": "rectangle",
                    "origin": ["x": coords[0], "y": coords[1]],
                    "size": ["width": coords[2], "height": coords[3]],
                    "color": color,
                ]
                if let w = width { a["lineWidth"] = w }
                annotations.append(a)
            } else if let ellipse = ellipse {
                let coords = parseCoords(ellipse, count: 4)
                var a: [String: Any] = [
                    "type": "ellipse",
                    "origin": ["x": coords[0], "y": coords[1]],
                    "size": ["width": coords[2], "height": coords[3]],
                    "color": color,
                ]
                if let w = width { a["lineWidth"] = w }
                annotations.append(a)
            } else if let line = line {
                let coords = parseCoords(line, count: 4)
                var a: [String: Any] = [
                    "type": "line",
                    "from": ["x": coords[0], "y": coords[1]],
                    "to": ["x": coords[2], "y": coords[3]],
                    "color": color,
                ]
                if let w = width { a["lineWidth"] = w }
                annotations.append(a)
            } else if let text = text {
                guard let at = at else {
                    throw ValidationError("--text requires --at x,y")
                }
                let coords = parseCoords(at, count: 2)
                var a: [String: Any] = [
                    "type": "text",
                    "at": ["x": coords[0], "y": coords[1]],
                    "text": text,
                    "color": color,
                ]
                if let w = width { a["fontSize"] = w }
                annotations.append(a)
            } else {
                throw ValidationError("Provide --arrow, --rect, --ellipse, --line, --text, or --json")
            }

            let params: [String: Any] = ["annotations": annotations]
            let result = try client.call("annotate.add", params: params)
            let added = result["added"] as? Int ?? 0
            let total = result["total"] as? Int ?? 0
            print("✅ Added \(added) annotation(s) (\(total) total)")
        }

        private func parseCoords(_ str: String, count: Int) -> [Double] {
            let parts = str.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == count else {
                fatalError("Expected \(count) comma-separated numbers, got: \(str)")
            }
            return parts
        }
    }

    // MARK: - Clear / Undo / Redo / List

    struct Clear: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Clear all annotations.")

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            _ = try client.call("annotate.clear")
            print("🗑  Annotations cleared")
        }
    }

    struct Undo: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Undo last annotation.")

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            let result = try client.call("annotate.undo")
            let count = result["stroke_count"] as? Int ?? 0
            print("↩️  Undo (\(count) strokes remaining)")
        }
    }

    struct Redo: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Redo last undone annotation.")

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            let result = try client.call("annotate.redo")
            let count = result["stroke_count"] as? Int ?? 0
            print("↪️  Redo (\(count) strokes)")
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List current annotations.")

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        func run() throws {
            let client = RPCClient(port: port)
            let result = try client.call("annotate.list")

            if json {
                print(try jsonString(result))
            } else {
                let count = result["count"] as? Int ?? 0
                print("Annotations: \(count)")
                if let strokes = result["strokes"] as? [[String: Any]] {
                    for (i, stroke) in strokes.enumerated() {
                        let tool = stroke["tool"] as? String ?? "?"
                        let points = stroke["point_count"] as? Int ?? 0
                        let text = stroke["text"] as? String
                        if let text = text {
                            print("  [\(i)] \(tool): \"\(text)\"")
                        } else {
                            print("  [\(i)] \(tool) (\(points) points)")
                        }
                    }
                }
            }
        }
    }
}
