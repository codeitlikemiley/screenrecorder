import ArgumentParser
import Foundation

struct Shell: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shell",
        abstract: "Run a shell command and return its output.",
        discussion: """
            Executes a command via /bin/zsh and returns stdout, stderr, and exit code.

            Examples:
              sr shell "echo hello"
              sr shell "ls -la /tmp"
              sr shell --timeout 10 "npm test"
            """
    )

    @Argument(help: "Shell command to execute")
    var command: String

    @Option(name: .long, help: "Timeout in seconds (default: 30)")
    var timeout: Double = 30

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    @Option(name: .long, help: "Server port")
    var port: Int = 19820

    func run() throws {
        let client = RPCClient(port: port)
        let result = try client.call("shell.exec", params: [
            "command": command,
            "timeout": timeout,
        ])

        if json {
            print(try jsonString(result))
        } else {
            let ok = result["ok"] as? Bool ?? false
            let exitCode = result["exit_code"] as? Int ?? -1
            let stdout = result["stdout"] as? String ?? ""
            let stderr = result["stderr"] as? String ?? ""

            if !stdout.isEmpty {
                print(stdout)
            }
            if !stderr.isEmpty {
                fputs(stderr + "\n", Foundation.stderr)
            }
            if !ok {
                if let error = result["error"] as? String {
                    fputs("❌ \(error)\n", Foundation.stderr)
                }
                throw ExitCode(Int32(exitCode))
            }
        }
    }
}

// Helper: access to stderr stream
extension Shell {
    private static var stderr = FileHandle.standardError
}
