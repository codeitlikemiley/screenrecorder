import Foundation

/// Model Context Protocol server using stdio transport (JSON-RPC 2.0).
/// Reads requests from stdin, writes responses to stdout.
/// All tool calls are gated by license validation + rate limiting.
final class MCPServer {
    private let licenseManager = LicenseManager.shared
    private let rpcPort: Int

    /// JSON-RPC port of the running Screen Recorder app
    init(rpcPort: Int = 19820) {
        self.rpcPort = rpcPort
    }

    // MARK: - Server Lifecycle

    /// Start the MCP server (blocks, reads stdin line by line)
    func start() async {
        // Write to stderr so it doesn't interfere with JSON-RPC on stdout
        fputs("Screen Recorder MCP server started\n", stderr)

        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }

            guard let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                writeError(id: nil, code: -32700, message: "Parse error")
                continue
            }

            let id = request["id"]
            let method = request["method"] as? String ?? ""
            let params = request["params"] as? [String: Any] ?? [:]

            await handleRequest(id: id, method: method, params: params)
        }
    }

    // MARK: - Request Handler

    private func handleRequest(id: Any?, method: String, params: [String: Any]) async {
        switch method {
        // MCP lifecycle
        case "initialize":
            writeResult(id: id, result: serverCapabilities())

        case "notifications/initialized":
            return // No response needed for notifications

        case "tools/list":
            writeResult(id: id, result: ["tools": toolDefinitions()])

        case "tools/call":
            await handleToolCall(id: id, params: params)

        default:
            writeError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Tool Calls

    private func handleToolCall(id: Any?, params: [String: Any]) async {
        let toolName = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        // License check
        guard licenseManager.isActivated else {
            writeToolError(id: id, message: "No license activated. Run: sr activate YOUR-KEY")
            return
        }

        // Rate limit check (also revalidates license if stale)
        guard await licenseManager.checkRateLimit() else {
            let usage = licenseManager.currentUsage
            writeToolError(
                id: id,
                message: "Rate limit exceeded (\(usage.used)/\(usage.limit) calls today). Upgrade at https://screenrecorder.dev"
            )
            return
        }

        // Record the call
        licenseManager.recordCall()

        // Dispatch tool
        let result: Any
        do {
            switch toolName {
            case "screen_recorder_status":
                result = try await callRPC(method: "status")

            case "screen_recorder_screen_info":
                let showAll = arguments["all_displays"] as? Bool ?? false
                var rpcParams: [String: Any] = [:]
                if showAll { rpcParams["all"] = true }
                result = try await callRPC(method: "screen.info", params: rpcParams.isEmpty ? nil : rpcParams)

            case "screen_recorder_list_windows":
                let appFilter = arguments["app"] as? String
                var rpcParams: [String: Any] = [:]
                if let app = appFilter { rpcParams["app"] = app }
                result = try await callRPC(method: "windows.list", params: rpcParams.isEmpty ? nil : rpcParams)

            case "screen_recorder_focused_window":
                result = try await callRPC(method: "windows.focused")

            case "screen_recorder_detect_elements":
                var rpcParams: [String: Any] = [:]
                if let window = arguments["window"] as? String { rpcParams["window"] = window }
                if let windowId = arguments["window_id"] as? Int { rpcParams["window_id"] = windowId }
                if let region = arguments["region"] { rpcParams["region"] = region }
                if let minConf = arguments["min_confidence"] as? Double { rpcParams["min_confidence"] = minConf }
                result = try await callRPC(method: "elements.detect", params: rpcParams.isEmpty ? nil : rpcParams)

            case "screen_recorder_start":
                result = try await callRPC(method: "record.start")

            case "screen_recorder_stop":
                result = try await callRPC(method: "record.stop")

            case "screen_recorder_screenshot":
                var rpcParams: [String: Any] = [:]
                if let path = arguments["output_path"] as? String { rpcParams["output"] = path }
                if let region = arguments["region"] { rpcParams["region"] = region }
                if let window = arguments["window"] as? String { rpcParams["window"] = window }
                if let windowId = arguments["window_id"] as? Int { rpcParams["window_id"] = windowId }
                if let clean = arguments["clean"] as? Bool { rpcParams["clean"] = clean }
                result = try await callRPC(method: "screenshot.capture", params: rpcParams.isEmpty ? nil : rpcParams)

            case "screen_recorder_annotate":
                let action = arguments["action"] as? String ?? "add"
                result = try await callRPC(method: "annotate.\(action)", params: arguments)

            case "screen_recorder_annotate_clear":
                result = try await callRPC(method: "annotate.clear")

            case "screen_recorder_tool":
                let tool = arguments["tool"] as? String ?? "pen"
                result = try await callRPC(method: "tool.select", params: ["tool": tool])

            case "screen_recorder_usage":
                let usage = licenseManager.currentUsage
                result = [
                    "plan": usage.plan,
                    "calls_today": usage.used,
                    "limit": usage.limit == -1 ? "unlimited" : "\(usage.limit)",
                ] as [String: Any]

            default:
                writeToolError(id: id, message: "Unknown tool: \(toolName)")
                return
            }
        } catch {
            writeToolError(id: id, message: "Tool call failed: \(error.localizedDescription)")
            return
        }

        writeResult(id: id, result: [
            "content": [
                ["type": "text", "text": stringify(result)]
            ]
        ])
    }

    // MARK: - RPC Client

    /// Call the local Screen Recorder app via JSON-RPC
    private func callRPC(method: String, params: [String: Any]? = nil) async throws -> Any {
        let url = URL(string: "http://localhost:\(rpcPort)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "id": Int.random(in: 1...999999),
        ]
        if let params { body["params"] = params }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        if let error = response["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown error"
            throw NSError(domain: "RPC", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
        }

        return response["result"] ?? [String: Any]()
    }

    // MARK: - MCP Protocol

    private func serverCapabilities() -> [String: Any] {
        [
            "protocolVersion": "2024-11-05",
            "capabilities": [
                "tools": [String: Any]()
            ],
            "serverInfo": [
                "name": "screen-recorder",
                "version": "1.0.0",
            ],
        ]
    }

    private func toolDefinitions() -> [[String: Any]] {
        [
            toolDef(
                name: "screen_recorder_status",
                description: "Get the current status of Screen Recorder (recording state, camera, mic, annotation mode)",
                properties: [:]
            ),
            toolDef(
                name: "screen_recorder_screen_info",
                description: "Get display information (resolution, scale factor, visible frame). Essential for calculating annotation coordinates.",
                properties: [
                    "all_displays": [
                        "type": "boolean",
                        "description": "If true, return all connected displays. Default: main display only.",
                    ]
                ]
            ),
            toolDef(
                name: "screen_recorder_list_windows",
                description: "List all visible on-screen windows with their app name, title, bounds (x, y, width, height), and window ID. Use to find window positions for targeted screenshots or placing annotations.",
                properties: [
                    "app": [
                        "type": "string",
                        "description": "Filter windows by app name (case-insensitive substring match)",
                    ]
                ]
            ),
            toolDef(
                name: "screen_recorder_focused_window",
                description: "Get the currently focused/frontmost window with its app name, title, and bounds.",
                properties: [:]
            ),
            toolDef(
                name: "screen_recorder_detect_elements",
                description: "Detect text/UI elements via Vision OCR. Screenshots a window or region and returns each detected element's text, bounding box (x, y, width, height in screen points), center point, and confidence score. Use returned coordinates to precisely place annotations. Ideal for iOS Simulator, desktop apps, or any non-browser UI.",
                properties: [
                    "window": [
                        "type": "string",
                        "description": "Target window by app name (case-insensitive substring match)",
                    ],
                    "window_id": [
                        "type": "integer",
                        "description": "Target window by CGWindowID (from list_windows)",
                    ],
                    "region": [
                        "type": "object",
                        "description": "Target a specific screen region. Properties: x, y, width, height",
                    ],
                    "min_confidence": [
                        "type": "number",
                        "description": "Minimum OCR confidence 0.0-1.0 (default: 0.5). Higher = fewer but more accurate results.",
                    ],
                ]
            ),
            toolDef(
                name: "screen_recorder_start",
                description: "Start screen recording",
                properties: [:]
            ),
            toolDef(
                name: "screen_recorder_stop",
                description: "Stop screen recording",
                properties: [:]
            ),
            toolDef(
                name: "screen_recorder_screenshot",
                description: "Capture a screenshot. Supports full screen, specific region, or specific window capture. Can optionally exclude annotation overlays.",
                properties: [
                    "output_path": [
                        "type": "string",
                        "description": "File path to save the screenshot to. Default: auto-generated temp file.",
                    ],
                    "region": [
                        "type": "object",
                        "description": "Capture a specific screen region. Properties: x, y, width, height (in screen points).",
                    ],
                    "window": [
                        "type": "string",
                        "description": "Capture a specific window by app name (case-insensitive substring match).",
                    ],
                    "window_id": [
                        "type": "integer",
                        "description": "Capture a specific window by its CGWindowID (from list_windows).",
                    ],
                    "clean": [
                        "type": "boolean",
                        "description": "If true, temporarily hides annotations during capture. Default: false (includes annotations).",
                    ],
                ]
            ),
            toolDef(
                name: "screen_recorder_annotate",
                description: "Add an annotation to the screen. Supports arrows, rectangles, ellipses, text, and freehand drawing.",
                properties: [
                    "action": [
                        "type": "string",
                        "description": "The annotation action: add, undo, redo",
                        "enum": ["add", "undo", "redo"],
                    ],
                    "type": [
                        "type": "string",
                        "description": "Annotation type for 'add': arrow, rectangle, ellipse, line, text, pen",
                    ],
                    "points": [
                        "type": "string",
                        "description": "Comma-separated coordinates (x1,y1,x2,y2) for shapes, or x,y for text",
                    ],
                    "color": [
                        "type": "string",
                        "description": "Color name: red, green, blue, yellow, white, black",
                    ],
                    "text": [
                        "type": "string",
                        "description": "Text content (for text annotations)",
                    ],
                ],
                required: ["action"]
            ),
            toolDef(
                name: "screen_recorder_annotate_clear",
                description: "Clear all annotations from the screen",
                properties: [:]
            ),
            toolDef(
                name: "screen_recorder_tool",
                description: "Select the active drawing tool",
                properties: [
                    "tool": [
                        "type": "string",
                        "description": "The tool to select",
                        "enum": ["pen", "line", "arrow", "rectangle", "ellipse", "text", "move"],
                    ]
                ],
                required: ["tool"]
            ),
            toolDef(
                name: "screen_recorder_usage",
                description: "Get current license usage information (plan, calls today, limit)",
                properties: [:]
            ),
        ]
    }

    // MARK: - Helpers

    private func toolDef(
        name: String,
        description: String,
        properties: [String: [String: Any]],
        required: [String] = []
    ) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties,
        ]
        if !required.isEmpty {
            schema["required"] = required
        }
        return [
            "name": name,
            "description": description,
            "inputSchema": schema,
        ]
    }

    private func writeResult(id: Any?, result: Any) {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "result": result,
        ]
        writeLine(response)
    }

    private func writeError(id: Any?, code: Int, message: String) {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": ["code": code, "message": message],
        ]
        writeLine(response)
    }

    private func writeToolError(id: Any?, message: String) {
        writeResult(id: id, result: [
            "content": [
                ["type": "text", "text": message]
            ],
            "isError": true,
        ])
    }

    private func writeLine(_ obj: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let line = String(data: data, encoding: .utf8)
        else { return }
        print(line)
        fflush(stdout)
    }

    private func stringify(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8)
        {
            return str
        }
        return "\(value)"
    }
}
