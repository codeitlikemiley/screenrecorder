import ArgumentParser
import Foundation

struct Screenshot: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Capture a screenshot.",
        discussion: """
            Captures the screen including any visible annotations.
            Supports full screen, region, or window-specific captures.

            Examples:
              sr screenshot                                # full screen
              sr screenshot --output ~/Desktop/demo.png    # custom path
              sr screenshot --region 100,200,800,600       # x,y,w,h region
              sr screenshot --window "Safari"              # specific window
              sr screenshot --window-id 12345              # by window ID
              sr screenshot --base64                       # base64 output
              sr screenshot --clean                        # without annotations
            """
    )

    @Option(name: [.short, .long], help: "Output file path (default: auto-generated temp file)")
    var output: String?

    @Option(name: .long, help: "Capture region: x,y,width,height")
    var region: String?

    @Option(name: .long, help: "Capture specific window by app name")
    var window: String?

    @Option(name: .long, help: "Capture specific window by window ID")
    var windowId: Int?

    @Flag(name: .long, help: "Capture without annotation overlay")
    var clean = false

    @Flag(name: .long, help: "Also print base64-encoded PNG to stdout")
    var base64 = false

    @Option(name: .long, help: "Server port")
    var port: Int = 19820

    func run() throws {
        let client = RPCClient(port: port)
        var params: [String: Any] = [:]
        if let output = output { params["output"] = output }
        if base64 { params["base64"] = true }
        if clean { params["clean"] = true }

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
        if let window = window { params["window"] = window }
        if let windowId = windowId { params["window_id"] = windowId }

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
