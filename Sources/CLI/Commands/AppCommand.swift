import ArgumentParser
import Foundation

struct App: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app",
        abstract: "Launch, activate, or list macOS applications.",
        subcommands: [Launch.self, Activate.self, List.self]
    )

    struct Launch: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Launch an application by name or bundle ID."
        )

        @Argument(help: "App name (e.g. 'Safari') or bundle ID (e.g. 'com.apple.Safari')")
        var name: String

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            let result = try client.call("app.launch", params: ["name": name])
            if result["ok"] as? Bool == true {
                print("🚀 Launched: \(name)")
            } else {
                print("❌ \(result["error"] as? String ?? "Could not launch \(name)")")
            }
        }
    }

    struct Activate: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Bring a running app to the foreground."
        )

        @Argument(help: "App name or bundle ID")
        var name: String

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            let result = try client.call("app.activate", params: ["name": name])
            if result["ok"] as? Bool == true {
                print("📱 Activated: \(name)")
            } else {
                print("❌ \(result["error"] as? String ?? "Could not activate \(name)")")
            }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List running applications."
        )

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            let result = try client.call("app.list")

            if json {
                print(try jsonString(result))
            } else {
                guard let apps = result["apps"] as? [[String: Any]] else {
                    print("No running apps")
                    return
                }
                let count = result["count"] as? Int ?? apps.count
                print("Running apps (\(count)):")
                print("──────────────────────────────")
                for app in apps {
                    let name = app["name"] as? String ?? "?"
                    let bundleId = app["bundle_id"] as? String ?? ""
                    let active = app["is_active"] as? Bool ?? false
                    let marker = active ? " ✦" : ""
                    print("  \(name)\(marker)  [\(bundleId)]")
                }
            }
        }
    }
}
