import ArgumentParser
import Foundation

struct Detect: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Detect UI elements (text, buttons, labels) via Vision OCR.",
        discussion: """
            Captures a screenshot and runs macOS Vision text recognition
            to identify on-screen text elements with bounding boxes.

            Returns each detected element's text, position, size, center
            point, and confidence score. Use these coordinates to precisely
            place annotations via `sr annotate add`.

            Ideal for iOS Simulator, desktop apps, or any non-browser UI.

            Examples:
              sr detect                              # full screen
              sr detect --window "Simulator"         # specific window
              sr detect --window-id 12345            # by window ID
              sr detect --region 100,200,800,600     # specific region
              sr detect --json                       # JSON output
              sr detect --window "Simulator" --min-confidence 0.8
            """
    )

    @Option(name: .long, help: "Detect elements in a specific window by app name")
    var window: String?

    @Option(name: .long, help: "Detect elements in a specific window by ID")
    var windowId: Int?

    @Option(name: .long, help: "Detect elements in region: x,y,width,height")
    var region: String?

    @Option(name: .long, help: "Minimum confidence 0.0-1.0 (default: 0.5)")
    var minConfidence: Double = 0.5

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    @Option(name: .long, help: "Server port")
    var port: Int = 19820

    func run() throws {
        let client = RPCClient(port: port)
        var params: [String: Any] = [
            "min_confidence": minConfidence,
        ]

        if let window = window { params["window"] = window }
        if let windowId = windowId { params["window_id"] = windowId }
        if let region = region {
            let coords = region.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard coords.count == 4 else {
                throw ValidationError("--region requires 4 values: x,y,width,height")
            }
            params["region"] = [
                "x": coords[0], "y": coords[1],
                "width": coords[2], "height": coords[3],
            ]
        }

        let result = try client.call("elements.detect", params: params)

        if json {
            print(try jsonString(result))
        } else {
            guard let elements = result["elements"] as? [[String: Any]] else {
                print("No elements detected")
                return
            }

            let count = result["count"] as? Int ?? elements.count
            print("Detected \(count) elements")
            print("──────────────────────────────")

            for el in elements {
                let text = el["text"] as? String ?? ""
                let conf = el["confidence"] as? Double ?? 0
                let bounds = el["bounds"] as? [String: Any] ?? [:]
                let center = el["center"] as? [String: Any] ?? [:]
                let bx = bounds["x"] as? Double ?? 0
                let by = bounds["y"] as? Double ?? 0
                let bw = bounds["width"] as? Double ?? 0
                let bh = bounds["height"] as? Double ?? 0
                let cx = center["x"] as? Double ?? 0
                let cy = center["y"] as? Double ?? 0

                let confStr = String(format: "%.0f%%", conf * 100)
                print("  \"\(text)\"  [\(confStr)]")
                print("    bounds: \(Int(bw))×\(Int(bh)) at (\(Int(bx)),\(Int(by)))  center: (\(Int(cx)),\(Int(cy)))")
            }
        }
    }
}
