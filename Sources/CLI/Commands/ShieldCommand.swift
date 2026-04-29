import ArgumentParser
import Foundation

struct Shield: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shield",
        abstract: "Inspect or control the scoped interaction shield.",
        subcommands: [Status.self, Enable.self, Disable.self]
    )

    struct SharedTargetOptions: ParsableArguments {
        @Option(name: .long, help: "Browser backend: chromium or safari")
        var backend: String?

        @Option(name: .long, help: "Browser tab ID")
        var tabId: String?

        @Option(name: .long, help: "Match browser tab title containing this string")
        var titleContains: String?

        @Option(name: .long, help: "Match browser tab URL containing this string")
        var urlContains: String?

        @Option(name: .long, help: "Native target window ID")
        var windowId: Int?

        @Option(name: .long, help: "Native target app name")
        var app: String?

        @Option(name: .long, help: "Native target pid")
        var pid: Int?

        @Option(name: .long, help: "Shield message")
        var message: String?

        @Option(name: .long, help: "Browser debugging / WebDriver port")
        var browserPort: Int?
    }

    struct Status: ParsableCommand {
        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            let result = try client.call("shield.status")
            if json {
                print(try jsonString(result))
            } else {
                printResult(result)
            }
        }
    }

    struct Enable: ParsableCommand {
        @OptionGroup
        var target: SharedTargetOptions

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            var params: [String: Any] = [:]
            if let backend = target.backend { params["backend"] = backend }
            if let tabId = target.tabId { params["tab_id"] = tabId }
            if let titleContains = target.titleContains { params["title_contains"] = titleContains }
            if let urlContains = target.urlContains { params["url_contains"] = urlContains }
            if let windowId = target.windowId { params["window_id"] = windowId }
            if let app = target.app { params["app"] = app }
            if let pid = target.pid { params["pid"] = pid }
            if let message = target.message { params["message"] = message }
            if let browserPort = target.browserPort { params["port"] = browserPort }

            let result = try client.call("shield.enable", params: params)
            if json {
                print(try jsonString(result))
            } else {
                printResult(result)
            }
        }
    }

    struct Disable: ParsableCommand {
        @Option(name: .long, help: "Disable scope: all, browser, or native")
        var scope: String = "all"

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            let result = try client.call("shield.disable", params: ["scope": scope])
            if json {
                print(try jsonString(result))
            } else {
                printResult(result)
            }
        }
    }
}
