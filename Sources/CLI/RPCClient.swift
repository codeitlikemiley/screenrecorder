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
        request.timeoutInterval = 30

        var body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "id": 1,
        ]
        if let params = params {
            body["params"] = params
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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
            if nsError.code == NSURLErrorCannotConnectToHost || nsError.code == NSURLErrorNetworkConnectionLost {
                throw CLIError.appNotRunning
            }
            throw CLIError.networkError(error.localizedDescription)
        }

        guard let data = responseData else {
            throw CLIError.emptyResponse
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError.invalidResponse
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
    case networkError(String)
    case emptyResponse
    case invalidResponse
    case rpcError(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .appNotRunning:
            return "Screen Recorder is not running. Launch the app first."
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
