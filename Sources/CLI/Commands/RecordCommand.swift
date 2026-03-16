import ArgumentParser
import Foundation

struct Record: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Control screen recording.",
        subcommands: [Start.self, Stop.self, Pause.self, Resume.self]
    )

    struct Start: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start recording.")

        @Option(name: .long, help: "Recording mode: normal or ai")
        var mode: String?

        @Flag(name: .long, help: "Enable camera overlay")
        var camera = false

        @Flag(name: .long, help: "Disable camera overlay")
        var noCamera = false

        @Flag(name: .long, help: "Enable microphone")
        var mic = false

        @Flag(name: .long, help: "Disable microphone")
        var noMic = false

        @Flag(name: .long, help: "Enable keystroke overlay")
        var keystrokes = false

        @Flag(name: .long, help: "Disable keystroke overlay")
        var noKeystrokes = false

        @Flag(name: .long, help: "Skip countdown")
        var noCountdown = false

        @Option(name: .long, help: "Frame rate (15, 30, or 60)")
        var fps: Int?

        @Option(name: .long, help: "Output format: mov or mp4")
        var format: String?

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            var params: [String: Any] = [:]

            if let mode = mode { params["mode"] = mode }
            if camera { params["camera"] = true }
            if noCamera { params["camera"] = false }
            if mic { params["mic"] = true }
            if noMic { params["mic"] = false }
            if keystrokes { params["keystrokes"] = true }
            if noKeystrokes { params["keystrokes"] = false }
            if noCountdown { params["countdown"] = false }
            if let fps = fps { params["fps"] = fps }
            if let format = format { params["format"] = format }

            let result = try client.call("record.start", params: params.isEmpty ? nil : params)

            if result["ok"] as? Bool == true {
                print("🔴 Recording started")
                if let mode = result["mode"] as? String {
                    print("   Mode: \(mode)")
                }
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

    struct Pause: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Pause recording.")

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            let result = try client.call("record.pause")
            let ok = result["ok"] as? Bool ?? false
            print(ok ? "⏸ Recording paused" : "⚠️  \(result["reason"] as? String ?? "Not recording")")
        }
    }

    struct Resume: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Resume recording.")

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            let result = try client.call("record.resume")
            let ok = result["ok"] as? Bool ?? false
            print(ok ? "▶️ Recording resumed" : "⚠️  \(result["reason"] as? String ?? "Not paused")")
        }
    }
}
