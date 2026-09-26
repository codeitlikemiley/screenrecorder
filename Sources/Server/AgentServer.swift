import Foundation
import Network
import Security

/// Lightweight JSON-RPC 2.0 server over HTTP using Network.framework.
/// Listens on localhost only — no external access.
/// Zero external dependencies — uses only built-in macOS frameworks.
///
/// Security model: loopback alone is not enough, because any web page in the user's
/// browser can POST to localhost. Every JSON-RPC request must therefore carry the
/// per-launch secret from `~/.screenrecorder/agent-token` (readable only by this user)
/// in the `X-SR-Token` header. Requests carrying an `Origin` header (i.e. from a browser)
/// or a non-loopback `Host` header (DNS rebinding) are rejected outright.
@MainActor
class AgentServer {
    private var listener: NWListener?
    private let port: UInt16
    private var handler: AgentRouter?
    private var token: String = ""

    /// Header clients (`sr`, `sr-mcp`) use to send the token.
    static let tokenHeader = "x-sr-token"

    /// Where the per-launch token is written. Must match the path used by `sr` and `sr-mcp`.
    static var tokenFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".screenrecorder", isDirectory: true)
            .appendingPathComponent("agent-token")
    }

    var isRunning: Bool { listener != nil }

    init(port: UInt16 = 19820) {
        self.port = port
    }

    // MARK: - Start / Stop

    func start(router: AgentRouter) {
        guard listener == nil else { return }
        self.handler = router

        do {
            try installToken()
        } catch {
            // Without a token file no client could authenticate — refuse to run an open server.
            print("🤖 Agent server not started: could not write token file: \(error)")
            return
        }

        do {
            let params = NWParameters.tcp
            // Restrict to localhost only
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: port)!
            )

            let nwListener = try NWListener(using: params)
            nwListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("🤖 Agent server listening on http://localhost:\(self?.port ?? 0)")
                case .failed(let error):
                    print("🤖 Agent server failed: \(error)")
                    Task { @MainActor in
                        self?.stop()
                    }
                default:
                    break
                }
            }

            nwListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleConnection(connection)
                }
            }

            nwListener.start(queue: .main)
            self.listener = nwListener
        } catch {
            print("🤖 Agent server failed to start: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        handler = nil
        try? FileManager.default.removeItem(at: Self.tokenFileURL)
        print("🤖 Agent server stopped")
    }

    // MARK: - Token

    /// Generate a fresh random token and write it to `tokenFileURL` with 0600 permissions.
    private func installToken() throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NSError(domain: "AgentServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "SecRandomCopyBytes failed"])
        }
        let newToken = bytes.map { String(format: "%02x", $0) }.joined()

        let fm = FileManager.default
        let url = Self.tokenFileURL
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: Data(newToken.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw NSError(domain: "AgentServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create \(url.path)"])
        }
        token = newToken
    }

    /// Constant-time comparison so the token can't be recovered by timing.
    private func tokenMatches(_ candidate: String?) -> Bool {
        guard let candidate, !token.isEmpty else { return false }
        let a = Array(candidate.utf8), b = Array(token.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    /// Parse header lines into a lowercased-name dictionary.
    private func parseHeaders(_ headerPart: Substring) -> [String: String] {
        var headers: [String: String] = [:]
        for line in headerPart.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return headers
    }

    /// Only loopback host names are accepted (defeats DNS-rebinding attacks).
    private func isLoopbackHost(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return true } // HTTP/1.0 clients may omit Host
        var name = host.lowercased()
        if name.hasPrefix("[") {
            name = String(name.prefix(while: { $0 != "]" }).dropFirst())
        } else if let colon = name.lastIndex(of: ":") {
            name = String(name[..<colon])
        }
        return name == "localhost" || name == "127.0.0.1" || name == "::1"
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                print("🤖 Connection failed: \(error)")
                connection.cancel()
            default:
                break
            }
        }

        connection.start(queue: .main)
        receiveHTTPRequest(connection)
    }

    private func receiveHTTPRequest(_ connection: NWConnection) {
        receiveAccumulating(connection: connection, buffer: Data())
    }

    /// Accumulate TCP data until we have the complete HTTP request (headers + body).
    private func receiveAccumulating(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            if let error = error {
                print("🤖 Receive error: \(error)")
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let data = data, !data.isEmpty {
                accumulated.append(data)
            }

            // Try to parse what we have so far
            guard let request = String(data: accumulated, encoding: .utf8) else {
                if isComplete { connection.cancel() }
                return
            }

            // Check if we have the full headers (double CRLF)
            guard request.contains("\r\n\r\n") else {
                // Headers not complete yet — keep reading
                if isComplete { connection.cancel() }
                else { Task { @MainActor [weak self] in self?.receiveAccumulating(connection: connection, buffer: accumulated) } }
                return
            }

            // Parse Content-Length to know if we have the full body
            let headerPart = request.components(separatedBy: "\r\n\r\n").first ?? ""
            let headerLines = headerPart.components(separatedBy: "\r\n")
            var contentLength = 0
            for line in headerLines {
                let lower = line.lowercased()
                if lower.hasPrefix("content-length:") {
                    let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                    contentLength = Int(value) ?? 0
                }
            }

            // Calculate how many body bytes we've received
            let headerEndRange = request.range(of: "\r\n\r\n")!
            let bodyStart = request.distance(from: request.startIndex, to: headerEndRange.upperBound)
            let receivedBodyBytes = accumulated.count - bodyStart

            if receivedBodyBytes >= contentLength {
                // We have the full message — process it
                Task { @MainActor in
                    await self?.processHTTPData(accumulated, connection: connection)
                }
            } else {
                // Need more data
                Task { @MainActor [weak self] in self?.receiveAccumulating(connection: connection, buffer: accumulated) }
            }
        }
    }


    private func processHTTPData(_ data: Data, connection: NWConnection) async {
        guard let request = String(data: data, encoding: .utf8) else {
            sendHTTPResponse(connection, status: 400, body: #"{"error":"Invalid request encoding"}"#)
            return
        }

        // Parse HTTP: extract body (after double CRLF)
        guard let bodyRange = request.range(of: "\r\n\r\n") else {
            sendHTTPResponse(connection, status: 400, body: #"{"error":"Malformed HTTP request"}"#)
            return
        }

        let body = String(request[bodyRange.upperBound...])
        let headers = parseHeaders(request[..<bodyRange.lowerBound])

        // Browsers always attach Origin to cross-site fetches; legitimate clients (sr, sr-mcp) never do.
        if headers["origin"] != nil {
            sendHTTPResponse(connection, status: 403, body: #"{"error":"Browser requests are not allowed"}"#)
            return
        }
        guard isLoopbackHost(headers["host"]) else {
            sendHTTPResponse(connection, status: 403, body: #"{"error":"Invalid Host header"}"#)
            return
        }

        // Check method
        let firstLine = request.prefix(while: { $0 != "\r" && $0 != "\n" })
        if firstLine.hasPrefix("GET") {
            // Health check
            let status: [String: Any] = [
                "service": "screenrecorder-agent",
                "version": "1.0.0",
                "status": "ok"
            ]
            if let json = try? JSONSerialization.data(withJSONObject: status),
               let str = String(data: json, encoding: .utf8) {
                sendHTTPResponse(connection, status: 200, body: str)
            }
            return
        }

        guard firstLine.hasPrefix("POST") else {
            sendHTTPResponse(connection, status: 405, body: #"{"error":"Method not allowed. Use POST for JSON-RPC."}"#)
            return
        }

        guard tokenMatches(headers[Self.tokenHeader]) else {
            sendHTTPResponse(connection, status: 401, body: #"{"error":"Missing or invalid X-SR-Token. Read it from ~/.screenrecorder/agent-token."}"#)
            return
        }

        // Handle JSON-RPC
        let responseBody = await handleJSONRPC(body)
        sendHTTPResponse(connection, status: 200, body: responseBody)
    }

    // MARK: - JSON-RPC 2.0

    private func handleJSONRPC(_ body: String) async -> String {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return jsonRPCError(id: nil, code: -32700, message: "Parse error")
        }

        guard let method = json["method"] as? String else {
            return jsonRPCError(id: json["id"], code: -32600, message: "Invalid request: missing 'method'")
        }

        let params = json["params"] as? [String: Any]
        let id = json["id"]

        do {
            let result = try await handler?.dispatch(method: method, params: params) ?? [:]
            return jsonRPCResponse(id: id, result: result)
        } catch {
            return jsonRPCError(id: id, code: -32000, message: error.localizedDescription)
        }
    }

    private func jsonRPCResponse(id: Any?, result: [String: Any]) -> String {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result
        ]
        if let id = id { response["id"] = id }
        return serializeJSON(response)
    }

    private func jsonRPCError(id: Any?, code: Int, message: String) -> String {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message] as [String: Any]
        ]
        if let id = id { response["id"] = id }
        return serializeJSON(response)
    }

    private func serializeJSON(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return #"{"jsonrpc":"2.0","error":{"code":-32603,"message":"Internal serialization error"}}"#
        }
        return str
    }

    // MARK: - HTTP Response

    private func sendHTTPResponse(_ connection: NWConnection, status: Int, body: String) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 403: statusText = "Forbidden"
        case 405: statusText = "Method Not Allowed"
        default: statusText = "Error"
        }

        let bodyData = body.data(using: .utf8) ?? Data()
        let headers = [
            "HTTP/1.1 \(status) \(statusText)",
            "Content-Type: application/json",
            "Content-Length: \(bodyData.count)",
            "Connection: close",
            "", ""
        ].joined(separator: "\r\n")

        var responseData = headers.data(using: .utf8)!
        responseData.append(bodyData)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
