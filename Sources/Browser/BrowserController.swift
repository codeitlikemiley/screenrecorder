import AppKit
import Foundation

protocol BrowserController {
    var backendName: String { get }
    func status(port: Int) async throws -> [String: Any]
    func launch(appName: String, port: Int, startURL: String?, activate: Bool, isolated: Bool) async throws -> [String: Any]
    func listTabs(port: Int) async throws -> [[String: Any]]
    func openTab(port: Int, url: String) async throws -> [String: Any]
    func navigate(port: Int, params: [String: Any]) async throws -> [String: Any]
    func evaluate(port: Int, params: [String: Any]) async throws -> [String: Any]
    func click(port: Int, params: [String: Any]) async throws -> [String: Any]
    func type(port: Int, params: [String: Any]) async throws -> [String: Any]
    func pressKey(port: Int, params: [String: Any]) async throws -> [String: Any]
    func screenshot(port: Int, params: [String: Any]) async throws -> [String: Any]
    func activateTab(port: Int, params: [String: Any]) async throws -> [String: Any]
}

enum BrowserAutomationError: LocalizedError {
    case unsupportedBackend(String)
    case browserNotReachable(Int)
    case browserAppNotFound(String)
    case invalidResponse(String)
    case missingWebSocketDebuggerURL
    case tabNotFound
    case cdpError(String)
    case javascriptError(String)
    case invalidArgument(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedBackend(let backend):
            return "Unsupported browser backend '\(backend)'. Supported backends: 'chromium', 'safari'."
        case .browserNotReachable(let port):
            return "No browser DevTools endpoint is reachable on port \(port). Launch a Chromium browser with remote debugging enabled."
        case .browserAppNotFound(let name):
            return "Browser app '\(name)' was not found."
        case .invalidResponse(let message):
            return "Browser controller received an invalid response: \(message)"
        case .missingWebSocketDebuggerURL:
            return "Browser DevTools endpoint did not provide a WebSocket debugger URL."
        case .tabNotFound:
            return "Browser tab not found."
        case .cdpError(let message):
            return "Browser DevTools error: \(message)"
        case .javascriptError(let message):
            return "Browser JavaScript error: \(message)"
        case .invalidArgument(let message):
            return "Invalid browser argument: \(message)"
        }
    }
}

private struct BrowserTabInfo {
    let id: String
    let title: String
    let url: String
    let type: String
    let webSocketDebuggerURL: URL?

    init?(dict: [String: Any]) {
        guard let id = dict["id"] as? String else { return nil }
        self.id = id
        self.title = dict["title"] as? String ?? ""
        self.url = dict["url"] as? String ?? ""
        self.type = dict["type"] as? String ?? "page"
        if let wsRaw = dict["webSocketDebuggerUrl"] as? String {
            self.webSocketDebuggerURL = URL(string: wsRaw)
        } else {
            self.webSocketDebuggerURL = nil
        }
    }

    var isPage: Bool { type == "page" }

    var dictionary: [String: Any] {
        [
            "id": id,
            "title": title,
            "url": url,
            "type": type,
            "websocket_debugger_url": webSocketDebuggerURL?.absoluteString ?? "",
        ]
    }
}

private actor CDPConnection {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private var nextID: Int = 1

    init(url: URL) {
        self.session = URLSession(configuration: .ephemeral)
        self.task = session.webSocketTask(with: url)
        self.task.resume()
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    func call(method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        let id = nextID
        nextID += 1

        var payload: [String: Any] = [
            "id": id,
            "method": method,
        ]
        if !params.isEmpty {
            payload["params"] = params
        }

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw BrowserAutomationError.invalidResponse("Could not encode CDP request")
        }

        try await task.send(.string(text))

        while true {
            let message = try await task.receive()
            let data: Data
            switch message {
            case .string(let string):
                guard let stringData = string.data(using: .utf8) else { continue }
                data = stringData
            case .data(let binary):
                data = binary
            @unknown default:
                continue
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if let responseID = json["id"] as? Int, responseID == id {
                if let error = json["error"] as? [String: Any] {
                    let message = error["message"] as? String ?? "Unknown CDP error"
                    throw BrowserAutomationError.cdpError(message)
                }
                return json["result"] as? [String: Any] ?? [:]
            }
        }
    }
}

actor ChromiumBrowserController: BrowserController {
    let backendName = "chromium"

    func status(port: Int) async throws -> [String: Any] {
        let version = try await browserVersion(port: port)
        let tabs = try await listTabs(port: port)
        return [
            "ok": true,
            "backend": backendName,
            "reachable": true,
            "port": port,
            "browser": version["Browser"] as? String ?? "",
            "protocol_version": version["Protocol-Version"] as? String ?? "",
            "user_agent": version["User-Agent"] as? String ?? "",
            "tab_count": tabs.count,
        ]
    }

    func launch(appName: String, port: Int, startURL: String?, activate: Bool, isolated: Bool) async throws -> [String: Any] {
        let appURL = try findBrowserApp(named: appName)
        let profileURL = isolated ? isolatedProfileDirectory(appName: appName, port: port) : nil
        if let profileURL {
            try FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        configuration.createsNewApplicationInstance = isolated

        var args = [
            "--remote-debugging-port=\(port)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-session-crashed-bubble",
        ]
        if let profileURL {
            args.append("--user-data-dir=\(profileURL.path)")
        }
        if let startURL, !startURL.isEmpty {
            args.append(startURL)
        } else {
            args.append("about:blank")
        }
        configuration.arguments = args

        let openResult = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)

        try await waitUntilReachable(port: port, timeoutMs: 8_000)

        var result = try await status(port: port)
        result["launched"] = appName
        result["activate"] = activate
        result["isolated"] = isolated
        if let profileURL {
            result["profile_dir"] = profileURL.path
        }
        if let startURL {
            result["url"] = startURL
        }
        result["pid"] = openResult.processIdentifier
        return result
    }

    func listTabs(port: Int) async throws -> [[String: Any]] {
        let json = try await getJSONArray(path: "/json/list", port: port)
        let tabs = json.compactMap { BrowserTabInfo(dict: $0) }.filter(\.isPage)
        return tabs.map(\.dictionary)
    }

    func openTab(port: Int, url: String) async throws -> [String: Any] {
        let browserSocket = try await browserWebSocketURL(port: port)
        let cdp = CDPConnection(url: browserSocket)
        defer { Task { await cdp.close() } }
        let result = try await cdp.call(method: "Target.createTarget", params: ["url": url])
        guard let targetID = result["targetId"] as? String else {
            throw BrowserAutomationError.invalidResponse("Target.createTarget did not return targetId")
        }
        let tab = try await resolveTab(port: port, params: ["tab_id": targetID])
        return [
            "ok": true,
            "opened": url,
            "tab": tab.dictionary,
        ]
    }

    func navigate(port: Int, params: [String: Any]) async throws -> [String: Any] {
        guard let url = params["url"] as? String, !url.isEmpty else {
            throw BrowserAutomationError.invalidArgument("Missing browser URL")
        }
        let tab = try await resolveTab(port: port, params: params)
        let socketURL = try tabSocketURL(for: tab)
        let cdp = CDPConnection(url: socketURL)
        defer { Task { await cdp.close() } }

        _ = try await cdp.call(method: "Page.enable")
        let result = try await cdp.call(method: "Page.navigate", params: ["url": url])
        let frameID = result["frameId"] as? String ?? ""
        try await waitForDocumentReady(cdp: cdp)

        let refreshedTab = try await resolveTab(port: port, params: ["tab_id": tab.id])
        return [
            "ok": true,
            "navigated": url,
            "frame_id": frameID,
            "tab": refreshedTab.dictionary,
        ]
    }

    func evaluate(port: Int, params: [String: Any]) async throws -> [String: Any] {
        guard let expression = params["expression"] as? String, !expression.isEmpty else {
            throw BrowserAutomationError.invalidArgument("Missing JavaScript expression")
        }
        let tab = try await resolveTab(port: port, params: params)
        let socketURL = try tabSocketURL(for: tab)
        let cdp = CDPConnection(url: socketURL)
        defer { Task { await cdp.close() } }

        let result = try await cdp.call(
            method: "Runtime.evaluate",
            params: [
                "expression": expression,
                "returnByValue": true,
                "awaitPromise": true,
            ]
        )

        if let exception = result["exceptionDetails"] as? [String: Any] {
            let exceptionText = exception["text"] as? String ?? "JavaScript evaluation failed"
            throw BrowserAutomationError.javascriptError(exceptionText)
        }

        let remoteResult = result["result"] as? [String: Any] ?? [:]
        return [
            "ok": true,
            "tab": tab.dictionary,
            "result": normalizeRemoteResult(remoteResult),
        ]
    }

    func click(port: Int, params: [String: Any]) async throws -> [String: Any] {
        guard let selector = params["selector"] as? String, !selector.isEmpty else {
            throw BrowserAutomationError.invalidArgument("Missing CSS selector")
        }
        let selectorLiteral = try jsStringLiteral(selector)
        let script = """
        (() => {
          const el = document.querySelector(\(selectorLiteral));
          if (!el) return { ok: false, error: "Selector not found" };
          el.scrollIntoView({ block: "center", inline: "center" });
          el.click();
          return {
            ok: true,
            tag: el.tagName,
            text: (el.innerText || el.value || "").slice(0, 200)
          };
        })()
        """
        let evalResult = try await evaluate(port: port, params: params.merging(["expression": script]) { _, new in new })
        return try unwrapDOMActionResult(evalResult, action: "click", selector: selector)
    }

    func type(port: Int, params: [String: Any]) async throws -> [String: Any] {
        guard let selector = params["selector"] as? String, !selector.isEmpty else {
            throw BrowserAutomationError.invalidArgument("Missing CSS selector")
        }
        guard let text = params["text"] as? String else {
            throw BrowserAutomationError.invalidArgument("Missing text to type")
        }
        let selectorLiteral = try jsStringLiteral(selector)
        let textLiteral = try jsStringLiteral(text)
        let script = """
        (() => {
          const el = document.querySelector(\(selectorLiteral));
          if (!el) return { ok: false, error: "Selector not found" };
          el.scrollIntoView({ block: "center", inline: "center" });
          el.focus();
          if ("value" in el) {
            el.value = \(textLiteral);
          } else {
            el.textContent = \(textLiteral);
          }
          el.dispatchEvent(new Event("input", { bubbles: true }));
          el.dispatchEvent(new Event("change", { bubbles: true }));
          return {
            ok: true,
            tag: el.tagName,
            value: "value" in el ? el.value : el.textContent
          };
        })()
        """
        let evalResult = try await evaluate(port: port, params: params.merging(["expression": script]) { _, new in new })
        return try unwrapDOMActionResult(evalResult, action: "type", selector: selector)
    }

    func pressKey(port: Int, params: [String: Any]) async throws -> [String: Any] {
        guard let key = params["key"] as? String, !key.isEmpty else {
            throw BrowserAutomationError.invalidArgument("Missing browser key")
        }
        let keyLiteral = try jsStringLiteral(key)
        let script = """
        (() => {
          const target = document.activeElement || document.body;
          const eventInit = { key: \(keyLiteral), bubbles: true, cancelable: true };
          target.dispatchEvent(new KeyboardEvent("keydown", eventInit));
          target.dispatchEvent(new KeyboardEvent("keypress", eventInit));
          target.dispatchEvent(new KeyboardEvent("keyup", eventInit));
          return {
            ok: true,
            key: \(keyLiteral),
            active_tag: target.tagName || ""
          };
        })()
        """
        let evalResult = try await evaluate(port: port, params: params.merging(["expression": script]) { _, new in new })
        return try unwrapDOMActionResult(evalResult, action: "press_key", selector: nil)
    }

    func screenshot(port: Int, params: [String: Any]) async throws -> [String: Any] {
        let tab = try await resolveTab(port: port, params: params)
        let socketURL = try tabSocketURL(for: tab)
        let cdp = CDPConnection(url: socketURL)
        defer { Task { await cdp.close() } }

        _ = try await cdp.call(method: "Page.enable")
        let result = try await cdp.call(method: "Page.captureScreenshot", params: ["format": "png", "fromSurface": true])
        guard let dataBase64 = result["data"] as? String,
              let imageData = Data(base64Encoded: dataBase64) else {
            throw BrowserAutomationError.invalidResponse("Page.captureScreenshot did not return PNG data")
        }

        let outputPath = params["output"] as? String
        let writeURL: URL
        if let outputPath, !outputPath.isEmpty {
            writeURL = URL(fileURLWithPath: outputPath)
        } else {
            writeURL = FileManager.default.temporaryDirectory.appendingPathComponent("browser_\(Int(Date().timeIntervalSince1970)).png")
        }
        try imageData.write(to: writeURL)

        var response: [String: Any] = [
            "ok": true,
            "file": writeURL.path,
            "size_bytes": imageData.count,
            "tab": tab.dictionary,
        ]
        if params["base64"] as? Bool == true || outputPath == nil {
            response["base64"] = dataBase64
        }
        return response
    }

    func activateTab(port: Int, params: [String: Any]) async throws -> [String: Any] {
        let tab = try await resolveTab(port: port, params: params)
        let path = "/json/activate/\(tab.id)"
        _ = try await getJSON(path: path, port: port)
        return ["ok": true, "tab": tab.dictionary]
    }

    private func browserVersion(port: Int) async throws -> [String: Any] {
        try await getJSON(path: "/json/version", port: port)
    }

    private func browserWebSocketURL(port: Int) async throws -> URL {
        let version = try await browserVersion(port: port)
        guard let raw = version["webSocketDebuggerUrl"] as? String,
              let url = URL(string: raw) else {
            throw BrowserAutomationError.missingWebSocketDebuggerURL
        }
        return url
    }

    private func resolveTab(port: Int, params: [String: Any]) async throws -> BrowserTabInfo {
        let tabs = try await getJSONArray(path: "/json/list", port: port)
            .compactMap { BrowserTabInfo(dict: $0) }
            .filter(\.isPage)

        if let tabID = params["tab_id"] as? String,
           let tab = tabs.first(where: { $0.id == tabID }) {
            return tab
        }
        if let titleContains = params["title_contains"] as? String, !titleContains.isEmpty,
           let tab = tabs.first(where: { $0.title.localizedCaseInsensitiveContains(titleContains) }) {
            return tab
        }
        if let urlContains = params["url_contains"] as? String, !urlContains.isEmpty,
           let tab = tabs.first(where: { $0.url.localizedCaseInsensitiveContains(urlContains) }) {
            return tab
        }
        if let first = tabs.first {
            return first
        }
        throw BrowserAutomationError.tabNotFound
    }

    private func tabSocketURL(for tab: BrowserTabInfo) throws -> URL {
        guard let url = tab.webSocketDebuggerURL else {
            throw BrowserAutomationError.missingWebSocketDebuggerURL
        }
        return url
    }

    private func waitUntilReachable(port: Int, timeoutMs: Int) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if (try? await browserVersion(port: port)) != nil {
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw BrowserAutomationError.browserNotReachable(port)
    }

    private func waitForDocumentReady(cdp: CDPConnection) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let result = try await cdp.call(
                method: "Runtime.evaluate",
                params: [
                    "expression": "document.readyState",
                    "returnByValue": true,
                ]
            )
            let remoteResult = result["result"] as? [String: Any] ?? [:]
            if let state = remoteResult["value"] as? String, state == "complete" || state == "interactive" {
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func findBrowserApp(named name: String) throws -> URL {
        if let directURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
            return directURL
        }

        let searchDirs = [
            "/Applications",
            NSString(string: "~/Applications").expandingTildeInPath,
        ]

        for dir in searchDirs {
            let appURL = URL(fileURLWithPath: dir).appendingPathComponent("\(name).app")
            if FileManager.default.fileExists(atPath: appURL.path) {
                return appURL
            }
        }

        for dir in searchDirs {
            let folder = URL(fileURLWithPath: dir)
            if let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                if let match = urls.first(where: {
                    $0.pathExtension == "app" && $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(name)
                }) {
                    return match
                }
            }
        }

        throw BrowserAutomationError.browserAppNotFound(name)
    }

    private func isolatedProfileDirectory(appName: String, port: Int) -> URL {
        let safeName = appName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenRecorderBrowserProfiles", isDirectory: true)
            .appendingPathComponent("\(safeName)-\(port)", isDirectory: true)
    }

    private func getJSON(path: String, port: Int) async throws -> [String: Any] {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BrowserAutomationError.browserNotReachable(port)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrowserAutomationError.invalidResponse("Expected JSON object at \(path)")
        }
        return json
    }

    private func getJSONArray(path: String, port: Int) async throws -> [[String: Any]] {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BrowserAutomationError.browserNotReachable(port)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw BrowserAutomationError.invalidResponse("Expected JSON array at \(path)")
        }
        return json
    }

    private func jsStringLiteral(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value])
        guard let arrayLiteral = String(data: data, encoding: .utf8),
              arrayLiteral.count >= 2 else {
            throw BrowserAutomationError.invalidArgument("Could not encode JavaScript string literal")
        }
        return String(arrayLiteral.dropFirst().dropLast())
    }

    private func normalizeRemoteResult(_ remoteResult: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        if let type = remoteResult["type"] as? String {
            result["type"] = type
        }
        if let subtype = remoteResult["subtype"] as? String {
            result["subtype"] = subtype
        }
        if let value = remoteResult["value"] {
            result["value"] = value
        }
        if let description = remoteResult["description"] as? String {
            result["description"] = description
        }
        if let unserializable = remoteResult["unserializableValue"] as? String {
            result["unserializable_value"] = unserializable
        }
        return result
    }

    private func unwrapDOMActionResult(_ evalResult: [String: Any], action: String, selector: String?) throws -> [String: Any] {
        let result = evalResult["result"] as? [String: Any] ?? [:]
        let payload = result["value"] as? [String: Any] ?? [:]
        if let ok = payload["ok"] as? Bool, ok == false {
            let message = payload["error"] as? String ?? "Browser \(action) failed"
            throw BrowserAutomationError.javascriptError(message)
        }
        var response: [String: Any] = [
            "ok": true,
            "action": action,
            "result": payload,
        ]
        if let selector {
            response["selector"] = selector
        }
        response["tab"] = evalResult["tab"] as? [String: Any] ?? [:]
        return response
    }
}

actor BrowserAutomationManager {
    static let shared = BrowserAutomationManager()

    private let chromium = ChromiumBrowserController()
    private let safari = SafariBrowserController()

    private func controller(for params: [String: Any]?) throws -> any BrowserController {
        let backend = (params?["backend"] as? String ?? "chromium").lowercased()
        switch backend {
        case "chromium":
            return chromium
        case "safari":
            return safari
        default:
            throw BrowserAutomationError.unsupportedBackend(backend)
        }
    }

    private func port(from params: [String: Any]?) -> Int {
        params?["port"] as? Int ?? 9222
    }

    func status(params: [String: Any]?) async throws -> [String: Any] {
        try await controller(for: params).status(port: port(from: params))
    }

    func launch(params: [String: Any]?) async throws -> [String: Any] {
        let controller = try controller(for: params)
        let defaultAppName = controller.backendName == "safari" ? "Safari" : "Google Chrome"
        let appName = params?["app"] as? String ?? defaultAppName
        let url = params?["url"] as? String
        let activate = params?["activate"] as? Bool ?? false
        let isolated = params?["isolated"] as? Bool ?? true
        return try await controller.launch(
            appName: appName,
            port: port(from: params),
            startURL: url,
            activate: activate,
            isolated: isolated
        )
    }

    func launchAndOpen(params: [String: Any]?) async throws -> [String: Any] {
        let controller = try controller(for: params)
        let port = port(from: params)
        let defaultAppName = controller.backendName == "safari" ? "Safari" : "Google Chrome"
        let appName = params?["app"] as? String ?? defaultAppName
        let url = params?["url"] as? String
        let activate = params?["activate"] as? Bool ?? false
        let isolated = params?["isolated"] as? Bool ?? true
        let newTab = params?["new_tab"] as? Bool ?? false

        if (try? await controller.status(port: port)) == nil {
            var launched = try await controller.launch(
                appName: appName,
                port: port,
                startURL: url,
                activate: activate,
                isolated: isolated
            )
            launched["operation"] = "launch_and_open"
            return launched
        }

        guard let url, !url.isEmpty else {
            var status = try await controller.status(port: port)
            status["operation"] = "launch_and_open"
            status["launched"] = false
            return status
        }

        let result = if newTab {
            try await controller.openTab(port: port, url: url)
        } else {
            try await controller.navigate(port: port, params: params ?? [:])
        }

        var enriched = result
        enriched["operation"] = "launch_and_open"
        enriched["launched"] = false
        enriched["backend"] = controller.backendName
        enriched["port"] = port
        return enriched
    }

    func listTabs(params: [String: Any]?) async throws -> [String: Any] {
        let controller = try controller(for: params)
        let tabs = try await controller.listTabs(port: port(from: params))
        return ["ok": true, "backend": controller.backendName, "port": port(from: params), "tabs": tabs, "count": tabs.count]
    }

    func openTab(params: [String: Any]?) async throws -> [String: Any] {
        guard let url = params?["url"] as? String else {
            throw BrowserAutomationError.invalidArgument("Missing browser URL")
        }
        return try await controller(for: params).openTab(port: port(from: params), url: url)
    }

    func navigate(params: [String: Any]?) async throws -> [String: Any] {
        try await controller(for: params).navigate(port: port(from: params), params: params ?? [:])
    }

    func evaluate(params: [String: Any]?) async throws -> [String: Any] {
        try await controller(for: params).evaluate(port: port(from: params), params: params ?? [:])
    }

    func click(params: [String: Any]?) async throws -> [String: Any] {
        try await controller(for: params).click(port: port(from: params), params: params ?? [:])
    }

    func type(params: [String: Any]?) async throws -> [String: Any] {
        try await controller(for: params).type(port: port(from: params), params: params ?? [:])
    }

    func pressKey(params: [String: Any]?) async throws -> [String: Any] {
        try await controller(for: params).pressKey(port: port(from: params), params: params ?? [:])
    }

    func screenshot(params: [String: Any]?) async throws -> [String: Any] {
        try await controller(for: params).screenshot(port: port(from: params), params: params ?? [:])
    }

    func activateTab(params: [String: Any]?) async throws -> [String: Any] {
        try await controller(for: params).activateTab(port: port(from: params), params: params ?? [:])
    }
}
