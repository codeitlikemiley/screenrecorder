import ArgumentParser
import Foundation

struct Safety: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "safety",
        abstract: "Inspect or configure computer-control safety settings.",
        subcommands: [Status.self, Mode.self]
    )

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show current safety settings."
        )

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            let result = try client.call("safety.settings")

            if json {
                print(try jsonString(result))
                return
            }

            let enabled = result["enabled"] as? Bool ?? false
            let mode = result["execution_mode"] as? String ?? "foreground"
            let confirm = result["confirmation_mode"] as? Bool ?? false
            let rate = result["max_actions_per_second"] as? Int ?? 0
            let allowlist = result["app_allowlist"] as? [String] ?? []

            print("Safety Settings")
            print("───────────────")
            print("  Enabled:           \(enabled ? "✅" : "❌")")
            print("  Execution mode:    \(mode)")
            print("  Confirmation:      \(confirm ? "✅" : "❌")")
            print("  Max actions/sec:   \(rate)")
            print("  App allowlist:     \(allowlist.isEmpty ? "(none)" : allowlist.joined(separator: ", "))")
        }
    }

    struct Mode: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set execution mode: foreground, background_safe, or background_strict."
        )

        @Argument(help: "Execution mode")
        var mode: String

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            let result = try client.call("safety.configure", params: ["execution_mode": mode])
            guard result["ok"] as? Bool == true else {
                print("❌ \(result["error"] as? String ?? "Could not update safety mode")")
                return
            }
            let settings = result["settings"] as? [String: Any] ?? [:]
            let current = settings["execution_mode"] as? String ?? mode
            print("🛡️ Execution mode: \(current)")
        }
    }
}
