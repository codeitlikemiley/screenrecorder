import ArgumentParser
import Foundation

struct Browser: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "browser",
        abstract: "Control Chromium-based browsers via the DevTools Protocol.",
        discussion: """
            Browser automation is preferred over desktop OCR/mouse control for web pages.
            Chromium backends use the DevTools Protocol; Safari uses safaridriver/WebDriver.
            Both use DOM/JavaScript APIs instead of screen coordinates.

              sr browser launch --url https://example.com
              sr browser launch --backend safari --app Safari --url https://example.com
              sr browser tabs --json
              sr browser click 'button[type="submit"]'
              sr browser type 'input[name="q"]' 'screen recorder'
              sr browser eval 'document.title'
              sr browser screenshot -o /tmp/page.png
            """,
        subcommands: [
            Status.self,
            Launch.self,
            LaunchAndOpen.self,
            Tabs.self,
            Open.self,
            ActivateTab.self,
            Navigate.self,
            Eval.self,
            Click.self,
            TypeText.self,
            PressKey.self,
            Screenshot.self,
        ]
    )

    static func baseParams(backend: String, port: Int) -> [String: Any] {
        ["backend": backend, "port": port]
    }

    static func addTabTarget(tabId: String?, titleContains: String?, urlContains: String?, to params: inout [String: Any]) {
        if let tabId { params["tab_id"] = tabId }
        if let titleContains { params["title_contains"] = titleContains }
        if let urlContains { params["url_contains"] = urlContains }
    }

    struct SharedOptions: ParsableArguments {
        @Option(name: .long, help: "Browser backend: 'chromium' or 'safari'")
        var backend: String = "chromium"

        @Option(name: .long, help: "Remote debugging port")
        var port: Int = 9222
    }

    struct TabTargetOptions: ParsableArguments {
        @Option(name: .long, help: "Explicit browser tab ID")
        var tabId: String?

        @Option(name: .long, help: "Match a tab whose title contains this text")
        var titleContains: String?

        @Option(name: .long, help: "Match a tab whose URL contains this text")
        var urlContains: String?
    }

    struct Status: ParsableCommand {
        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @OptionGroup
        var shared: SharedOptions

        func run() throws {
            let client = RPCClient()
            let result = try client.call("browser.status", params: Browser.baseParams(backend: shared.backend, port: shared.port))
            if json {
                print(try jsonString(result))
            } else {
                printResult(result)
            }
        }
    }

    struct Launch: ParsableCommand {
        @Option(name: .long, help: "Browser app name")
        var app: String = "Google Chrome"

        @Option(name: .long, help: "Open this URL after launch")
        var url: String?

        @Flag(name: .long, help: "Activate/focus the browser after launch")
        var activate = false

        @Flag(name: .long, inversion: .prefixedNo, help: "Use an isolated browser profile for automation")
        var isolated = true

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @OptionGroup
        var shared: SharedOptions

        func run() throws {
            let client = RPCClient()
            var params = Browser.baseParams(backend: shared.backend, port: shared.port)
            params["app"] = app
            params["activate"] = activate
            params["isolated"] = isolated
            if let url { params["url"] = url }
            let result = try client.call("browser.launch", params: params)
            if json {
                print(try jsonString(result))
            } else {
                printResult(result)
            }
        }
    }

    struct Tabs: ParsableCommand {
        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @OptionGroup
        var shared: SharedOptions

        func run() throws {
            let client = RPCClient()
            let result = try client.call("browser.tabs", params: Browser.baseParams(backend: shared.backend, port: shared.port))
            if json {
                print(try jsonString(result))
            } else {
                printResult(result)
            }
        }
    }

    struct LaunchAndOpen: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "launch-and-open",
            abstract: "Ensure the browser is available, then open or navigate to a URL."
        )

        @Argument(help: "URL to open")
        var url: String

        @Flag(name: .long, help: "Open in a new tab if the browser is already running")
        var newTab = false

        @Option(name: .long, help: "Browser app name")
        var app: String?

        @Flag(name: .long, help: "Activate/focus the browser after launch")
        var activate = false

        @Flag(name: .long, inversion: .prefixedNo, help: "Use an isolated browser profile for automation when launching")
        var isolated = true

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @OptionGroup
        var shared: SharedOptions

        func run() throws {
            let client = RPCClient()
            var params = Browser.baseParams(backend: shared.backend, port: shared.port)
            params["url"] = url
            params["new_tab"] = newTab
            params["activate"] = activate
            params["isolated"] = isolated
            if let app { params["app"] = app }
            let result = try client.call("browser.launch_and_open", params: params)
            if json {
                print(try jsonString(result))
            } else {
                printResult(result)
            }
        }
    }

    struct Open: ParsableCommand {
        @Argument(help: "URL to open in a new browser tab")
        var url: String

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @OptionGroup
        var shared: SharedOptions

        func run() throws {
            let client = RPCClient()
            var params = Browser.baseParams(backend: shared.backend, port: shared.port)
            params["url"] = url
            let result = try client.call("browser.open_tab", params: params)
            if json {
                print(try jsonString(result))
            } else {
                printResult(result)
            }
        }
    }

    struct ActivateTab: ParsableCommand {
        @OptionGroup
        var target: TabTargetOptions

        @OptionGroup
        var shared: SharedOptions

        func run() throws {
            let client = RPCClient()
            var params = Browser.baseParams(backend: shared.backend, port: shared.port)
            Browser.addTabTarget(tabId: target.tabId, titleContains: target.titleContains, urlContains: target.urlContains, to: &params)
            let result = try client.call("browser.activate_tab", params: params)
            printResult(result)
        }
    }

    struct Navigate: ParsableCommand {
        @Argument(help: "URL to navigate the target tab to")
        var url: String

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @OptionGroup
        var target: TabTargetOptions

        @OptionGroup
        var shared: SharedOptions

        func run() throws {
            let client = RPCClient()
            var params = Browser.baseParams(backend: shared.backend, port: shared.port)
            params["url"] = url
            Browser.addTabTarget(tabId: target.tabId, titleContains: target.titleContains, urlContains: target.urlContains, to: &params)
            let result = try client.call("browser.navigate", params: params)
            if json {
                print(try jsonString(result))
            } else {
                printResult(result)
            }
        }
    }

    struct Eval: ParsableCommand {
        @Argument(help: "JavaScript expression to evaluate in the target tab")
        var expression: String

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @OptionGroup
        var target: TabTargetOptions

        @OptionGroup
        var shared: SharedOptions

        func run() throws {
            let client = RPCClient()
            var params = Browser.baseParams(backend: shared.backend, port: shared.port)
            params["expression"] = expression
            Browser.addTabTarget(tabId: target.tabId, titleContains: target.titleContains, urlContains: target.urlContains, to: &params)
            let result = try client.call("browser.eval", params: params)
            if json {
                print(try jsonString(result))
            } else {
                printResult(result)
            }
        }
    }

    struct Click: ParsableCommand {
        @Argument(help: "CSS selector to click")
        var selector: String

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @OptionGroup
        var target: TabTargetOptions

        @OptionGroup
        var shared: SharedOptions

        func run() throws {
            let client = RPCClient()
            var params = Browser.baseParams(backend: shared.backend, port: shared.port)
            params["selector"] = selector
            Browser.addTabTarget(tabId: target.tabId, titleContains: target.titleContains, urlContains: target.urlContains, to: &params)
            let result = try client.call("browser.click", params: params)
            if json {
                print(try jsonString(result))
            } else {
                printResult(result)
            }
        }
    }

    struct TypeText: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "type")

        @Argument(help: "CSS selector to type into")
        var selector: String

        @Argument(help: "Text to set into the element")
        var text: String

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @OptionGroup
        var target: TabTargetOptions

        @OptionGroup
        var shared: SharedOptions

        func run() throws {
            let client = RPCClient()
            var params = Browser.baseParams(backend: shared.backend, port: shared.port)
            params["selector"] = selector
            params["text"] = text
            Browser.addTabTarget(tabId: target.tabId, titleContains: target.titleContains, urlContains: target.urlContains, to: &params)
            let result = try client.call("browser.type", params: params)
            if json {
                print(try jsonString(result))
            } else {
                printResult(result)
            }
        }
    }

    struct PressKey: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "press-key")

        @Argument(help: "Key to dispatch to the active element")
        var key: String

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @OptionGroup
        var target: TabTargetOptions

        @OptionGroup
        var shared: SharedOptions

        func run() throws {
            let client = RPCClient()
            var params = Browser.baseParams(backend: shared.backend, port: shared.port)
            params["key"] = key
            Browser.addTabTarget(tabId: target.tabId, titleContains: target.titleContains, urlContains: target.urlContains, to: &params)
            let result = try client.call("browser.press_key", params: params)
            if json {
                print(try jsonString(result))
            } else {
                printResult(result)
            }
        }
    }

    struct Screenshot: ParsableCommand {
        @Option(name: [.short, .long], help: "Output file path")
        var output: String?

        @Flag(name: .long, help: "Print base64 to stdout")
        var base64 = false

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @OptionGroup
        var target: TabTargetOptions

        @OptionGroup
        var shared: SharedOptions

        func run() throws {
            let client = RPCClient()
            var params = Browser.baseParams(backend: shared.backend, port: shared.port)
            if let output { params["output"] = output }
            if base64 { params["base64"] = true }
            Browser.addTabTarget(tabId: target.tabId, titleContains: target.titleContains, urlContains: target.urlContains, to: &params)
            let result = try client.call("browser.screenshot", params: params)
            if json {
                print(try jsonString(result))
            } else {
                printResult(result)
            }
        }
    }
}
