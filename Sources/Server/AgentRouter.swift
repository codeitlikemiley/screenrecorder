import Foundation
import SwiftUI

/// Routes JSON-RPC method calls to app actions.
/// Acts as the bridge between the network layer and the running app.
@MainActor
class AgentRouter {
    private weak var appState: AppState?
    private weak var coordinator: RecordingCoordinator?

    init(appState: AppState, coordinator: RecordingCoordinator) {
        self.appState = appState
        self.coordinator = coordinator
    }

    // MARK: - Dispatch

    /// Dispatch a JSON-RPC method to the appropriate handler.
    func dispatch(method: String, params: [String: Any]?) async throws -> [String: Any] {
        switch method {
        // Status
        case "status":
            return getStatus()

        // Screen & Windows
        case "screen.info":
            return getScreenInfo(params: params)
        case "windows.list":
            return getWindowsList(params: params)
        case "windows.focused":
            return getFocusedWindow()

        // Recording
        case "record.start":
            return try await startRecording()
        case "record.stop":
            return try await stopRecording()

        // Annotation mode
        case "annotate.activate":
            return activateAnnotation()
        case "annotate.deactivate":
            return deactivateAnnotation()

        // Annotation drawing
        case "annotate.add":
            return try addAnnotations(params: params)
        case "annotate.clear":
            return clearAnnotations()
        case "annotate.undo":
            return undoAnnotation()
        case "annotate.redo":
            return redoAnnotation()
        case "annotate.list":
            return listAnnotations()

        // Screenshot
        case "screenshot.capture":
            return try await captureScreenshot(params: params)

        // Tool selection
        case "tool.select":
            return try selectTool(params: params)
        case "tool.color":
            return try setColor(params: params)
        case "tool.lineWidth":
            return try setLineWidth(params: params)

        default:
            throw AgentError.methodNotFound(method)
        }
    }

    // MARK: - Status

    private func getStatus() -> [String: Any] {
        guard let state = appState else { return ["error": "App not ready"] }
        return [
            "recording": state.isRecording,
            "annotating": state.isAnnotationModeActive,
            "annotation_visible": state.isAnnotationVisible,
            "stroke_count": state.annotationState.strokes.count,
            "can_undo": state.annotationState.canUndo,
            "can_redo": state.annotationState.canRedo,
            "selected_tool": state.annotationState.selectedTool.rawValue,
            "line_width": state.annotationState.lineWidth,
            "camera_enabled": state.isCameraEnabled,
            "mic_enabled": state.isMicrophoneEnabled,
            "duration": state.recordingDuration,
        ]
    }

    // MARK: - Screen & Window Info

    private func getScreenInfo(params: [String: Any]?) -> [String: Any] {
        let showAll = params?["all"] as? Bool ?? false
        let screens = showAll ? NSScreen.screens : [NSScreen.main].compactMap { $0 }

        let displays: [[String: Any]] = screens.enumerated().map { (i, screen) in
            let frame = screen.frame
            let visible = screen.visibleFrame
            return [
                "index": i,
                "is_main": screen == NSScreen.main,
                "width": Int(frame.width),
                "height": Int(frame.height),
                "scale_factor": Double(screen.backingScaleFactor),
                "frame": [
                    "x": Double(frame.origin.x),
                    "y": Double(frame.origin.y),
                    "width": Double(frame.width),
                    "height": Double(frame.height),
                ],
                "visible_frame": [
                    "x": Double(visible.origin.x),
                    "y": Double(visible.origin.y),
                    "width": Double(visible.width),
                    "height": Double(visible.height),
                ],
            ] as [String: Any]
        }

        if displays.count == 1, let d = displays.first {
            return d
        }
        return ["displays": displays, "count": displays.count]
    }

    private func getWindowsList(params: [String: Any]?) -> [String: Any] {
        let appFilter = params?["app"] as? String
        let windows = queryWindows(appFilter: appFilter)
        return ["windows": windows, "count": windows.count]
    }

    private func getFocusedWindow() -> [String: Any] {
        let frontApp = NSWorkspace.shared.frontmostApplication
        guard let bundleId = frontApp?.bundleIdentifier else {
            return ["error": "No focused application"]
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return ["error": "Cannot query windows"]
        }

        for info in windowList {
            let ownerPID = info[kCGWindowOwnerPID as String] as? Int32 ?? 0
            if ownerPID == frontApp?.processIdentifier {
                return windowInfoDict(info)
            }
        }
        return ["error": "No focused window found", "app": frontApp?.localizedName ?? bundleId]
    }

    /// Query visible windows, optionally filtering by app name.
    private func queryWindows(appFilter: String? = nil) -> [[String: Any]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var results: [[String: Any]] = []
        for info in windowList {
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            // Skip menu bar, dock, and other system UI (layer > 0)
            guard layer == 0 else { continue }

            let ownerName = info[kCGWindowOwnerName as String] as? String ?? ""
            if let filter = appFilter, !ownerName.localizedCaseInsensitiveContains(filter) {
                continue
            }

            results.append(windowInfoDict(info))
        }
        return results
    }

    private func windowInfoDict(_ info: [String: Any]) -> [String: Any] {
        let windowId = info[kCGWindowNumber as String] as? Int ?? 0
        let ownerName = info[kCGWindowOwnerName as String] as? String ?? ""
        let title = info[kCGWindowName as String] as? String ?? ""
        let layer = info[kCGWindowLayer as String] as? Int ?? 0
        let isOnScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? true

        var bounds: [String: Any] = [:]
        if let boundsDict = info[kCGWindowBounds as String] as? [String: Any] {
            bounds = [
                "x": boundsDict["X"] as? Double ?? 0,
                "y": boundsDict["Y"] as? Double ?? 0,
                "width": boundsDict["Width"] as? Double ?? 0,
                "height": boundsDict["Height"] as? Double ?? 0,
            ]
        }

        return [
            "id": windowId,
            "app": ownerName,
            "title": title,
            "bounds": bounds,
            "is_on_screen": isOnScreen,
            "layer": layer,
        ] as [String: Any]
    }

    private func startRecording() async throws -> [String: Any] {
        guard let coordinator = coordinator else { throw AgentError.appNotReady }
        guard let state = appState, !state.isRecording else {
            return ["ok": false, "reason": "Already recording"]
        }
        await coordinator.toggleRecording()
        // Wait briefly for recording to start
        try await Task.sleep(nanoseconds: 500_000_000)
        return ["ok": true, "recording": appState?.isRecording ?? false]
    }

    private func stopRecording() async throws -> [String: Any] {
        guard let coordinator = coordinator else { throw AgentError.appNotReady }
        guard let state = appState, state.isRecording else {
            return ["ok": false, "reason": "Not recording"]
        }
        await coordinator.toggleRecording()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let file = state.currentRecordingURL?.path ?? ""
        return ["ok": true, "file": file]
    }

    // MARK: - Annotation Mode

    private func activateAnnotation() -> [String: Any] {
        guard let state = appState else { return ["ok": false] }
        state.isAnnotationModeActive = true
        state.isAnnotationVisible = true
        return ["ok": true]
    }

    private func deactivateAnnotation() -> [String: Any] {
        guard let state = appState else { return ["ok": false] }
        state.isAnnotationModeActive = false
        return ["ok": true]
    }

    // MARK: - Annotation Drawing

    private func addAnnotations(params: [String: Any]?) throws -> [String: Any] {
        guard let state = appState else { throw AgentError.appNotReady }
        guard let params = params else { throw AgentError.invalidParams("Missing params") }

        // Activate annotation mode if not already active
        if !state.isAnnotationModeActive {
            state.isAnnotationModeActive = true
            state.isAnnotationVisible = true
        }

        // Parse annotations from params
        let jsonData = try JSONSerialization.data(withJSONObject: params)
        let batch = try JSONDecoder().decode(AgentAnnotationBatch.self, from: jsonData)

        var added = 0
        for annotation in batch.annotations {
            let stroke = convertToStroke(annotation)
            state.annotationState.strokes.append(stroke)
            added += 1
        }

        return ["ok": true, "added": added, "total": state.annotationState.strokes.count]
    }

    private func clearAnnotations() -> [String: Any] {
        guard let state = appState else { return ["ok": false] }
        state.annotationState.clearAll()
        return ["ok": true]
    }

    private func undoAnnotation() -> [String: Any] {
        guard let state = appState else { return ["ok": false] }
        state.annotationState.undo()
        return ["ok": true, "stroke_count": state.annotationState.strokes.count]
    }

    private func redoAnnotation() -> [String: Any] {
        guard let state = appState else { return ["ok": false] }
        state.annotationState.redo()
        return ["ok": true, "stroke_count": state.annotationState.strokes.count]
    }

    private func listAnnotations() -> [String: Any] {
        guard let state = appState else { return ["ok": false] }
        let strokes = state.annotationState.strokes.map { stroke -> [String: Any] in
            var dict: [String: Any] = [
                "tool": stroke.tool.rawValue,
                "point_count": stroke.points.count,
                "line_width": stroke.lineWidth,
            ]
            if let text = stroke.textContent {
                dict["text"] = text
            }
            return dict
        }
        return ["strokes": strokes, "count": strokes.count]
    }

    // MARK: - Screenshot

    private func captureScreenshot(params: [String: Any]?) async throws -> [String: Any] {
        guard let coordinator = coordinator else { throw AgentError.appNotReady }

        let outputPath = params?["output"] as? String
        let returnBase64 = params?["base64"] as? Bool ?? (outputPath == nil)

        // Determine output file
        let outputURL: URL
        if let path = outputPath {
            outputURL = URL(fileURLWithPath: path)
        } else {
            // Default to temp file
            let tempDir = FileManager.default.temporaryDirectory
            let filename = "screenshot_\(Int(Date().timeIntervalSince1970)).png"
            outputURL = tempDir.appendingPathComponent(filename)
        }

        // Hide toolbar during capture
        coordinator.overlayManager.hideAnnotationToolbarForCapture()
        try await Task.sleep(nanoseconds: 150_000_000) // 150ms for window to update

        guard let screen = NSScreen.main else { throw AgentError.captureError("No main screen") }
        let screenRect = screen.frame

        guard let cgImage = CGWindowListCreateImage(
            screenRect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else {
            if appState?.isAnnotationModeActive == true {
                coordinator.overlayManager.showAnnotationToolbarAfterCapture()
            }
            throw AgentError.captureError("CGWindowListCreateImage failed")
        }

        if appState?.isAnnotationModeActive == true {
            coordinator.overlayManager.showAnnotationToolbarAfterCapture()
        }

        // Convert to PNG
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            throw AgentError.captureError("PNG encoding failed")
        }

        // Save to file
        try pngData.write(to: outputURL)

        var result: [String: Any] = [
            "ok": true,
            "file": outputURL.path,
            "width": cgImage.width,
            "height": cgImage.height,
        ]

        // Optionally return base64
        if returnBase64 {
            result["base64"] = pngData.base64EncodedString()
        }

        return result
    }

    // MARK: - Tool Selection

    private func selectTool(params: [String: Any]?) throws -> [String: Any] {
        guard let state = appState else { throw AgentError.appNotReady }
        guard let toolName = params?["tool"] as? String else {
            throw AgentError.invalidParams("Missing 'tool' parameter")
        }

        guard let tool = AnnotationTool(rawValue: toolName) else {
            let valid = AnnotationTool.allCases.map(\.rawValue).joined(separator: ", ")
            throw AgentError.invalidParams("Unknown tool '\(toolName)'. Valid: \(valid)")
        }

        state.annotationState.selectedTool = tool
        return ["ok": true, "tool": tool.rawValue]
    }

    private func setColor(params: [String: Any]?) throws -> [String: Any] {
        guard let state = appState else { throw AgentError.appNotReady }
        guard let colorName = params?["color"] as? String else {
            throw AgentError.invalidParams("Missing 'color' parameter")
        }

        let rgb = AgentAnnotation.resolveColor(colorName)
        state.annotationState.selectedColor = Color(red: rgb.r, green: rgb.g, blue: rgb.b)
        return ["ok": true, "color": colorName]
    }

    private func setLineWidth(params: [String: Any]?) throws -> [String: Any] {
        guard let state = appState else { throw AgentError.appNotReady }
        guard let width = params?["width"] as? CGFloat ?? (params?["width"] as? Int).map(CGFloat.init) else {
            throw AgentError.invalidParams("Missing 'width' parameter")
        }

        state.annotationState.lineWidth = max(1, min(20, width))
        return ["ok": true, "lineWidth": state.annotationState.lineWidth]
    }

    // MARK: - Annotation Conversion

    /// Convert an AgentAnnotation to an AnnotationStroke for rendering.
    private func convertToStroke(_ annotation: AgentAnnotation) -> AnnotationStroke {
        switch annotation {
        case .arrow(let a):
            let rgb = AgentAnnotation.resolveColor(a.color)
            return AnnotationStroke(
                tool: .arrow,
                points: [a.from.cgPoint, a.to.cgPoint],
                color: Color(red: rgb.r, green: rgb.g, blue: rgb.b),
                lineWidth: a.lineWidth ?? 3
            )

        case .rectangle(let a):
            let rgb = AgentAnnotation.resolveColor(a.color)
            let endPoint = CGPoint(
                x: a.origin.x + a.size.width,
                y: a.origin.y + a.size.height
            )
            return AnnotationStroke(
                tool: .rectangle,
                points: [a.origin.cgPoint, endPoint],
                color: Color(red: rgb.r, green: rgb.g, blue: rgb.b),
                lineWidth: a.lineWidth ?? 2
            )

        case .ellipse(let a):
            let rgb = AgentAnnotation.resolveColor(a.color)
            let endPoint = CGPoint(
                x: a.origin.x + a.size.width,
                y: a.origin.y + a.size.height
            )
            return AnnotationStroke(
                tool: .ellipse,
                points: [a.origin.cgPoint, endPoint],
                color: Color(red: rgb.r, green: rgb.g, blue: rgb.b),
                lineWidth: a.lineWidth ?? 2
            )

        case .line(let a):
            let rgb = AgentAnnotation.resolveColor(a.color)
            return AnnotationStroke(
                tool: .line,
                points: [a.from.cgPoint, a.to.cgPoint],
                color: Color(red: rgb.r, green: rgb.g, blue: rgb.b),
                lineWidth: a.lineWidth ?? 2
            )

        case .pen(let a):
            let rgb = AgentAnnotation.resolveColor(a.color)
            return AnnotationStroke(
                tool: .pen,
                points: a.points.map(\.cgPoint),
                color: Color(red: rgb.r, green: rgb.g, blue: rgb.b),
                lineWidth: a.lineWidth ?? 3
            )

        case .text(let a):
            let rgb = AgentAnnotation.resolveColor(a.color)
            return AnnotationStroke(
                tool: .text,
                points: [a.at.cgPoint],
                color: Color(red: rgb.r, green: rgb.g, blue: rgb.b),
                lineWidth: a.fontSize ?? 16,
                textContent: a.text
            )
        }
    }
}

// MARK: - Agent Errors

enum AgentError: LocalizedError {
    case appNotReady
    case methodNotFound(String)
    case invalidParams(String)
    case captureError(String)

    var errorDescription: String? {
        switch self {
        case .appNotReady: return "App not ready"
        case .methodNotFound(let m): return "Method not found: \(m)"
        case .invalidParams(let msg): return "Invalid params: \(msg)"
        case .captureError(let msg): return "Capture error: \(msg)"
        }
    }
}
