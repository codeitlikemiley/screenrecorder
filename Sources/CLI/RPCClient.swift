import Foundation

/// Lightweight JSON-RPC 2.0 client that talks to the running Screen Recorder app.
struct RPCClient {
    let host: String
    let port: Int

    init(host: String = "127.0.0.1", port: Int = 19820) {
        self.host = host
        self.port = port
    }

    /// Send a JSON-RPC request and return the result dictionary.
    func call(_ method: String, params: [String: Any]? = nil) throws -> [String: Any] {
        let url = URL(string: "http://\(host):\(port)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("close", forHTTPHeaderField: "Connection")
        if let token = AgentAuth.token() {
            request.setValue(token, forHTTPHeaderField: AgentAuth.header)
        }
        request.timeoutInterval = AgentAuth.timeout(method: method, params: params)

        var body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "id": 1,
        ]
        if let params = params {
            body["params"] = params
        }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        // Must set Content-Length explicitly — otherwise URLSession uses chunked
        // transfer encoding, which our raw NWConnection server doesn't handle.
        request.setValue("\(bodyData.count)", forHTTPHeaderField: "Content-Length")

        // Synchronous request using semaphore (CLI is single-threaded)
        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?

        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            responseData = data
            responseError = error
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        if let error = responseError {
            let nsError = error as NSError
            // These codes all mean the server isn't listening on the port
            let noServerCodes: Set<Int> = [
                NSURLErrorCannotConnectToHost,    // -1004
                NSURLErrorNetworkConnectionLost,  // -1005
                -1,                               // connection refused (POSIX 61)
            ]
            if noServerCodes.contains(nsError.code) {
                throw CLIError.appNotRunning
            }
            if nsError.code == NSURLErrorTimedOut {
                throw CLIError.timedOut(method)
            }
            throw CLIError.networkError(error.localizedDescription)
        }

        guard let data = responseData else {
            throw CLIError.emptyResponse
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError.invalidResponse
        }

        // HTTP-level rejections (401/403) carry a plain string error.
        if let error = json["error"] as? String {
            throw CLIError.rpcError(code: -1, message: error)
        }

        if let error = json["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown error"
            let code = error["code"] as? Int ?? -1
            throw CLIError.rpcError(code: code, message: message)
        }

        guard let result = json["result"] as? [String: Any] else {
            throw CLIError.invalidResponse
        }

        return result
    }
}

enum CLIError: LocalizedError {
    case appNotRunning
    case timedOut(String)
    case networkError(String)
    case emptyResponse
    case invalidResponse
    case rpcError(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .appNotRunning:
            return "Screen Recorder is not running. Launch the desktop app (check your menu bar)."
        case .timedOut(let method):
            return "Timed out waiting for '\(method)'. The app may still be running the action."
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .emptyResponse:
            return "Empty response from server"
        case .invalidResponse:
            return "Invalid response from server"
        case .rpcError(_, let msg):
            return msg
        }
    }
}

/// Pretty-print a result dictionary as key: value lines.
func printResult(_ result: [String: Any], indent: String = "") {
    for (key, value) in result.sorted(by: { $0.key < $1.key }) {
        if let dict = value as? [String: Any] {
            print("\(indent)\(key):")
            printResult(dict, indent: indent + "  ")
        } else if let array = value as? [[String: Any]] {
            print("\(indent)\(key):")
            for (i, item) in array.enumerated() {
                print("\(indent)  [\(i)]:")
                printResult(item, indent: indent + "    ")
            }
        } else {
            print("\(indent)\(key): \(value)")
        }
    }
}

/// Format result as JSON string.
func jsonString(_ result: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    return String(data: data, encoding: .utf8) ?? "{}"
}

/// Shared-secret + timeout helpers for talking to the app's agent server.
/// Kept in sync with `AgentServer` (token file path and header name).
enum AgentAuth {
    static let header = "X-SR-Token"

    static var tokenFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".screenrecorder", isDirectory: true)
            .appendingPathComponent("agent-token")
    }

    /// The token the running app wrote at launch, or nil if the app isn't running.
    static func token() -> String? {
        guard let data = try? Data(contentsOf: tokenFileURL),
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }

    /// Client-side timeout for an RPC. Long-running methods (shell commands, sleeps, slow typing)
    /// get enough headroom that the client doesn't give up while the app is still working.
    static func timeout(method: String, params: [String: Any]?) -> TimeInterval {
        func number(_ key: String) -> Double? {
            if let d = params?[key] as? Double { return d }
            if let i = params?[key] as? Int { return Double(i) }
            return nil
        }
        var seconds: TimeInterval = 30
        if let t = number("timeout") { seconds = max(seconds, t + 10) }
        if method == "sleep", let ms = number("ms") ?? number("duration") { seconds = max(seconds, ms / 1000 + 10) }
        if let text = params?["text"] as? String {
            let interval = number("interval_ms") ?? 50
            seconds = max(seconds, Double(text.count) * interval / 1000 + 10)
        }
        return seconds
    }
}
