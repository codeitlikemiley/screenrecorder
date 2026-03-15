import ArgumentParser
import Foundation

struct Screenshot: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Capture a screenshot.",
        discussion: """
            Captures the screen including any visible annotations.
            Saves to the specified path or a temp file.

            Examples:
              sr screenshot
              sr screenshot --output ~/Desktop/demo.png
              sr screenshot --base64
            """
    )

    @Option(name: [.short, .long], help: "Output file path (default: auto-generated temp file)")
    var output: String?

    @Flag(name: .long, help: "Also print base64-encoded PNG to stdout")
    var base64 = false

    @Option(name: .long, help: "Server port")
    var port: Int = 19820

    func run() throws {
        let client = RPCClient(port: port)
        var params: [String: Any] = [:]
        if let output = output { params["output"] = output }
        if base64 { params["base64"] = true }

        let result = try client.call("screenshot.capture", params: params)

        if result["ok"] as? Bool == true {
            let file = result["file"] as? String ?? ""
            let width = result["width"] as? Int ?? 0
            let height = result["height"] as? Int ?? 0
            print("📸 Screenshot captured (\(width)×\(height))")
            print("   \(file)")

            if base64, let b64 = result["base64"] as? String {
                print("\n--- base64 ---")
                print(b64)
            }
        }
    }
}
