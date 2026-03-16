import ArgumentParser
import Foundation

struct Session: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage annotation sessions (save, load, switch between named annotation sets).",
        subcommands: [New.self, List.self, Switch.self, Delete.self, Save.self, Export.self],
        defaultSubcommand: List.self
    )

    struct New: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a new annotation session")

        @Argument(help: "Session name")
        var name: String

        @Flag(name: .long, help: "Copy current annotations into the new session")
        var fromCurrent = false

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        func run() throws {
            let client = RPCClient(port: port)
            let result = try client.call("session.new", params: [
                "name": name,
                "from_current": fromCurrent,
            ])
            if json {
                print(try jsonString(result))
            } else {
                let sid = result["session_id"] as? String ?? "?"
                let count = result["stroke_count"] as? Int ?? 0
                print("✅ Created session \"\(name)\" (\(sid))")
                if count > 0 { print("   Copied \(count) strokes from current canvas") }
            }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all saved sessions")

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        func run() throws {
            let client = RPCClient(port: port)
            let result = try client.call("session.list")
            if json {
                print(try jsonString(result))
            } else {
                guard let sessions = result["sessions"] as? [[String: Any]] else {
                    print("No sessions found")
                    return
                }
                if sessions.isEmpty {
                    print("No sessions saved. Create one with: sr session new <name>")
                    return
                }
                print("Sessions (\(sessions.count)):")
                print("──────────────────────────────")
                for s in sessions {
                    let name = s["name"] as? String ?? "?"
                    let count = s["stroke_count"] as? Int ?? 0
                    let active = s["active"] as? Bool ?? false
                    let activeStr = active ? " ← active" : ""
                    print("  \(name) (\(count) strokes)\(activeStr)")
                }
            }
        }
    }

    struct Switch: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Switch to a named session")

        @Argument(help: "Session name")
        var name: String

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            let result = try client.call("session.switch", params: ["name": name])
            let ok = result["ok"] as? Bool ?? false
            if ok {
                let count = result["stroke_count"] as? Int ?? 0
                print("✅ Switched to \"\(name)\" (\(count) strokes)")
            } else {
                let reason = result["reason"] as? String ?? "Unknown error"
                print("❌ \(reason)")
            }
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a session")

        @Argument(help: "Session name")
        var name: String

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            let result = try client.call("session.delete", params: ["name": name])
            let ok = result["ok"] as? Bool ?? false
            if ok {
                print("✅ Deleted session \"\(name)\"")
            } else {
                let reason = result["reason"] as? String ?? "Unknown error"
                print("❌ \(reason)")
            }
        }
    }

    struct Save: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Save current annotations to active session")

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            let result = try client.call("session.save")
            let count = result["stroke_count"] as? Int ?? 0
            print("✅ Saved (\(count) strokes)")
        }
    }

    struct Export: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Export a session as JSON")

        @Argument(help: "Session name (defaults to active session)")
        var name: String?

        @Option(name: .shortAndLong, help: "Output file path (default: stdout)")
        var output: String?

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            var params: [String: Any] = [:]
            if let name = name { params["name"] = name }
            if let output = output { params["output"] = output }
            let result = try client.call("session.export", params: params.isEmpty ? nil : params)

            let ok = result["ok"] as? Bool ?? false
            if ok {
                if let file = result["file"] as? String {
                    print("✅ Exported to \(file)")
                } else if let json = result["json"] as? String {
                    print(json)
                }
            } else {
                let reason = result["reason"] as? String ?? "Unknown error"
                print("❌ \(reason)")
            }
        }
    }
}
