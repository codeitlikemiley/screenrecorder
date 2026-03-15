import ArgumentParser
import Foundation

struct Tool: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Configure drawing tools.",
        subcommands: [Select.self, Color.self, LineWidth.self]
    )

    struct Select: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Select a drawing tool.",
            discussion: "Available tools: pen, line, arrow, rectangle, ellipse, text"
        )

        @Argument(help: "Tool name: pen, line, arrow, rectangle, ellipse, text")
        var tool: String

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            let result = try client.call("tool.select", params: ["tool": tool])
            let selected = result["tool"] as? String ?? tool
            print("🔧 Tool: \(selected)")
        }
    }

    struct Color: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set the drawing color.",
            discussion: "Named colors: red, blue, green, yellow, white, orange, cyan, magenta, black. Or hex: #FF0000"
        )

        @Argument(help: "Color name or hex code")
        var color: String

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            _ = try client.call("tool.color", params: ["color": color])
            print("🎨 Color: \(color)")
        }
    }

    struct LineWidth: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "width",
            abstract: "Set the line width (1-20)."
        )

        @Argument(help: "Line width (1-20)")
        var width: Double

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            let result = try client.call("tool.lineWidth", params: ["width": width])
            let actual = result["lineWidth"] as? Double ?? width
            print("📏 Line width: \(actual)")
        }
    }
}
