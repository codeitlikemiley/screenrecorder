import Foundation

private actor WebDriverClient {
    private let baseURL: URL

    init(port: Int) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
    }

    func request(method: String, path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 10
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BrowserAutomationError.invalidResponse("WebDriver response was not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw BrowserAutomationError.invalidResponse("HTTP \(http.statusCode): \(text)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrowserAutomationError.invalidResponse("WebDriver response was not a JSON object")
        }
        if let value = json["value"] as? [String: Any],
           let error = value["error"] as? String {
            let message = value["message"] as? String ?? error
            throw BrowserAutomationError.invalidResponse("WebDriver \(error): \(message)")
        }
        return json
    }

    func status() async throws -> [String: Any] {
        try await request(method: "GET", path: "status")
    }
}

actor SafariBrowserController: BrowserController {
    let backendName = "safari"

    private var sessionID: String?
    private var serverProcess: Process?

    func status(port: Int) async throws -> [String: Any] {
        let client = WebDriverClient(port: port)
        let status = try await client.status()
        let value = status["value"] as? [String: Any] ?? [:]
        return [
            "ok": true,
            "backend": backendName,
            "reachable": true,
            "port": port,
            "ready": value["ready"] as? Bool ?? true,
            "message": (value["message"] as? String) ?? "safaridriver reachable",
            "session_active": sessionID != nil,
        ]
    }

    func launch(appName: String, port: Int, startURL: String?, activate: Bool, isolated: Bool) async throws -> [String: Any] {
        guard appName.localizedCaseInsensitiveContains("safari") else {
            throw BrowserAutomationError.unsupportedBackend("Safari backend only supports Safari.app")
        }
        try await ensureServerRunning(port: port)
        let session = try await ensureSession(port: port)
        let targetURL = (startURL?.isEmpty == false ? startURL! : "about:blank")
        _ = try await navigate(port: port, params: ["url": targetURL, "tab_id": session["current_handle"] as? String ?? ""])

        var result = try await status(port: port)
        result["launched"] = "Safari"
        result["activate"] = true
        result["isolated"] = false
        result["note"] = "Safari automation uses safaridriver/WebDriver. Safari profiles are not isolated like Chromium user-data-dir profiles."
        result["url"] = targetURL
        if activate == false {
            result["note"] = "\(result["note"] as? String ?? "") Safari may still come to the foreground when the WebDriver session starts."
        }
        return result
    }

    func listTabs(port: Int) async throws -> [[String: Any]] {
        let session = try await ensureSession(port: port)
        let client = WebDriverClient(port: port)
        guard let sessionID = session["session_id"] as? String else {
            throw BrowserAutomationError.invalidResponse("Missing Safari session id")
        }
        let handlesResponse = try await client.request(method: "GET", path: "session/\(sessionID)/window/handles")
        let handles = handlesResponse["value"] as? [String] ?? []
        let originalHandle = try await currentHandle(port: port, sessionID: sessionID)

        var tabs: [[String: Any]] = []
        for handle in handles {
            try await switchToWindow(port: port, sessionID: sessionID, handle: handle)
            let title = try await titleForCurrentWindow(port: port, sessionID: sessionID)
            let url = try await currentURL(port: port, sessionID: sessionID)
            tabs.append([
                "id": handle,
                "title": title,
                "url": url,
                "type": "page",
            ])
        }

        try await switchToWindow(port: port, sessionID: sessionID, handle: originalHandle)
        return tabs
    }

    func openTab(port: Int, url: String) async throws -> [String: Any] {
        let session = try await ensureSession(port: port)
        let client = WebDriverClient(port: port)
        guard let sessionID = session["session_id"] as? String else {
            throw BrowserAutomationError.invalidResponse("Missing Safari session id")
        }
        let newWindow = try await client.request(method: "POST", path: "session/\(sessionID)/window/new", body: ["type": "tab"])
        let value = newWindow["value"] as? [String: Any] ?? [:]
        let handle = value["handle"] as? String ?? ""
        if !handle.isEmpty {
            try await switchToWindow(port: port, sessionID: sessionID, handle: handle)
        }
        let result = try await navigate(port: port, params: ["url": url, "tab_id": handle])
        return [
            "ok": true,
            "opened": url,
            "tab": result["tab"] as? [String: Any] ?? [:],
        ]
    }

    func navigate(port: Int, params: [String: Any]) async throws -> [String: Any] {
        guard let url = params["url"] as? String, !url.isEmpty else {
            throw BrowserAutomationError.invalidArgument("Missing browser URL")
        }
        let session = try await ensureSession(port: port)
        let client = WebDriverClient(port: port)
        guard let sessionID = session["session_id"] as? String else {
            throw BrowserAutomationError.invalidResponse("Missing Safari session id")
        }
        let tab = try await resolveTab(port: port, params: params)
        try await switchToWindow(port: port, sessionID: sessionID, handle: tab["id"] as? String ?? "")
        _ = try await client.request(method: "POST", path: "session/\(sessionID)/url", body: ["url": url])
        let refreshedTab = try await resolveTab(port: port, params: ["tab_id": tab["id"] as? String ?? ""])
        return ["ok": true, "navigated": url, "tab": refreshedTab]
    }

    func evaluate(port: Int, params: [String: Any]) async throws -> [String: Any] {
        guard let expression = params["expression"] as? String, !expression.isEmpty else {
            throw BrowserAutomationError.invalidArgument("Missing JavaScript expression")
        }
        let session = try await ensureSession(port: port)
        let client = WebDriverClient(port: port)
        guard let sessionID = session["session_id"] as? String else {
            throw BrowserAutomationError.invalidResponse("Missing Safari session id")
        }
        let tab = try await resolveTab(port: port, params: params)
        try await switchToWindow(port: port, sessionID: sessionID, handle: tab["id"] as? String ?? "")

        let response = try await client.request(
            method: "POST",
            path: "session/\(sessionID)/execute/sync",
            body: [
                "script": "return (function(){ return (\(expression)); }).apply(null, arguments);",
                "args": [],
            ]
        )
        return [
            "ok": true,
            "tab": tab,
            "result": ["value": response["value"] ?? NSNull()],
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
          return { ok: true, tag: el.tagName, text: (el.innerText || el.value || "").slice(0, 200) };
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
          el.focus();
          if ("value" in el) {
            el.value = \(textLiteral);
          } else {
            el.textContent = \(textLiteral);
          }
          el.dispatchEvent(new Event("input", { bubbles: true }));
          el.dispatchEvent(new Event("change", { bubbles: true }));
          return { ok: true, tag: el.tagName, value: "value" in el ? el.value : el.textContent };
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
          return { ok: true, key: \(keyLiteral), active_tag: target.tagName || "" };
        })()
        """
        let evalResult = try await evaluate(port: port, params: params.merging(["expression": script]) { _, new in new })
        return try unwrapDOMActionResult(evalResult, action: "press_key", selector: nil)
    }

    func screenshot(port: Int, params: [String: Any]) async throws -> [String: Any] {
        let session = try await ensureSession(port: port)
        let client = WebDriverClient(port: port)
        guard let sessionID = session["session_id"] as? String else {
            throw BrowserAutomationError.invalidResponse("Missing Safari session id")
        }
        let tab = try await resolveTab(port: port, params: params)
        try await switchToWindow(port: port, sessionID: sessionID, handle: tab["id"] as? String ?? "")
        let response = try await client.request(method: "GET", path: "session/\(sessionID)/screenshot")
        guard let dataBase64 = response["value"] as? String,
              let imageData = Data(base64Encoded: dataBase64) else {
            throw BrowserAutomationError.invalidResponse("Safari screenshot did not return PNG data")
        }

        let outputPath = params["output"] as? String
        let writeURL: URL
        if let outputPath, !outputPath.isEmpty {
            writeURL = URL(fileURLWithPath: outputPath)
        } else {
            writeURL = FileManager.default.temporaryDirectory.appendingPathComponent("safari_\(Int(Date().timeIntervalSince1970)).png")
        }
        try imageData.write(to: writeURL)

        var result: [String: Any] = [
            "ok": true,
            "file": writeURL.path,
            "size_bytes": imageData.count,
            "tab": tab,
        ]
        if params["base64"] as? Bool == true || outputPath == nil {
            result["base64"] = dataBase64
        }
        return result
    }

    func activateTab(port: Int, params: [String: Any]) async throws -> [String: Any] {
        let session = try await ensureSession(port: port)
        guard let sessionID = session["session_id"] as? String else {
            throw BrowserAutomationError.invalidResponse("Missing Safari session id")
        }
        let tab = try await resolveTab(port: port, params: params)
        try await switchToWindow(port: port, sessionID: sessionID, handle: tab["id"] as? String ?? "")
        return ["ok": true, "tab": tab]
    }

    private func ensureServerRunning(port: Int) async throws {
        let client = WebDriverClient(port: port)
        if (try? await client.status()) != nil {
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/System/Cryptexes/App/usr/bin/safaridriver")
        process.arguments = ["-p", "\(port)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        serverProcess = process

        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if (try? await client.status()) != nil {
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        throw BrowserAutomationError.browserNotReachable(port)
    }

    private func ensureSession(port: Int) async throws -> [String: Any] {
        try await ensureServerRunning(port: port)
        let client = WebDriverClient(port: port)
        if let sessionID {
            return [
                "session_id": sessionID,
                "current_handle": try await currentHandle(port: port, sessionID: sessionID),
            ]
        }

        let response = try await client.request(
            method: "POST",
            path: "session",
            body: [
                "capabilities": [
                    "alwaysMatch": [
                        "browserName": "safari",
                    ],
                ],
            ]
        )

        let value = response["value"] as? [String: Any] ?? [:]
        let newSessionID = (response["sessionId"] as? String) ?? (value["sessionId"] as? String)
        guard let newSessionID, !newSessionID.isEmpty else {
            throw BrowserAutomationError.invalidResponse("Could not create Safari WebDriver session. You may need to run 'safaridriver --enable' once.")
        }
        self.sessionID = newSessionID
        return [
            "session_id": newSessionID,
            "current_handle": try await currentHandle(port: port, sessionID: newSessionID),
        ]
    }

    private func currentHandle(port: Int, sessionID: String) async throws -> String {
        let client = WebDriverClient(port: port)
        let response = try await client.request(method: "GET", path: "session/\(sessionID)/window")
        return response["value"] as? String ?? ""
    }

    private func currentURL(port: Int, sessionID: String) async throws -> String {
        let client = WebDriverClient(port: port)
        let response = try await client.request(method: "GET", path: "session/\(sessionID)/url")
        return response["value"] as? String ?? ""
    }

    private func titleForCurrentWindow(port: Int, sessionID: String) async throws -> String {
        let client = WebDriverClient(port: port)
        let response = try await client.request(method: "GET", path: "session/\(sessionID)/title")
        return response["value"] as? String ?? ""
    }

    private func switchToWindow(port: Int, sessionID: String, handle: String) async throws {
        let client = WebDriverClient(port: port)
        _ = try await client.request(method: "POST", path: "session/\(sessionID)/window", body: ["handle": handle])
    }

    private func resolveTab(port: Int, params: [String: Any]) async throws -> [String: Any] {
        let tabs = try await listTabs(port: port)
        if let tabID = params["tab_id"] as? String,
           let tab = tabs.first(where: { ($0["id"] as? String ?? "") == tabID }) {
            return tab
        }
        if let titleContains = params["title_contains"] as? String, !titleContains.isEmpty,
           let tab = tabs.first(where: { ($0["title"] as? String ?? "").localizedCaseInsensitiveContains(titleContains) }) {
            return tab
        }
        if let urlContains = params["url_contains"] as? String, !urlContains.isEmpty,
           let tab = tabs.first(where: { ($0["url"] as? String ?? "").localizedCaseInsensitiveContains(urlContains) }) {
            return tab
        }
        if let first = tabs.first {
            return first
        }
        throw BrowserAutomationError.tabNotFound
    }

    private func jsStringLiteral(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value])
        guard let arrayLiteral = String(data: data, encoding: .utf8),
              arrayLiteral.count >= 2 else {
            throw BrowserAutomationError.invalidArgument("Could not encode JavaScript string literal")
        }
        return String(arrayLiteral.dropFirst().dropLast())
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
