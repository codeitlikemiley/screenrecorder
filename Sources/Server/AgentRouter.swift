import Foundation
import SwiftUI
import Vision

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
        case "elements.detect":
            return try await detectElements(params: params)

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

        // Sessions
        case "session.new":
            return createSession(params: params)
        case "session.list":
            return listSessions()
        case "session.switch":
            return switchSession(params: params)
        case "session.delete":
            return deleteSession(params: params)
        case "session.save":
            return saveSession()
        case "session.export":
            return exportSession(params: params)

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

    // MARK: - Element Detection (Vision OCR)

    private func detectElements(params: [String: Any]?) async throws -> [String: Any] {
        let minConfidence = params?["min_confidence"] as? Double ?? 0.5
        let windowName = params?["window"] as? String
        let windowId = params?["window_id"] as? Int

        // Capture image (same targeting logic as screenshot)
        let captureRect: CGRect
        var captureWindowId: CGWindowID = kCGNullWindowID
        var listOption: CGWindowListOption = .optionOnScreenOnly
        var windowBounds: CGRect? = nil

        if let regionDict = params?["region"] as? [String: Any] {
            let x = regionDict["x"] as? Double ?? 0
            let y = regionDict["y"] as? Double ?? 0
            let w = regionDict["width"] as? Double ?? 0
            let h = regionDict["height"] as? Double ?? 0
            captureRect = CGRect(x: x, y: y, width: w, height: h)
            windowBounds = captureRect
        } else if let windowId = windowId {
            captureWindowId = CGWindowID(windowId)
            listOption = .optionIncludingWindow
            captureRect = CGRect.null
            windowBounds = findWindowBounds(windowId: windowId)
        } else if let windowName = windowName {
            if let wid = findWindowId(appName: windowName) {
                captureWindowId = CGWindowID(wid)
                listOption = .optionIncludingWindow
                captureRect = CGRect.null
                windowBounds = findWindowBounds(windowId: wid)
            } else {
                throw AgentError.captureError("No window found for app: \(windowName)")
            }
        } else {
            guard let screen = NSScreen.main else {
                throw AgentError.captureError("No main screen")
            }
            captureRect = screen.frame
            windowBounds = captureRect
        }

        guard let cgImage = CGWindowListCreateImage(
            captureRect,
            listOption,
            captureWindowId,
            [.bestResolution]
        ) else {
            throw AgentError.captureError("Screenshot failed for element detection")
        }

        let elements = try await runTextRecognition(
            on: cgImage,
            minConfidence: Float(minConfidence),
            imageOrigin: windowBounds ?? CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        )

        return [
            "ok": true,
            "elements": elements,
            "count": elements.count,
            "image_width": cgImage.width,
            "image_height": cgImage.height,
        ]
    }

    private func runTextRecognition(
        on cgImage: CGImage,
        minConfidence: Float,
        imageOrigin: CGRect
    ) async throws -> [[String: Any]] {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                let imgW = CGFloat(cgImage.width)
                let imgH = CGFloat(cgImage.height)

                var elements: [[String: Any]] = []
                for obs in observations {
                    guard let candidate = obs.topCandidates(1).first,
                          candidate.confidence >= minConfidence else { continue }

                    // Vision normalized coords (0-1, bottom-left origin) → pixel coords (top-left origin)
                    let box = obs.boundingBox
                    let x = box.origin.x * imgW
                    let y = (1 - box.origin.y - box.height) * imgH
                    let w = box.width * imgW
                    let h = box.height * imgH

                    // Map pixel coords to screen coords
                    let scaleX = imageOrigin.width / imgW
                    let scaleY = imageOrigin.height / imgH
                    let screenX = imageOrigin.origin.x + x * scaleX
                    let screenY = imageOrigin.origin.y + y * scaleY
                    let screenW = w * scaleX
                    let screenH = h * scaleY

                    elements.append([
                        "text": candidate.string,
                        "confidence": round(Double(candidate.confidence) * 1000) / 1000,
                        "bounds": [
                            "x": round(screenX * 100) / 100,
                            "y": round(screenY * 100) / 100,
                            "width": round(screenW * 100) / 100,
                            "height": round(screenH * 100) / 100,
                        ],
                        "center": [
                            "x": round((screenX + screenW / 2) * 100) / 100,
                            "y": round((screenY + screenH / 2) * 100) / 100,
                        ],
                    ] as [String: Any])
                }

                // Sort top-to-bottom, left-to-right
                elements.sort { a, b in
                    let aB = a["bounds"] as? [String: Any] ?? [:]
                    let bB = b["bounds"] as? [String: Any] ?? [:]
                    let ay = aB["y"] as? Double ?? 0
                    let by = bB["y"] as? Double ?? 0
                    if abs(ay - by) > 10 { return ay < by }
                    let ax = aB["x"] as? Double ?? 0
                    let bx = bB["x"] as? Double ?? 0
                    return ax < bx
                }

                continuation.resume(returning: elements)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Find window bounds from CGWindowList by window ID
    private func findWindowBounds(windowId: Int) -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in windowList {
            let wid = info[kCGWindowNumber as String] as? Int ?? 0
            if wid == windowId, let boundsDict = info[kCGWindowBounds as String] as? [String: Any] {
                let x = boundsDict["X"] as? Double ?? 0
                let y = boundsDict["Y"] as? Double ?? 0
                let w = boundsDict["Width"] as? Double ?? 0
                let h = boundsDict["Height"] as? Double ?? 0
                return CGRect(x: x, y: y, width: w, height: h)
            }
        }
        return nil
    }

    // MARK: - Recording

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
        guard var params = params else { throw AgentError.invalidParams("Missing params") }

        // Activate annotation mode if not already active
        if !state.isAnnotationModeActive {
            state.isAnnotationModeActive = true
            state.isAnnotationVisible = true
        }

        // Resolve window-relative coordinates if window_ref is provided
        var windowOffset: CGPoint = .zero
        if let windowRef = params["window_ref"] as? String {
            // Try as app name first, then as window ID
            if let wid = findWindowId(appName: windowRef),
               let bounds = findWindowBounds(windowId: wid) {
                windowOffset = bounds.origin
            } else if let wid = Int(windowRef), let bounds = findWindowBounds(windowId: wid) {
                windowOffset = bounds.origin
            } else {
                throw AgentError.invalidParams("Window not found: \(windowRef)")
            }
            params.removeValue(forKey: "window_ref")
        } else if let windowRefId = params["window_ref_id"] as? Int {
            if let bounds = findWindowBounds(windowId: windowRefId) {
                windowOffset = bounds.origin
            } else {
                throw AgentError.invalidParams("Window ID not found: \(windowRefId)")
            }
            params.removeValue(forKey: "window_ref_id")
        }

        // Parse annotations from params
        let jsonData = try JSONSerialization.data(withJSONObject: params)
        let batch = try JSONDecoder().decode(AgentAnnotationBatch.self, from: jsonData)

        var added = 0
        for annotation in batch.annotations {
            var stroke = convertToStroke(annotation)
            // Apply window offset to all points
            if windowOffset != .zero {
                stroke.points = stroke.points.map { point in
                    CGPoint(x: point.x + windowOffset.x, y: point.y + windowOffset.y)
                }
            }
            state.annotationState.strokes.append(stroke)
            added += 1
        }

        var result: [String: Any] = ["ok": true, "added": added, "total": state.annotationState.strokes.count]
        if windowOffset != .zero {
            result["window_offset"] = ["x": Double(windowOffset.x), "y": Double(windowOffset.y)]
        }
        return result
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
        let strokes = state.annotationState.strokes.enumerated().map { (index, stroke) -> [String: Any] in
            var dict: [String: Any] = [
                "index": index,
                "tool": stroke.tool.rawValue,
                "point_count": stroke.points.count,
                "line_width": stroke.lineWidth,
            ]

            // Color (extract RGB components)
            if let cgColor = NSColor(stroke.color).usingColorSpace(.sRGB) {
                dict["color"] = [
                    "r": Double(cgColor.redComponent),
                    "g": Double(cgColor.greenComponent),
                    "b": Double(cgColor.blueComponent),
                ]
            }

            // Coordinates
            if let first = stroke.points.first {
                dict["start"] = ["x": Double(first.x), "y": Double(first.y)]
            }
            if stroke.points.count >= 2, let last = stroke.points.last {
                dict["end"] = ["x": Double(last.x), "y": Double(last.y)]
            }

            // Bounding box
            if let rect = stroke.boundingRect {
                dict["bounds"] = [
                    "x": Double(rect.origin.x),
                    "y": Double(rect.origin.y),
                    "width": Double(rect.width),
                    "height": Double(rect.height),
                ]
            } else if stroke.points.count >= 1 {
                // Compute bounding box from all points
                let xs = stroke.points.map(\.x)
                let ys = stroke.points.map(\.y)
                let minX = xs.min()!, maxX = xs.max()!
                let minY = ys.min()!, maxY = ys.max()!
                dict["bounds"] = [
                    "x": Double(minX), "y": Double(minY),
                    "width": Double(maxX - minX),
                    "height": Double(maxY - minY),
                ]
            }

            // Geometry for lines/arrows: length and angle
            if (stroke.tool == .arrow || stroke.tool == .line), stroke.points.count >= 2 {
                let from = stroke.points.first!
                let to = stroke.points.last!
                let dx = to.x - from.x
                let dy = to.y - from.y
                let length = hypot(dx, dy)
                let angle = atan2(dy, dx) * 180.0 / .pi  // degrees from horizontal
                dict["length"] = round(length * 100) / 100
                dict["angle"] = round(angle * 100) / 100
            }

            // Area for shapes
            if (stroke.tool == .rectangle || stroke.tool == .ellipse), let rect = stroke.boundingRect {
                if stroke.tool == .rectangle {
                    dict["area"] = round(Double(rect.width * rect.height) * 100) / 100
                } else {
                    dict["area"] = round(Double.pi * Double(rect.width / 2) * Double(rect.height / 2) * 100) / 100
                }
                dict["center"] = [
                    "x": Double(rect.midX),
                    "y": Double(rect.midY),
                ]
            }

            // Text content
            if let text = stroke.textContent {
                dict["text"] = text
                dict["font_size"] = stroke.lineWidth  // lineWidth stores fontSize for text
            }

            return dict
        }
        return ["strokes": strokes, "count": strokes.count]
    }

    // MARK: - Sessions

    private func createSession(params: [String: Any]?) -> [String: Any] {
        guard let state = appState else { return ["ok": false] }
        let name = params?["name"] as? String ?? "Session \(state.annotationState.sessions.count + 1)"
        let fromCurrent = params?["from_current"] as? Bool ?? false
        let session = state.annotationState.createSession(name: name, fromCurrent: fromCurrent)
        state.annotationState.switchToSession(id: session.id)
        return [
            "ok": true,
            "session_id": session.id.uuidString,
            "name": session.name,
            "stroke_count": session.strokes.count,
        ]
    }

    private func listSessions() -> [String: Any] {
        guard let state = appState else { return ["ok": false] }
        state.annotationState.loadSessions()
        let sessions = state.annotationState.sessions.map { session -> [String: Any] in
            let formatter = ISO8601DateFormatter()
            var dict: [String: Any] = [
                "id": session.id.uuidString,
                "name": session.name,
                "stroke_count": session.strokes.count,
                "created_at": formatter.string(from: session.createdAt),
                "updated_at": formatter.string(from: session.updatedAt),
            ]
            if session.id == state.annotationState.activeSessionId {
                dict["active"] = true
            }
            return dict
        }
        return ["sessions": sessions, "count": sessions.count]
    }

    private func switchSession(params: [String: Any]?) -> [String: Any] {
        guard let state = appState else { return ["ok": false] }
        if let name = params?["name"] as? String {
            if state.annotationState.switchToSession(name: name) {
                return ["ok": true, "name": name, "stroke_count": state.annotationState.strokes.count]
            }
            return ["ok": false, "reason": "Session not found: \(name)"]
        }
        if let idStr = params?["id"] as? String, let id = UUID(uuidString: idStr) {
            state.annotationState.switchToSession(id: id)
            return ["ok": true, "id": idStr, "stroke_count": state.annotationState.strokes.count]
        }
        return ["ok": false, "reason": "Provide 'name' or 'id' parameter"]
    }

    private func deleteSession(params: [String: Any]?) -> [String: Any] {
        guard let state = appState else { return ["ok": false] }
        if let name = params?["name"] as? String {
            if let session = state.annotationState.sessions.first(where: { $0.name.lowercased() == name.lowercased() }) {
                state.annotationState.deleteSession(id: session.id)
                return ["ok": true, "deleted": name]
            }
            return ["ok": false, "reason": "Session not found: \(name)"]
        }
        if let idStr = params?["id"] as? String, let id = UUID(uuidString: idStr) {
            state.annotationState.deleteSession(id: id)
            return ["ok": true, "deleted": idStr]
        }
        return ["ok": false, "reason": "Provide 'name' or 'id' parameter"]
    }

    private func saveSession() -> [String: Any] {
        guard let state = appState else { return ["ok": false] }
        state.annotationState.saveCurrentSession()
        return ["ok": true, "stroke_count": state.annotationState.strokes.count]
    }

    private func exportSession(params: [String: Any]?) -> [String: Any] {
        guard let state = appState else { return ["ok": false] }
        // Export active session or by id/name
        var targetId = state.annotationState.activeSessionId
        if let name = params?["name"] as? String {
            targetId = state.annotationState.sessions.first(where: { $0.name.lowercased() == name.lowercased() })?.id
        } else if let idStr = params?["id"] as? String {
            targetId = UUID(uuidString: idStr)
        }
        guard let id = targetId, let data = state.annotationState.exportSession(id: id),
              let json = String(data: data, encoding: .utf8) else {
            return ["ok": false, "reason": "Session not found or empty"]
        }

        // Optionally save to file
        if let path = params?["output"] as? String {
            try? data.write(to: URL(fileURLWithPath: path))
            return ["ok": true, "file": path]
        }

        return ["ok": true, "json": json]
    }

    // MARK: - Screenshot

    private func captureScreenshot(params: [String: Any]?) async throws -> [String: Any] {
        guard let coordinator = coordinator else { throw AgentError.appNotReady }

        let outputPath = params?["output"] as? String
        let returnBase64 = params?["base64"] as? Bool ?? (outputPath == nil)
        let clean = params?["clean"] as? Bool ?? false
        let windowName = params?["window"] as? String
        let windowId = params?["window_id"] as? Int

        // Determine output file
        let outputURL: URL
        if let path = outputPath {
            outputURL = URL(fileURLWithPath: path)
        } else {
            let tempDir = FileManager.default.temporaryDirectory
            let filename = "screenshot_\(Int(Date().timeIntervalSince1970)).png"
            outputURL = tempDir.appendingPathComponent(filename)
        }

        // If clean mode, hide annotations temporarily
        let wasAnnotationVisible = appState?.isAnnotationVisible ?? false
        if clean && wasAnnotationVisible {
            appState?.isAnnotationVisible = false
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        // Hide toolbar during capture
        coordinator.overlayManager.hideAnnotationToolbarForCapture()
        try await Task.sleep(nanoseconds: 150_000_000)

        // Determine capture rect and window
        let captureRect: CGRect
        var captureWindowId: CGWindowID = kCGNullWindowID
        var listOption: CGWindowListOption = .optionOnScreenOnly

        if let regionDict = params?["region"] as? [String: Any] {
            // Region capture
            let x = regionDict["x"] as? Double ?? 0
            let y = regionDict["y"] as? Double ?? 0
            let w = regionDict["width"] as? Double ?? 0
            let h = regionDict["height"] as? Double ?? 0
            captureRect = CGRect(x: x, y: y, width: w, height: h)
        } else if let windowId = windowId {
            // Window capture by ID
            captureWindowId = CGWindowID(windowId)
            listOption = .optionIncludingWindow
            captureRect = CGRect.null // auto-size to window
        } else if let windowName = windowName {
            // Window capture by app name — find the window ID
            if let wid = findWindowId(appName: windowName) {
                captureWindowId = CGWindowID(wid)
                listOption = .optionIncludingWindow
                captureRect = CGRect.null
            } else {
                restoreAfterCapture(coordinator: coordinator, wasVisible: wasAnnotationVisible, clean: clean)
                throw AgentError.captureError("No window found for app: \(windowName)")
            }
        } else {
            // Full screen
            guard let screen = NSScreen.main else {
                restoreAfterCapture(coordinator: coordinator, wasVisible: wasAnnotationVisible, clean: clean)
                throw AgentError.captureError("No main screen")
            }
            captureRect = screen.frame
        }

        guard let cgImage = CGWindowListCreateImage(
            captureRect,
            listOption,
            captureWindowId,
            [.bestResolution]
        ) else {
            restoreAfterCapture(coordinator: coordinator, wasVisible: wasAnnotationVisible, clean: clean)
            throw AgentError.captureError("CGWindowListCreateImage failed")
        }

        restoreAfterCapture(coordinator: coordinator, wasVisible: wasAnnotationVisible, clean: clean)

        // Convert to PNG
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            throw AgentError.captureError("PNG encoding failed")
        }

        try pngData.write(to: outputURL)

        var result: [String: Any] = [
            "ok": true,
            "file": outputURL.path,
            "width": cgImage.width,
            "height": cgImage.height,
        ]

        if returnBase64 {
            result["base64"] = pngData.base64EncodedString()
        }

        return result
    }

    /// Find window ID by app name (first matching on-screen window).
    private func findWindowId(appName: String) -> Int? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in windowList {
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            if owner.localizedCaseInsensitiveContains(appName) {
                return info[kCGWindowNumber as String] as? Int
            }
        }
        return nil
    }

    /// Restore annotation visibility and toolbar after screenshot capture.
    private func restoreAfterCapture(coordinator: RecordingCoordinator, wasVisible: Bool, clean: Bool) {
        if appState?.isAnnotationModeActive == true {
            coordinator.overlayManager.showAnnotationToolbarAfterCapture()
        }
        if clean && wasVisible {
            appState?.isAnnotationVisible = true
        }
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
