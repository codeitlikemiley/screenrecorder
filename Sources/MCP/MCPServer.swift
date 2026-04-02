import AppKit
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
            writeToolError(id: id, message: "No license activated. Run: sr-mcp activate YOUR-KEY")
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
                var rpcParams: [String: Any] = [:]
                if let camera = arguments["camera"] as? Bool { rpcParams["camera"] = camera }
                if let mic = arguments["mic"] as? Bool { rpcParams["mic"] = mic }
                if let keystrokes = arguments["keystrokes"] as? Bool { rpcParams["keystrokes"] = keystrokes }
                if let fps = arguments["fps"] as? Int { rpcParams["fps"] = fps }
                if let mode = arguments["mode"] as? String { rpcParams["mode"] = mode }
                result = try await callRPC(method: "record.start", params: rpcParams.isEmpty ? nil : rpcParams)

            case "screen_recorder_stop":
                result = try await callRPC(method: "record.stop")

            case "screen_recorder_pause":
                result = try await callRPC(method: "record.pause")

            case "screen_recorder_resume":
                result = try await callRPC(method: "record.resume")

            case "screen_recorder_screenshot":
                var rpcParams: [String: Any] = [:]
                if let path = arguments["output_path"] as? String { rpcParams["output"] = path }
                if let region = arguments["region"] { rpcParams["region"] = region }
                if let window = arguments["window"] as? String { rpcParams["window"] = window }
                if let windowId = arguments["window_id"] as? Int { rpcParams["window_id"] = windowId }
                if let clean = arguments["clean"] as? Bool { rpcParams["clean"] = clean }
                result = try await callRPC(method: "screenshot.capture", params: rpcParams.isEmpty ? nil : rpcParams)

            case "screen_recorder_annotate":
                var rpcParams = arguments
                // Remove the "action" key — it's used only for routing
                let action = rpcParams.removeValue(forKey: "action") as? String ?? "add"
                // Pass window_ref through if present
                result = try await callRPC(method: "annotate.\(action)", params: rpcParams.isEmpty ? nil : rpcParams)

            case "screen_recorder_annotate_activate":
                result = try await callRPC(method: "annotate.activate")

            case "screen_recorder_annotate_deactivate":
                result = try await callRPC(method: "annotate.deactivate")

            case "screen_recorder_annotate_list":
                result = try await callRPC(method: "annotate.list")

            case "screen_recorder_annotate_undo":
                result = try await callRPC(method: "annotate.undo")

            case "screen_recorder_annotate_redo":
                result = try await callRPC(method: "annotate.redo")

            case "screen_recorder_annotate_clear":
                result = try await callRPC(method: "annotate.clear")

            case "screen_recorder_tool":
                let tool = arguments["tool"] as? String ?? "pen"
                result = try await callRPC(method: "tool.select", params: ["tool": tool])

            case "screen_recorder_tool_color":
                guard let color = arguments["color"] as? String else {
                    writeToolError(id: id, message: "Missing 'color' parameter")
                    return
                }
                result = try await callRPC(method: "tool.color", params: ["color": color])

            case "screen_recorder_tool_width":
                guard let width = arguments["width"] else {
                    writeToolError(id: id, message: "Missing 'width' parameter")
                    return
                }
                result = try await callRPC(method: "tool.lineWidth", params: ["width": width])

            case "screen_recorder_session_new":
                var params: [String: Any] = [:]
                if let name = arguments["name"] as? String { params["name"] = name }
                if let fc = arguments["from_current"] as? Bool { params["from_current"] = fc }
                result = try await callRPC(method: "session.new", params: params.isEmpty ? nil : params)

            case "screen_recorder_session_list":
                result = try await callRPC(method: "session.list")

            case "screen_recorder_session_switch":
                var params: [String: Any] = [:]
                if let name = arguments["name"] as? String { params["name"] = name }
                if let id = arguments["id"] as? String { params["id"] = id }
                result = try await callRPC(method: "session.switch", params: params)

            case "screen_recorder_session_delete":
                var params: [String: Any] = [:]
                if let name = arguments["name"] as? String { params["name"] = name }
                if let id = arguments["id"] as? String { params["id"] = id }
                result = try await callRPC(method: "session.delete", params: params)

            case "screen_recorder_session_save":
                result = try await callRPC(method: "session.save")

            case "screen_recorder_session_export":
                var params: [String: Any] = [:]
                if let name = arguments["name"] as? String { params["name"] = name }
                if let output = arguments["output"] as? String { params["output"] = output }
                result = try await callRPC(method: "session.export", params: params.isEmpty ? nil : params)

            case "screen_recorder_usage":
                let usage = licenseManager.currentUsage
                result = [
                    "plan": usage.plan,
                    "calls_today": usage.used,
                    "limit": usage.limit == -1 ? "unlimited" : "\(usage.limit)",
                ] as [String: Any]

            // --- Computer Control ---

            case "screen_recorder_click":
                var rpcParams: [String: Any] = [:]
                if let x = arguments["x"] { rpcParams["x"] = x }
                if let y = arguments["y"] { rpcParams["y"] = y }
                if let cc = arguments["click_count"] { rpcParams["click_count"] = cc }
                if let wr = arguments["window_ref"] { rpcParams["window_ref"] = wr }
                if let wri = arguments["window_ref_id"] { rpcParams["window_ref_id"] = wri }
                if let app = arguments["app"] { rpcParams["app"] = app }
                if let pid = arguments["pid"] { rpcParams["pid"] = pid }
                result = try await callRPC(method: "input.click", params: rpcParams)

            case "screen_recorder_right_click":
                var rpcParams: [String: Any] = [:]
                if let x = arguments["x"] { rpcParams["x"] = x }
                if let y = arguments["y"] { rpcParams["y"] = y }
                if let wr = arguments["window_ref"] { rpcParams["window_ref"] = wr }
                if let wri = arguments["window_ref_id"] { rpcParams["window_ref_id"] = wri }
                if let app = arguments["app"] { rpcParams["app"] = app }
                if let pid = arguments["pid"] { rpcParams["pid"] = pid }
                result = try await callRPC(method: "input.right_click", params: rpcParams)

            case "screen_recorder_double_click":
                var rpcParams: [String: Any] = [:]
                if let x = arguments["x"] { rpcParams["x"] = x }
                if let y = arguments["y"] { rpcParams["y"] = y }
                if let wr = arguments["window_ref"] { rpcParams["window_ref"] = wr }
                if let wri = arguments["window_ref_id"] { rpcParams["window_ref_id"] = wri }
                if let app = arguments["app"] { rpcParams["app"] = app }
                if let pid = arguments["pid"] { rpcParams["pid"] = pid }
                result = try await callRPC(method: "input.double_click", params: rpcParams)

            case "screen_recorder_drag":
                var rpcParams: [String: Any] = [:]
                if let fx = arguments["from_x"] { rpcParams["from_x"] = fx }
                if let fy = arguments["from_y"] { rpcParams["from_y"] = fy }
                if let tx = arguments["to_x"] { rpcParams["to_x"] = tx }
                if let ty = arguments["to_y"] { rpcParams["to_y"] = ty }
                if let d = arguments["duration"] { rpcParams["duration"] = d }
                if let wr = arguments["window_ref"] { rpcParams["window_ref"] = wr }
                if let wri = arguments["window_ref_id"] { rpcParams["window_ref_id"] = wri }
                if let app = arguments["app"] { rpcParams["app"] = app }
                if let pid = arguments["pid"] { rpcParams["pid"] = pid }
                result = try await callRPC(method: "input.drag", params: rpcParams)

            case "screen_recorder_scroll":
                var rpcParams: [String: Any] = [:]
                if let x = arguments["x"] { rpcParams["x"] = x }
                if let y = arguments["y"] { rpcParams["y"] = y }
                if let dx = arguments["delta_x"] { rpcParams["delta_x"] = dx }
                if let dy = arguments["delta_y"] { rpcParams["delta_y"] = dy }
                if let wr = arguments["window_ref"] { rpcParams["window_ref"] = wr }
                if let wri = arguments["window_ref_id"] { rpcParams["window_ref_id"] = wri }
                if let app = arguments["app"] { rpcParams["app"] = app }
                if let pid = arguments["pid"] { rpcParams["pid"] = pid }
                result = try await callRPC(method: "input.scroll", params: rpcParams)

            case "screen_recorder_move_mouse":
                var rpcParams: [String: Any] = [:]
                if let x = arguments["x"] { rpcParams["x"] = x }
                if let y = arguments["y"] { rpcParams["y"] = y }
                if let wr = arguments["window_ref"] { rpcParams["window_ref"] = wr }
                if let wri = arguments["window_ref_id"] { rpcParams["window_ref_id"] = wri }
                result = try await callRPC(method: "input.move_mouse", params: rpcParams)

            case "screen_recorder_type_text":
                var rpcParams: [String: Any] = [:]
                if let text = arguments["text"] { rpcParams["text"] = text }
                if let interval = arguments["interval_ms"] { rpcParams["interval_ms"] = interval }
                if let app = arguments["app"] { rpcParams["app"] = app }
                if let pid = arguments["pid"] { rpcParams["pid"] = pid }
                result = try await callRPC(method: "input.type_text", params: rpcParams)

            case "screen_recorder_press_key":
                var rpcParams: [String: Any] = [:]
                if let key = arguments["key"] { rpcParams["key"] = key }
                if let mods = arguments["modifiers"] { rpcParams["modifiers"] = mods }
                if let app = arguments["app"] { rpcParams["app"] = app }
                if let pid = arguments["pid"] { rpcParams["pid"] = pid }
                result = try await callRPC(method: "input.press_key", params: rpcParams)

            case "screen_recorder_hotkey":
                var rpcParams: [String: Any] = [:]
                if let keys = arguments["keys"] { rpcParams["keys"] = keys }
                if let app = arguments["app"] { rpcParams["app"] = app }
                if let pid = arguments["pid"] { rpcParams["pid"] = pid }
                result = try await callRPC(method: "input.hotkey", params: rpcParams)

            case "screen_recorder_click_element":
                var rpcParams: [String: Any] = [:]
                if let text = arguments["text"] { rpcParams["text"] = text }
                if let window = arguments["window"] { rpcParams["window"] = window }
                if let windowId = arguments["window_id"] { rpcParams["window_id"] = windowId }
                if let cc = arguments["click_count"] { rpcParams["click_count"] = cc }
                if let pid = arguments["pid"] { rpcParams["pid"] = pid }
                result = try await callRPC(method: "input.click_element", params: rpcParams)

            case "screen_recorder_launch_app":
                var rpcParams: [String: Any] = [:]
                if let name = arguments["name"] { rpcParams["name"] = name }
                if let activate = arguments["activate"] { rpcParams["activate"] = activate }
                result = try await callRPC(method: "app.launch", params: rpcParams)

            case "screen_recorder_activate_app":
                var rpcParams: [String: Any] = [:]
                if let name = arguments["name"] { rpcParams["name"] = name }
                result = try await callRPC(method: "app.activate", params: rpcParams)

            case "screen_recorder_list_apps":
                result = try await callRPC(method: "app.list")

            // --- Browser Automation ---

            case "screen_recorder_browser_status":
                var rpcParams: [String: Any] = [:]
                if let backend = arguments["backend"] { rpcParams["backend"] = backend }
                if let port = arguments["port"] { rpcParams["port"] = port }
                result = try await callRPC(method: "browser.status", params: rpcParams)

            case "screen_recorder_browser_launch":
                var rpcParams: [String: Any] = [:]
                if let backend = arguments["backend"] { rpcParams["backend"] = backend }
                if let port = arguments["port"] { rpcParams["port"] = port }
                if let app = arguments["app"] { rpcParams["app"] = app }
                if let url = arguments["url"] { rpcParams["url"] = url }
                if let activate = arguments["activate"] { rpcParams["activate"] = activate }
                if let isolated = arguments["isolated"] { rpcParams["isolated"] = isolated }
                result = try await callRPC(method: "browser.launch", params: rpcParams)

            case "screen_recorder_browser_launch_and_open":
                var rpcParams: [String: Any] = [:]
                if let backend = arguments["backend"] { rpcParams["backend"] = backend }
                if let port = arguments["port"] { rpcParams["port"] = port }
                if let app = arguments["app"] { rpcParams["app"] = app }
                if let url = arguments["url"] { rpcParams["url"] = url }
                if let activate = arguments["activate"] { rpcParams["activate"] = activate }
                if let isolated = arguments["isolated"] { rpcParams["isolated"] = isolated }
                if let newTab = arguments["new_tab"] { rpcParams["new_tab"] = newTab }
                result = try await callRPC(method: "browser.launch_and_open", params: rpcParams)

            case "screen_recorder_browser_tabs":
                var rpcParams: [String: Any] = [:]
                if let backend = arguments["backend"] { rpcParams["backend"] = backend }
                if let port = arguments["port"] { rpcParams["port"] = port }
                result = try await callRPC(method: "browser.tabs", params: rpcParams)

            case "screen_recorder_browser_open_tab":
                var rpcParams: [String: Any] = [:]
                if let backend = arguments["backend"] { rpcParams["backend"] = backend }
                if let port = arguments["port"] { rpcParams["port"] = port }
                if let url = arguments["url"] { rpcParams["url"] = url }
                result = try await callRPC(method: "browser.open_tab", params: rpcParams)

            case "screen_recorder_browser_activate_tab":
                var rpcParams: [String: Any] = [:]
                if let backend = arguments["backend"] { rpcParams["backend"] = backend }
                if let port = arguments["port"] { rpcParams["port"] = port }
                if let tabID = arguments["tab_id"] { rpcParams["tab_id"] = tabID }
                if let titleContains = arguments["title_contains"] { rpcParams["title_contains"] = titleContains }
                if let urlContains = arguments["url_contains"] { rpcParams["url_contains"] = urlContains }
                result = try await callRPC(method: "browser.activate_tab", params: rpcParams)

            case "screen_recorder_browser_navigate":
                var rpcParams: [String: Any] = [:]
                if let backend = arguments["backend"] { rpcParams["backend"] = backend }
                if let port = arguments["port"] { rpcParams["port"] = port }
                if let url = arguments["url"] { rpcParams["url"] = url }
                if let tabID = arguments["tab_id"] { rpcParams["tab_id"] = tabID }
                if let titleContains = arguments["title_contains"] { rpcParams["title_contains"] = titleContains }
                if let urlContains = arguments["url_contains"] { rpcParams["url_contains"] = urlContains }
                result = try await callRPC(method: "browser.navigate", params: rpcParams)

            case "screen_recorder_browser_eval":
                var rpcParams: [String: Any] = [:]
                if let backend = arguments["backend"] { rpcParams["backend"] = backend }
                if let port = arguments["port"] { rpcParams["port"] = port }
                if let expression = arguments["expression"] { rpcParams["expression"] = expression }
                if let tabID = arguments["tab_id"] { rpcParams["tab_id"] = tabID }
                if let titleContains = arguments["title_contains"] { rpcParams["title_contains"] = titleContains }
                if let urlContains = arguments["url_contains"] { rpcParams["url_contains"] = urlContains }
                result = try await callRPC(method: "browser.eval", params: rpcParams)

            case "screen_recorder_browser_click":
                var rpcParams: [String: Any] = [:]
                if let backend = arguments["backend"] { rpcParams["backend"] = backend }
                if let port = arguments["port"] { rpcParams["port"] = port }
                if let selector = arguments["selector"] { rpcParams["selector"] = selector }
                if let tabID = arguments["tab_id"] { rpcParams["tab_id"] = tabID }
                if let titleContains = arguments["title_contains"] { rpcParams["title_contains"] = titleContains }
                if let urlContains = arguments["url_contains"] { rpcParams["url_contains"] = urlContains }
                result = try await callRPC(method: "browser.click", params: rpcParams)

            case "screen_recorder_browser_type":
                var rpcParams: [String: Any] = [:]
                if let backend = arguments["backend"] { rpcParams["backend"] = backend }
                if let port = arguments["port"] { rpcParams["port"] = port }
                if let selector = arguments["selector"] { rpcParams["selector"] = selector }
                if let text = arguments["text"] { rpcParams["text"] = text }
                if let tabID = arguments["tab_id"] { rpcParams["tab_id"] = tabID }
                if let titleContains = arguments["title_contains"] { rpcParams["title_contains"] = titleContains }
                if let urlContains = arguments["url_contains"] { rpcParams["url_contains"] = urlContains }
                result = try await callRPC(method: "browser.type", params: rpcParams)

            case "screen_recorder_browser_press_key":
                var rpcParams: [String: Any] = [:]
                if let backend = arguments["backend"] { rpcParams["backend"] = backend }
                if let port = arguments["port"] { rpcParams["port"] = port }
                if let key = arguments["key"] { rpcParams["key"] = key }
                if let tabID = arguments["tab_id"] { rpcParams["tab_id"] = tabID }
                if let titleContains = arguments["title_contains"] { rpcParams["title_contains"] = titleContains }
                if let urlContains = arguments["url_contains"] { rpcParams["url_contains"] = urlContains }
                result = try await callRPC(method: "browser.press_key", params: rpcParams)

            case "screen_recorder_browser_screenshot":
                var rpcParams: [String: Any] = [:]
                if let backend = arguments["backend"] { rpcParams["backend"] = backend }
                if let port = arguments["port"] { rpcParams["port"] = port }
                if let output = arguments["output_path"] { rpcParams["output"] = output }
                if let base64 = arguments["base64"] { rpcParams["base64"] = base64 }
                if let tabID = arguments["tab_id"] { rpcParams["tab_id"] = tabID }
                if let titleContains = arguments["title_contains"] { rpcParams["title_contains"] = titleContains }
                if let urlContains = arguments["url_contains"] { rpcParams["url_contains"] = urlContains }
                result = try await callRPC(method: "browser.screenshot", params: rpcParams)

            case "screen_recorder_run_command":
                var rpcParams: [String: Any] = [:]
                if let cmd = arguments["command"] { rpcParams["command"] = cmd }
                if let t = arguments["timeout"] { rpcParams["timeout"] = t }
                result = try await callRPC(method: "shell.exec", params: rpcParams)

            case "screen_recorder_check_accessibility":
                result = try await callRPC(method: "accessibility.check")

            // --- Accessibility Tree ---

            case "screen_recorder_ax_tree":
                var rpcParams: [String: Any] = [:]
                if let app = arguments["app"] { rpcParams["app"] = app }
                if let bid = arguments["bundle_id"] { rpcParams["bundle_id"] = bid }
                if let pid = arguments["pid"] { rpcParams["pid"] = pid }
                if let md = arguments["max_depth"] { rpcParams["max_depth"] = md }
                result = try await callRPC(method: "ax.tree", params: rpcParams)

            case "screen_recorder_ax_find":
                var rpcParams: [String: Any] = [:]
                if let app = arguments["app"] { rpcParams["app"] = app }
                if let bid = arguments["bundle_id"] { rpcParams["bundle_id"] = bid }
                if let pid = arguments["pid"] { rpcParams["pid"] = pid }
                if let title = arguments["title"] { rpcParams["title"] = title }
                if let role = arguments["role"] { rpcParams["role"] = role }
                if let mr = arguments["max_results"] { rpcParams["max_results"] = mr }
                result = try await callRPC(method: "ax.find", params: rpcParams)

            case "screen_recorder_ax_press":
                var rpcParams: [String: Any] = [:]
                if let app = arguments["app"] { rpcParams["app"] = app }
                if let bid = arguments["bundle_id"] { rpcParams["bundle_id"] = bid }
                if let pid = arguments["pid"] { rpcParams["pid"] = pid }
                if let title = arguments["title"] { rpcParams["title"] = title }
                if let action = arguments["action"] { rpcParams["action"] = action }
                result = try await callRPC(method: "ax.press", params: rpcParams)

            case "screen_recorder_ax_set_value":
                var rpcParams: [String: Any] = [:]
                if let app = arguments["app"] { rpcParams["app"] = app }
                if let bid = arguments["bundle_id"] { rpcParams["bundle_id"] = bid }
                if let pid = arguments["pid"] { rpcParams["pid"] = pid }
                if let title = arguments["title"] { rpcParams["title"] = title }
                if let value = arguments["value"] { rpcParams["value"] = value }
                result = try await callRPC(method: "ax.set_value", params: rpcParams)

            case "screen_recorder_ax_focused":
                result = try await callRPC(method: "ax.focused")

            case "screen_recorder_ax_actionable":
                var rpcParams: [String: Any] = [:]
                if let app = arguments["app"] { rpcParams["app"] = app }
                if let bid = arguments["bundle_id"] { rpcParams["bundle_id"] = bid }
                if let pid = arguments["pid"] { rpcParams["pid"] = pid }
                if let md = arguments["max_depth"] { rpcParams["max_depth"] = md }
                if let mr = arguments["max_results"] { rpcParams["max_results"] = mr }
                result = try await callRPC(method: "ax.actionable", params: rpcParams)

            // --- Safety ---

            case "screen_recorder_safety_settings":
                result = try await callRPC(method: "safety.settings")

            case "screen_recorder_safety_configure":
                result = try await callRPC(method: "safety.configure", params: arguments)

            case "screen_recorder_safety_log":
                var rpcParams: [String: Any] = [:]
                if let count = arguments["count"] { rpcParams["count"] = count }
                result = try await callRPC(method: "safety.log", params: rpcParams)

            // --- Agent Control Lock ---

            case "screen_recorder_lock_controls":
                var rpcParams: [String: Any] = [:]
                if let key = arguments["unlock_key"] { rpcParams["unlock_key"] = key }
                result = try await callRPC(method: "input.lock_for_agent", params: rpcParams.isEmpty ? nil : rpcParams)

            case "screen_recorder_unlock_controls":
                result = try await callRPC(method: "input.unlock")

            case "screen_recorder_control_status":
                result = try await callRPC(method: "input.lock_status")

            // --- App Lifecycle ---

            case "screen_recorder_quit_app":
                var rpcParams: [String: Any] = [:]
                if let name = arguments["name"] { rpcParams["name"] = name }
                if let force = arguments["force"] { rpcParams["force"] = force }
                result = try await callRPC(method: "app.quit", params: rpcParams)

            case "screen_recorder_relaunch_app":
                var rpcParams: [String: Any] = [:]
                if let name = arguments["name"] { rpcParams["name"] = name }
                result = try await callRPC(method: "app.relaunch", params: rpcParams)

            case "screen_recorder_hide_app":
                var rpcParams: [String: Any] = [:]
                if let name = arguments["name"] { rpcParams["name"] = name }
                result = try await callRPC(method: "app.hide", params: rpcParams)

            // --- Window Manipulation ---

            case "screen_recorder_window_move":
                var rpcParams: [String: Any] = [:]
                if let x = arguments["x"] { rpcParams["x"] = x }
                if let y = arguments["y"] { rpcParams["y"] = y }
                if let app = arguments["app"] { rpcParams["app"] = app }
                result = try await callRPC(method: "window.move", params: rpcParams)

            case "screen_recorder_window_resize":
                var rpcParams: [String: Any] = [:]
                if let w = arguments["width"] { rpcParams["width"] = w }
                if let h = arguments["height"] { rpcParams["height"] = h }
                if let app = arguments["app"] { rpcParams["app"] = app }
                result = try await callRPC(method: "window.resize", params: rpcParams)

            case "screen_recorder_window_minimize":
                var rpcParams: [String: Any] = [:]
                if let app = arguments["app"] { rpcParams["app"] = app }
                result = try await callRPC(method: "window.minimize", params: rpcParams)

            case "screen_recorder_window_restore":
                var rpcParams: [String: Any] = [:]
                if let app = arguments["app"] { rpcParams["app"] = app }
                result = try await callRPC(method: "window.restore", params: rpcParams)

            // --- Sleep / Delay ---

            case "screen_recorder_sleep":
                var rpcParams: [String: Any] = [:]
                if let ms = arguments["ms"] { rpcParams["ms"] = ms }
                result = try await callRPC(method: "sleep", params: rpcParams)

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

    /// Call the local Screen Recorder app via JSON-RPC.
    /// If the connection fails, automatically tries to launch the app and retries once.
    private func callRPC(method: String, params: [String: Any]? = nil) async throws -> Any {
        do {
            return try await performRPC(method: method, params: params)
        } catch {
            // Connection refused — app is probably not running. Try to launch it then retry.
            let errDesc = error.localizedDescription.lowercased()
            guard errDesc.contains("connection refused") || errDesc.contains("could not connect") || errDesc.contains("network connection was lost") else {
                throw error
            }
            fputs("[sr-mcp] App not running on port \(rpcPort) — attempting auto-launch...\n", stderr)
            await autoLaunchApp()
            // Wait up to 5s for the app to start accepting connections
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                if let result = try? await performRPC(method: method, params: params) {
                    return result
                }
            }
            // Final attempt — throw if still failing
            return try await performRPC(method: method, params: params)
        }
    }

    /// Low-level RPC call — no retry logic.
    private func performRPC(method: String, params: [String: Any]? = nil) async throws -> Any {
        let url = URL(string: "http://localhost:\(rpcPort)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5

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
                description: "Start screen recording. Configure camera, microphone, keystroke overlay, frame rate, and recording mode.",
                properties: [
                    "camera": [
                        "type": "boolean",
                        "description": "Enable (true) or disable (false) camera overlay",
                    ],
                    "mic": [
                        "type": "boolean",
                        "description": "Enable (true) or disable (false) microphone",
                    ],
                    "keystrokes": [
                        "type": "boolean",
                        "description": "Enable (true) or disable (false) keystroke overlay",
                    ],
                    "fps": [
                        "type": "integer",
                        "description": "Frame rate: 15, 30, or 60",
                    ],
                    "mode": [
                        "type": "string",
                        "description": "Recording mode: 'normal' or 'ai' (AI mode captures interaction metadata)",
                        "enum": ["normal", "ai"],
                    ],
                ]
            ),
            toolDef(
                name: "screen_recorder_stop",
                description: "Stop screen recording and save the video file",
                properties: [:]
            ),
            toolDef(
                name: "screen_recorder_pause",
                description: "Pause the current recording",
                properties: [:]
            ),
            toolDef(
                name: "screen_recorder_resume",
                description: "Resume a paused recording",
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
                description: "Add annotations to the screen. Supports arrows, rectangles, ellipses, lines, text, and freehand drawing. Coordinates are in screen points. Use window_ref to offset coordinates relative to a window.",
                properties: [
                    "action": [
                        "type": "string",
                        "description": "The annotation action: add, undo, redo",
                        "enum": ["add", "undo", "redo"],
                    ],
                    "annotations": [
                        "type": "array",
                        "description": "Array of annotation objects. Each must have a 'type' (arrow/rectangle/ellipse/line/pen/text). Arrows/lines need 'from' and 'to' {x,y}. Shapes need 'origin' {x,y} and 'size' {width,height}. Text needs 'at' {x,y} and 'text'. All support optional 'color' and 'lineWidth'.",
                    ],
                    "window_ref": [
                        "type": "string",
                        "description": "App name to use as coordinate reference. All annotation coordinates become relative to this window's origin. Use with detect_elements for precise placement.",
                    ],
                    "window_ref_id": [
                        "type": "integer",
                        "description": "Window ID to use as coordinate reference (alternative to window_ref).",
                    ],
                ],
                required: ["action"]
            ),
            toolDef(
                name: "screen_recorder_annotate_activate",
                description: "Activate annotation mode (start accepting drawing input)",
                properties: [:]
            ),
            toolDef(
                name: "screen_recorder_annotate_deactivate",
                description: "Deactivate annotation mode (stop accepting drawing input, keep existing annotations visible)",
                properties: [:]
            ),
            toolDef(
                name: "screen_recorder_annotate_list",
                description: "List all current annotations with full geometry: bounding box, coordinates, length/angle (arrows/lines), area/center (shapes), color, and text content.",
                properties: [:]
            ),
            toolDef(
                name: "screen_recorder_annotate_undo",
                description: "Undo the last annotation",
                properties: [:]
            ),
            toolDef(
                name: "screen_recorder_annotate_redo",
                description: "Redo the last undone annotation",
                properties: [:]
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
                name: "screen_recorder_tool_color",
                description: "Set the drawing color for annotations",
                properties: [
                    "color": [
                        "type": "string",
                        "description": "Color name (red, green, blue, yellow, orange, purple, white, black, cyan, magenta, pink) or hex (#RRGGBB)",
                    ]
                ],
                required: ["color"]
            ),
            toolDef(
                name: "screen_recorder_tool_width",
                description: "Set the line width for drawing annotations (1-20)",
                properties: [
                    "width": [
                        "type": "number",
                        "description": "Line width in points (1-20)",
                    ]
                ],
                required: ["width"]
            ),
            toolDef(
                name: "screen_recorder_session_new",
                description: "Create a new annotation session. Optionally copy current annotations into it.",
                properties: [
                    "name": [
                        "type": "string",
                        "description": "Session name",
                    ],
                    "from_current": [
                        "type": "boolean",
                        "description": "If true, copy current canvas annotations into the new session. Default: false",
                    ],
                ]
            ),
            toolDef(
                name: "screen_recorder_session_list",
                description: "List all saved annotation sessions with name, stroke count, and active status.",
                properties: [:]
            ),
            toolDef(
                name: "screen_recorder_session_switch",
                description: "Switch to a named annotation session. Saves current session, loads target.",
                properties: [
                    "name": [
                        "type": "string",
                        "description": "Session name to switch to",
                    ],
                    "id": [
                        "type": "string",
                        "description": "Session UUID (alternative to name)",
                    ],
                ]
            ),
            toolDef(
                name: "screen_recorder_session_delete",
                description: "Delete a saved annotation session.",
                properties: [
                    "name": [
                        "type": "string",
                        "description": "Session name to delete",
                    ],
                ]
            ),
            toolDef(
                name: "screen_recorder_session_save",
                description: "Save current annotations to the active session.",
                properties: [:]
            ),
            toolDef(
                name: "screen_recorder_session_export",
                description: "Export a session as JSON. Returns JSON string or saves to file.",
                properties: [
                    "name": [
                        "type": "string",
                        "description": "Session name (default: active session)",
                    ],
                    "output": [
                        "type": "string",
                        "description": "File path to save JSON (default: return in response)",
                    ],
                ]
            ),
            toolDef(
                name: "screen_recorder_usage",
                description: "Get current license usage information (plan, calls today, limit)",
                properties: [:]
            ),

            // --- Computer Control Tools ---

            toolDef(
                name: "screen_recorder_click",
                description: "Click at screen coordinates. Supports window-relative coordinates and optional background delivery to a target app/PID without stealing focus.",
                properties: [
                    "x": ["type": "number", "description": "X coordinate (screen points)"],
                    "y": ["type": "number", "description": "Y coordinate (screen points)"],
                    "click_count": ["type": "integer", "description": "Number of clicks (1=single, 2=double, 3=triple). Default: 1"],
                    "window_ref": ["type": "string", "description": "App name — coordinates become relative to this window"],
                    "window_ref_id": ["type": "integer", "description": "Window ID — coordinates become relative to this window"],
                    "app": ["type": "string", "description": "Deliver to this app's PID without focusing it"],
                    "pid": ["type": "integer", "description": "Deliver directly to this PID without focusing it"],
                ],
                required: ["x", "y"]
            ),
            toolDef(
                name: "screen_recorder_right_click",
                description: "Right-click at screen coordinates (opens context menus).",
                properties: [
                    "x": ["type": "number", "description": "X coordinate"],
                    "y": ["type": "number", "description": "Y coordinate"],
                    "window_ref": ["type": "string", "description": "App name for relative coordinates"],
                    "window_ref_id": ["type": "integer", "description": "Window ID for relative coordinates"],
                    "app": ["type": "string", "description": "Deliver to this app's PID without focusing it"],
                    "pid": ["type": "integer", "description": "Deliver directly to this PID without focusing it"],
                ],
                required: ["x", "y"]
            ),
            toolDef(
                name: "screen_recorder_double_click",
                description: "Double-click at screen coordinates (selects words, opens files).",
                properties: [
                    "x": ["type": "number", "description": "X coordinate"],
                    "y": ["type": "number", "description": "Y coordinate"],
                    "window_ref": ["type": "string", "description": "App name for relative coordinates"],
                    "window_ref_id": ["type": "integer", "description": "Window ID for relative coordinates"],
                    "app": ["type": "string", "description": "Deliver to this app's PID without focusing it"],
                    "pid": ["type": "integer", "description": "Deliver directly to this PID without focusing it"],
                ],
                required: ["x", "y"]
            ),
            toolDef(
                name: "screen_recorder_drag",
                description: "Drag from one point to another (for moving windows, selecting text, resizing).",
                properties: [
                    "from_x": ["type": "number", "description": "Start X coordinate"],
                    "from_y": ["type": "number", "description": "Start Y coordinate"],
                    "to_x": ["type": "number", "description": "End X coordinate"],
                    "to_y": ["type": "number", "description": "End Y coordinate"],
                    "duration": ["type": "number", "description": "Drag duration in seconds (default: 0.5)"],
                    "window_ref": ["type": "string", "description": "App name for relative coordinates"],
                    "window_ref_id": ["type": "integer", "description": "Window ID for relative coordinates"],
                ],
                required: ["from_x", "from_y", "to_x", "to_y"]
            ),
            toolDef(
                name: "screen_recorder_scroll",
                description: "Scroll at a screen position. Positive delta_y = scroll up, negative = scroll down. Can deliver to a background app/PID without moving focus.",
                properties: [
                    "x": ["type": "number", "description": "X coordinate where scroll happens"],
                    "y": ["type": "number", "description": "Y coordinate where scroll happens"],
                    "delta_x": ["type": "number", "description": "Horizontal scroll amount (positive=right)"],
                    "delta_y": ["type": "number", "description": "Vertical scroll amount (positive=up, negative=down)"],
                    "window_ref": ["type": "string", "description": "App name for relative coordinates"],
                    "window_ref_id": ["type": "integer", "description": "Window ID for relative coordinates"],
                    "app": ["type": "string", "description": "Deliver to this app's PID without focusing it"],
                    "pid": ["type": "integer", "description": "Deliver directly to this PID without focusing it"],
                ],
                required: ["x", "y"]
            ),
            toolDef(
                name: "screen_recorder_move_mouse",
                description: "Move the cursor to screen coordinates without clicking.",
                properties: [
                    "x": ["type": "number", "description": "X coordinate"],
                    "y": ["type": "number", "description": "Y coordinate"],
                    "window_ref": ["type": "string", "description": "App name for relative coordinates"],
                    "window_ref_id": ["type": "integer", "description": "Window ID for relative coordinates"],
                ],
                required: ["x", "y"]
            ),
            toolDef(
                name: "screen_recorder_type_text",
                description: "Type a string of text character by character. Works in the focused text field by default, or can deliver to a specific app/PID without focusing it.",
                properties: [
                    "text": ["type": "string", "description": "The text to type"],
                    "interval_ms": ["type": "integer", "description": "Delay between characters in ms (default: 50)"],
                    "app": ["type": "string", "description": "Deliver to this app's PID without focusing it"],
                    "pid": ["type": "integer", "description": "Deliver directly to this PID without focusing it"],
                ],
                required: ["text"]
            ),
            toolDef(
                name: "screen_recorder_press_key",
                description: "Press a named key with optional modifier keys. Keys: return, tab, space, delete, escape, up, down, left, right, home, end, pageup, pagedown, f1-f12. Can target a background app/PID.",
                properties: [
                    "key": ["type": "string", "description": "Key name (e.g. 'return', 'tab', 'escape', 'up', 'f5')"],
                    "modifiers": [
                        "type": "array",
                        "description": "Modifier keys to hold: 'cmd', 'shift', 'alt'/'opt', 'ctrl'",
                    ],
                    "app": ["type": "string", "description": "Deliver to this app's PID without focusing it"],
                    "pid": ["type": "integer", "description": "Deliver directly to this PID without focusing it"],
                ],
                required: ["key"]
            ),
            toolDef(
                name: "screen_recorder_hotkey",
                description: "Execute a keyboard shortcut. Format: modifier+key (e.g. 'cmd+c', 'cmd+shift+4', 'ctrl+a'). Can target a background app/PID.",
                properties: [
                    "keys": ["type": "string", "description": "Hotkey string (e.g. 'cmd+c', 'cmd+shift+s', 'ctrl+alt+delete')"],
                    "app": ["type": "string", "description": "Deliver to this app's PID without focusing it"],
                    "pid": ["type": "integer", "description": "Deliver directly to this PID without focusing it"],
                ],
                required: ["keys"]
            ),
            toolDef(
                name: "screen_recorder_click_element",
                description: "Find a text element on screen via OCR and click its center. Combines detect_elements + click. Use when you know the text label of a button/link but not its coordinates.",
                properties: [
                    "text": ["type": "string", "description": "Text to find and click (case-insensitive substring match)"],
                    "window": ["type": "string", "description": "Restrict search to a specific window by app name"],
                    "window_id": ["type": "integer", "description": "Restrict search to a specific window by ID"],
                    "click_count": ["type": "integer", "description": "Number of clicks (default: 1)"],
                    "pid": ["type": "integer", "description": "Deliver the click directly to this PID without focusing it"],
                ],
                required: ["text"]
            ),
            toolDef(
                name: "screen_recorder_launch_app",
                description: "Launch a macOS application by name or bundle identifier. Defaults to background launch unless activate=true. If the target is Safari or a Chromium browser and the task is webpage interaction, prefer browser tools instead of app.launch plus desktop input.",
                properties: [
                    "name": ["type": "string", "description": "App name (e.g. 'Safari', 'Terminal') or bundle ID (e.g. 'com.apple.Safari')"],
                    "activate": ["type": "boolean", "description": "If true, activate/focus the app after launch. Default: false."],
                ],
                required: ["name"]
            ),
            toolDef(
                name: "screen_recorder_activate_app",
                description: "Bring a running application to the foreground.",
                properties: [
                    "name": ["type": "string", "description": "App name or bundle identifier"],
                ],
                required: ["name"]
            ),
            toolDef(
                name: "screen_recorder_list_apps",
                description: "List all running macOS applications with name, bundle ID, PID, and active status.",
                properties: [:]
            ),
            toolDef(
                name: "screen_recorder_browser_status",
                description: "Check whether a browser automation endpoint is reachable. If the task is webpage interaction inside Safari or a Chromium browser, prefer browser tools over app.launch plus input.*.",
                properties: [
                    "backend": ["type": "string", "description": "Browser backend: 'chromium' or 'safari'."],
                    "port": ["type": "integer", "description": "Automation port (default: 9222)"],
                ]
            ),
            toolDef(
                name: "screen_recorder_browser_launch",
                description: "Launch a browser for automation. Use this when the user explicitly wants Safari/Chrome/etc. For webpage work, browser tools are preferred over desktop OCR/mouse input.",
                properties: [
                    "backend": ["type": "string", "description": "Browser backend: 'chromium' or 'safari'."],
                    "app": ["type": "string", "description": "Browser app name, e.g. 'Google Chrome', 'Chromium', 'Brave Browser', or 'Microsoft Edge'."],
                    "port": ["type": "integer", "description": "Automation port to use (default: 9222)"],
                    "url": ["type": "string", "description": "Optional URL to open on launch"],
                    "activate": ["type": "boolean", "description": "If true, bring the browser to the foreground. Default: false."],
                    "isolated": ["type": "boolean", "description": "If true, use a dedicated automation profile directory. Chromium only. Default: true."],
                ]
            ),
            toolDef(
                name: "screen_recorder_browser_launch_and_open",
                description: "Best first step for webpage tasks. Ensures the chosen browser automation backend is available, then opens or navigates to the target URL without requiring desktop clicking or address-bar typing.",
                properties: [
                    "backend": ["type": "string", "description": "Browser backend: 'chromium' or 'safari'."],
                    "app": ["type": "string", "description": "Browser app name, e.g. 'Google Chrome' or 'Safari'."],
                    "port": ["type": "integer", "description": "Automation port to use (default: 9222)"],
                    "url": ["type": "string", "description": "URL to open or navigate to."],
                    "activate": ["type": "boolean", "description": "If true, bring the browser to the foreground. Default: false."],
                    "isolated": ["type": "boolean", "description": "If true, use a dedicated automation profile directory when launching. Chromium only. Default: true."],
                    "new_tab": ["type": "boolean", "description": "If the browser is already running, open the URL in a new tab instead of reusing the current tab. Default: false."],
                ],
                required: ["url"]
            ),
            toolDef(
                name: "screen_recorder_browser_tabs",
                description: "List browser tabs available through the DevTools endpoint.",
                properties: [
                    "backend": ["type": "string", "description": "Browser backend: 'chromium' or 'safari'."],
                    "port": ["type": "integer", "description": "Automation port (default: 9222)"],
                ]
            ),
            toolDef(
                name: "screen_recorder_browser_open_tab",
                description: "Open a new browser tab. Browser-native tab creation is safer and more reliable than opening tabs through desktop hotkeys.",
                properties: [
                    "backend": ["type": "string", "description": "Browser backend: 'chromium' or 'safari'."],
                    "port": ["type": "integer", "description": "Automation port (default: 9222)"],
                    "url": ["type": "string", "description": "URL to open"],
                ],
                required: ["url"]
            ),
            toolDef(
                name: "screen_recorder_browser_activate_tab",
                description: "Activate a browser tab by id, title match, or URL match.",
                properties: [
                    "backend": ["type": "string", "description": "Browser backend: 'chromium' or 'safari'."],
                    "port": ["type": "integer", "description": "Automation port (default: 9222)"],
                    "tab_id": ["type": "string", "description": "Exact browser tab ID"],
                    "title_contains": ["type": "string", "description": "Find a tab whose title contains this text"],
                    "url_contains": ["type": "string", "description": "Find a tab whose URL contains this text"],
                ]
            ),
            toolDef(
                name: "screen_recorder_browser_navigate",
                description: "Navigate a browser tab to a URL using the browser's page API rather than keyboard shortcuts or the address bar.",
                properties: [
                    "backend": ["type": "string", "description": "Browser backend: 'chromium' or 'safari'."],
                    "port": ["type": "integer", "description": "Automation port (default: 9222)"],
                    "url": ["type": "string", "description": "Destination URL"],
                    "tab_id": ["type": "string", "description": "Exact browser tab ID"],
                    "title_contains": ["type": "string", "description": "Find a tab whose title contains this text"],
                    "url_contains": ["type": "string", "description": "Find a tab whose URL contains this text"],
                ],
                required: ["url"]
            ),
            toolDef(
                name: "screen_recorder_browser_eval",
                description: "Evaluate JavaScript inside the browser tab. Use this for DOM state, page variables, and browser-native inspection instead of OCR when possible.",
                properties: [
                    "backend": ["type": "string", "description": "Browser backend: 'chromium' or 'safari'."],
                    "port": ["type": "integer", "description": "Automation port (default: 9222)"],
                    "expression": ["type": "string", "description": "JavaScript expression to evaluate"],
                    "tab_id": ["type": "string", "description": "Exact browser tab ID"],
                    "title_contains": ["type": "string", "description": "Find a tab whose title contains this text"],
                    "url_contains": ["type": "string", "description": "Find a tab whose URL contains this text"],
                ],
                required: ["expression"]
            ),
            toolDef(
                name: "screen_recorder_browser_click",
                description: "Click a DOM element by CSS selector inside the browser. Prefer this over screen-coordinate clicking or OCR for webpage content.",
                properties: [
                    "backend": ["type": "string", "description": "Browser backend: 'chromium' or 'safari'."],
                    "port": ["type": "integer", "description": "Automation port (default: 9222)"],
                    "selector": ["type": "string", "description": "CSS selector to click"],
                    "tab_id": ["type": "string", "description": "Exact browser tab ID"],
                    "title_contains": ["type": "string", "description": "Find a tab whose title contains this text"],
                    "url_contains": ["type": "string", "description": "Find a tab whose URL contains this text"],
                ],
                required: ["selector"]
            ),
            toolDef(
                name: "screen_recorder_browser_type",
                description: "Set the value of a browser DOM element by CSS selector.",
                properties: [
                    "backend": ["type": "string", "description": "Browser backend: 'chromium' or 'safari'."],
                    "port": ["type": "integer", "description": "Automation port (default: 9222)"],
                    "selector": ["type": "string", "description": "CSS selector to type into"],
                    "text": ["type": "string", "description": "Text to set"],
                    "tab_id": ["type": "string", "description": "Exact browser tab ID"],
                    "title_contains": ["type": "string", "description": "Find a tab whose title contains this text"],
                    "url_contains": ["type": "string", "description": "Find a tab whose URL contains this text"],
                ],
                required: ["selector", "text"]
            ),
            toolDef(
                name: "screen_recorder_browser_press_key",
                description: "Dispatch a keyboard key to the page's active element through browser APIs.",
                properties: [
                    "backend": ["type": "string", "description": "Browser backend: 'chromium' or 'safari'."],
                    "port": ["type": "integer", "description": "Automation port (default: 9222)"],
                    "key": ["type": "string", "description": "Key to dispatch, e.g. 'Enter'"],
                    "tab_id": ["type": "string", "description": "Exact browser tab ID"],
                    "title_contains": ["type": "string", "description": "Find a tab whose title contains this text"],
                    "url_contains": ["type": "string", "description": "Find a tab whose URL contains this text"],
                ],
                required: ["key"]
            ),
            toolDef(
                name: "screen_recorder_browser_screenshot",
                description: "Capture a browser tab screenshot using the browser rendering pipeline rather than desktop screen capture.",
                properties: [
                    "backend": ["type": "string", "description": "Browser backend: 'chromium' or 'safari'."],
                    "port": ["type": "integer", "description": "Automation port (default: 9222)"],
                    "output_path": ["type": "string", "description": "Optional output file path"],
                    "base64": ["type": "boolean", "description": "Also return base64 PNG data"],
                    "tab_id": ["type": "string", "description": "Exact browser tab ID"],
                    "title_contains": ["type": "string", "description": "Find a tab whose title contains this text"],
                    "url_contains": ["type": "string", "description": "Find a tab whose URL contains this text"],
                ]
            ),
            toolDef(
                name: "screen_recorder_run_command",
                description: "Run a shell command and return stdout, stderr, and exit code. Uses /bin/zsh.",
                properties: [
                    "command": ["type": "string", "description": "Shell command to execute"],
                    "timeout": ["type": "number", "description": "Timeout in seconds (default: 30)"],
                ],
                required: ["command"]
            ),
            toolDef(
                name: "screen_recorder_check_accessibility",
                description: "Check if Accessibility permission is granted (required for computer control). If not granted, triggers the system permission dialog.",
                properties: [:]
            ),

            // --- Accessibility Tree Tools ---

            toolDef(
                name: "screen_recorder_ax_tree",
                description: "Get the accessibility UI tree of an application. Returns elements with roles, titles, frames, and available actions. Use to understand what UI elements exist.",
                properties: [
                    "app": ["type": "string", "description": "App name (default: focused app)"],
                    "bundle_id": ["type": "string", "description": "Bundle identifier"],
                    "pid": ["type": "integer", "description": "Process ID"],
                    "max_depth": ["type": "integer", "description": "Tree depth limit (default: 3)"],
                ]
            ),
            toolDef(
                name: "screen_recorder_ax_find",
                description: "Find UI elements by title (text/label) or role (AXButton, AXTextField, etc). Returns matching elements with their properties and coordinates.",
                properties: [
                    "title": ["type": "string", "description": "Text/label to search for (case-insensitive substring)"],
                    "role": ["type": "string", "description": "AX role: AXButton, AXTextField, AXStaticText, AXCheckBox, AXMenuItem, etc"],
                    "app": ["type": "string", "description": "App name (default: focused app)"],
                    "bundle_id": ["type": "string", "description": "Bundle identifier"],
                    "pid": ["type": "integer", "description": "Process ID"],
                    "max_results": ["type": "integer", "description": "Max results (default: 50)"],
                ]
            ),
            toolDef(
                name: "screen_recorder_ax_press",
                description: "Press (click) a UI element found by its title/label using the Accessibility API. More reliable than coordinate-based clicking for standard UI elements.",
                properties: [
                    "title": ["type": "string", "description": "Element title/label to press"],
                    "action": ["type": "string", "description": "AX action (default: AXPress). Others: AXOpen, AXShowMenu, AXIncrement, AXDecrement"],
                    "app": ["type": "string", "description": "App name (default: focused app)"],
                    "bundle_id": ["type": "string", "description": "Bundle identifier"],
                    "pid": ["type": "integer", "description": "Process ID"],
                ],
                required: ["title"]
            ),
            toolDef(
                name: "screen_recorder_ax_set_value",
                description: "Set the value of a UI element (e.g., type into a text field, set a slider). Finds element by title/label.",
                properties: [
                    "title": ["type": "string", "description": "Element title/label"],
                    "value": ["type": "string", "description": "Value to set"],
                    "app": ["type": "string", "description": "App name (default: focused app)"],
                    "bundle_id": ["type": "string", "description": "Bundle identifier"],
                    "pid": ["type": "integer", "description": "Process ID"],
                ],
                required: ["title", "value"]
            ),
            toolDef(
                name: "screen_recorder_ax_focused",
                description: "Get the currently focused UI element with its properties, coordinates, and available actions.",
                properties: [:]
            ),
            toolDef(
                name: "screen_recorder_ax_actionable",
                description: "List all actionable UI elements (buttons, text fields, checkboxes, etc) in an app. Returns only elements that have both an identity (title/label) and at least one action.",
                properties: [
                    "app": ["type": "string", "description": "App name (default: focused app)"],
                    "bundle_id": ["type": "string", "description": "Bundle identifier"],
                    "pid": ["type": "integer", "description": "Process ID"],
                    "max_depth": ["type": "integer", "description": "Tree depth limit (default: 10)"],
                    "max_results": ["type": "integer", "description": "Max results (default: 100)"],
                ]
            ),

            // --- Agent Control Lock Tools ---

            toolDef(
                name: "screen_recorder_lock_controls",
                description: "IMPORTANT: Call this at the start of any automated workflow. Blocks all user mouse and keyboard input so your actions won't be interrupted. The user can still press the unlock hotkey to reclaim control at any time.",
                properties: [
                    "unlock_key": ["type": "string", "description": "Hotkey the user presses to override the lock. Format: 'cmd+shift+f12'. Default: 'cmd+shift+f12'."],
                ]
            ),
            toolDef(
                name: "screen_recorder_unlock_controls",
                description: "Release the agent control lock and restore normal user input. Call this when your automated workflow is complete.",
                properties: [:]
            ),
            toolDef(
                name: "screen_recorder_control_status",
                description: "Check whether the agent control lock is currently active.",
                properties: [:]
            ),

            // --- App Lifecycle Tools ---

            toolDef(
                name: "screen_recorder_quit_app",
                description: "Quit a running application by name. Use force=true to force-quit unresponsive apps.",
                properties: [
                    "name": ["type": "string", "description": "App name (case-insensitive)"],
                    "force": ["type": "boolean", "description": "Force-quit (SIGKILL). Default: false (graceful)"],
                ],
                required: ["name"]
            ),
            toolDef(
                name: "screen_recorder_relaunch_app",
                description: "Quit and relaunch an application. Useful when an app is in a bad state.",
                properties: [
                    "name": ["type": "string", "description": "App name (case-insensitive)"],
                ],
                required: ["name"]
            ),
            toolDef(
                name: "screen_recorder_hide_app",
                description: "Hide an app (⌘H). The app remains running but its windows are hidden.",
                properties: [
                    "name": ["type": "string", "description": "App name (case-insensitive)"],
                ],
                required: ["name"]
            ),

            // --- Window Manipulation Tools ---

            toolDef(
                name: "screen_recorder_window_move",
                description: "Move the frontmost window of an app to specific screen coordinates.",
                properties: [
                    "x": ["type": "number", "description": "New X position (screen points, top-left origin)"],
                    "y": ["type": "number", "description": "New Y position (screen points, top-left origin)"],
                    "app": ["type": "string", "description": "App name. Default: frontmost app."],
                ],
                required: ["x", "y"]
            ),
            toolDef(
                name: "screen_recorder_window_resize",
                description: "Resize the frontmost window of an app to specific dimensions.",
                properties: [
                    "width": ["type": "number", "description": "New width in screen points"],
                    "height": ["type": "number", "description": "New height in screen points"],
                    "app": ["type": "string", "description": "App name. Default: frontmost app."],
                ],
                required: ["width", "height"]
            ),
            toolDef(
                name: "screen_recorder_window_minimize",
                description: "Minimize the frontmost window of an app to the Dock.",
                properties: [
                    "app": ["type": "string", "description": "App name. Default: frontmost app."],
                ]
            ),
            toolDef(
                name: "screen_recorder_window_restore",
                description: "Restore (unminimize) the frontmost window of an app from the Dock.",
                properties: [
                    "app": ["type": "string", "description": "App name. Default: frontmost app."],
                ]
            ),

            // --- Sleep / Delay ---

            toolDef(
                name: "screen_recorder_sleep",
                description: "Pause execution for a specified number of milliseconds. Useful for waiting for animations, page loads, or app startup.",
                properties: [
                    "ms": ["type": "integer", "description": "Duration to sleep in milliseconds (e.g. 1000 = 1 second)"],
                ],
                required: ["ms"]
            ),

            // --- Safety Tools ---

            toolDef(
                name: "screen_recorder_safety_settings",
                description: "Get current safety settings (kill switch status, execution mode, confirmation mode, rate limit, app allowlist, recent actions).",
                properties: [:]
            ),
            toolDef(
                name: "screen_recorder_safety_configure",
                description: "Configure safety settings for computer control. Set execution_mode, enabled, confirmation_mode, max_actions_per_second, or app_allowlist.",
                properties: [
                    "execution_mode": ["type": "string", "description": "Execution mode: 'foreground', 'background_safe', or 'background_strict'."],
                    "enabled": ["type": "boolean", "description": "Enable/disable computer control"],
                    "confirmation_mode": ["type": "boolean", "description": "Require user confirmation before each action"],
                    "max_actions_per_second": ["type": "integer", "description": "Rate limit (0 = unlimited, default: 10)"],
                    "app_allowlist": ["type": "array", "description": "Only allow actions on these apps (empty = all apps)"],
                ]
            ),
            toolDef(
                name: "screen_recorder_safety_log",
                description: "Get the audit log of recent computer control actions (last N actions with timestamps and allowed/blocked status).",
                properties: [
                    "count": ["type": "integer", "description": "Number of recent actions to return (default: 20)"],
                ]
            ),
        ]
    }

    // MARK: - Auto-Launch

    /// Attempt to open the Screen Recorder app from standard locations.
    private func autoLaunchApp() async {
        let candidates: [String] = [
            "/Applications/Screen Recorder.app",
            NSString(string: "~/Applications/Screen Recorder.app").expandingTildeInPath,
            // Also try the built app in DerivedData for dev builds
        ]
        for path in candidates {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = false
                try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
                return
            }
        }
        // Fallback: open by bundle ID
        if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.codeitlikemiley.screenrecorder"
        ) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        }
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
