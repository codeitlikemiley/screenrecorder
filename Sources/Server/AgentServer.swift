import Foundation
import Network

/// Lightweight JSON-RPC 2.0 server over HTTP using Network.framework.
/// Listens on localhost only — no external access.
/// Zero external dependencies — uses only built-in macOS frameworks.
@MainActor
class AgentServer {
    private var listener: NWListener?
    private let port: UInt16
    private var handler: AgentRouter?

    var isRunning: Bool { listener != nil }

    init(port: UInt16 = 19820) {
        self.port = port
    }

    // MARK: - Start / Stop

    func start(router: AgentRouter) {
        guard listener == nil else { return }
        self.handler = router

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
        print("🤖 Agent server stopped")
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
        // Read up to 1MB of data
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            if let error = error {
                print("🤖 Receive error: \(error)")
                connection.cancel()
                return
            }

            guard let data = data, !data.isEmpty else {
                if isComplete { connection.cancel() }
                return
            }

            Task { @MainActor in
                await self?.processHTTPData(data, connection: connection)
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
        case 405: statusText = "Method Not Allowed"
        default: statusText = "Error"
        }

        let bodyData = body.data(using: .utf8) ?? Data()
        let headers = [
            "HTTP/1.1 \(status) \(statusText)",
            "Content-Type: application/json",
            "Content-Length: \(bodyData.count)",
            "Access-Control-Allow-Origin: *",
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
