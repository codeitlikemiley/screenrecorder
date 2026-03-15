import ArgumentParser
import Foundation

struct Record: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start or stop recording.",
        subcommands: [Start.self, Stop.self]
    )

    struct Start: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start recording.")

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            let result = try client.call("record.start")

            if result["ok"] as? Bool == true {
                print("🔴 Recording started")
            } else {
                let reason = result["reason"] as? String ?? "Unknown"
                print("⚠️  \(reason)")
            }
        }
    }

    struct Stop: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop recording.")

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            let result = try client.call("record.stop")

            if result["ok"] as? Bool == true {
                let file = result["file"] as? String ?? ""
                print("⏹ Recording stopped")
                if !file.isEmpty { print("  Saved: \(file)") }
            } else {
                let reason = result["reason"] as? String ?? "Unknown"
                print("⚠️  \(reason)")
            }
        }
    }
}
