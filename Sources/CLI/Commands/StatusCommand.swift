import ArgumentParser
import Foundation

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show current app status."
    )

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    @Option(name: .long, help: "Server port (default: 19820)")
    var port: Int = 19820

    func run() throws {
        let client = RPCClient(port: port)
        let result = try client.call("status")

        if json {
            print(try jsonString(result))
        } else {
            let recording = result["recording"] as? Bool ?? false
            let annotating = result["annotating"] as? Bool ?? false
            let strokeCount = result["stroke_count"] as? Int ?? 0
            let camera = result["camera_enabled"] as? Bool ?? false
            let mic = result["mic_enabled"] as? Bool ?? false
            let duration = result["duration"] as? Double ?? 0

            print("Screen Recorder Status")
            print("──────────────────────")
            print("  Recording:   \(recording ? "🔴 Active (\(String(format: "%.0fs", duration)))" : "⏹ Idle")")
            print("  Annotation:  \(annotating ? "✏️  Active (\(strokeCount) strokes)" : "Off")")
            print("  Camera:      \(camera ? "✅" : "❌")")
            print("  Microphone:  \(mic ? "✅" : "❌")")
        }
    }
}
