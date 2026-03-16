import ArgumentParser
import Foundation

struct Windows: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List visible windows with position and size.",
        discussion: """
            Returns all on-screen windows with their app, title, bounds,
            and window ID. Useful for targeting screenshots and placing
            annotations relative to specific windows.

            Examples:
              sr windows                     # all visible windows
              sr windows --app "Safari"      # filter by app name
              sr windows --focused           # only the focused window
              sr windows --json              # JSON output
            """
    )

    @Option(name: .long, help: "Filter by app name (case-insensitive substring)")
    var app: String?

    @Flag(name: .long, help: "Show only the focused window")
    var focused = false

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    @Option(name: .long, help: "Server port")
    var port: Int = 19820

    func run() throws {
        let client = RPCClient(port: port)

        if focused {
            let result = try client.call("windows.focused")

            if json {
                print(try jsonString(result))
            } else {
                if let error = result["error"] as? String {
                    print("⚠️  \(error)")
                } else {
                    printWindow(result)
                }
            }
        } else {
            var params: [String: Any] = [:]
            if let app = app { params["app"] = app }

            let result = try client.call("windows.list", params: params.isEmpty ? nil : params)

            if json {
                print(try jsonString(result))
            } else {
                guard let windows = result["windows"] as? [[String: Any]] else {
                    print("No windows found")
                    return
                }

                let count = result["count"] as? Int ?? windows.count
                print("Windows (\(count))")
                print("──────────────────────")
                for window in windows {
                    printWindow(window)
                    print("")
                }
            }
        }
    }

    private func printWindow(_ w: [String: Any]) {
        let id = w["id"] as? Int ?? 0
        let app = w["app"] as? String ?? "?"
        let title = w["title"] as? String ?? ""
        let bounds = w["bounds"] as? [String: Any] ?? [:]
        let x = bounds["x"] as? Double ?? 0
        let y = bounds["y"] as? Double ?? 0
        let width = bounds["width"] as? Double ?? 0
        let height = bounds["height"] as? Double ?? 0

        let titleStr = title.isEmpty ? "" : " — \(title)"
        print("  [\(id)] \(app)\(titleStr)")
        print("         \(Int(width))×\(Int(height)) at (\(Int(x)),\(Int(y)))")
    }
}
