import ArgumentParser
import Foundation

struct Screen: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show screen/display information.",
        discussion: """
            Returns the primary display resolution, scale factor, and
            visible frame. Useful for calculating annotation coordinates.

            Examples:
              sr screen
              sr screen --json
              sr screen --all
            """
    )

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    @Flag(name: .long, help: "Show all connected displays")
    var all = false

    @Option(name: .long, help: "Server port")
    var port: Int = 19820

    func run() throws {
        let client = RPCClient(port: port)
        var params: [String: Any] = [:]
        if all { params["all"] = true }

        let result = try client.call("screen.info", params: params.isEmpty ? nil : params)

        if json {
            print(try jsonString(result))
        } else {
            if let displays = result["displays"] as? [[String: Any]] {
                for (i, display) in displays.enumerated() {
                    if i > 0 { print("") }
                    printDisplay(display, index: i)
                }
            } else {
                printDisplay(result, index: 0)
            }
        }
    }

    private func printDisplay(_ display: [String: Any], index: Int) {
        let width = display["width"] as? Int ?? 0
        let height = display["height"] as? Int ?? 0
        let scale = display["scale_factor"] as? Double ?? 1.0
        let isMain = display["is_main"] as? Bool ?? false

        print("Display \(index)\(isMain ? " (Main)" : "")")
        print("──────────────────────")
        print("  Resolution:    \(width)×\(height)")
        print("  Scale Factor:  \(scale)x")

        if let vf = display["visible_frame"] as? [String: Any] {
            let vx = vf["x"] as? Double ?? 0
            let vy = vf["y"] as? Double ?? 0
            let vw = vf["width"] as? Double ?? 0
            let vh = vf["height"] as? Double ?? 0
            print("  Visible Area:  \(Int(vw))×\(Int(vh)) at (\(Int(vx)),\(Int(vy)))")
        }

        if let frame = display["frame"] as? [String: Any] {
            let fx = frame["x"] as? Double ?? 0
            let fy = frame["y"] as? Double ?? 0
            print("  Origin:        (\(Int(fx)),\(Int(fy)))")
        }
    }
}
