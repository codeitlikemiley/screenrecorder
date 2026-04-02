import Foundation
import SwiftUI
import Vision

/// Routes JSON-RPC method calls to app actions.
/// Acts as the bridge between the network layer and the running app.
@MainActor
class AgentRouter {
    private weak var appState: AppState?
    private weak var coordinator: RecordingCoordinator?
    private let inputSynthesizer = InputSynthesizer()

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
            return try await startRecording(params: params)
        case "record.stop":
            return try await stopRecording()
        case "record.pause":
            return pauseRecording()
        case "record.resume":
            return resumeRecording()

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

        // Input synthesis (computer control)
        case "input.click":
            return try inputClick(params: params)
        case "input.right_click":
            return try inputRightClick(params: params)
        case "input.double_click":
            return try inputDoubleClick(params: params)
        case "input.middle_click":
            return try inputMiddleClick(params: params)
        case "input.drag":
            return try inputDrag(params: params)
        case "input.scroll":
            return try inputScroll(params: params)
        case "input.move_mouse":
            return try inputMoveMouse(params: params)
        case "input.type_text":
            return try inputTypeText(params: params)
        case "input.press_key":
            return try inputPressKey(params: params)
        case "input.hotkey":
            return try inputHotkey(params: params)
        case "input.click_element":
            return try await inputClickElement(params: params)
        case "input.type_to_field":
            return try await inputTypeToField(params: params)

        // App control
        case "app.launch":
            return try launchApp(params: params)
        case "app.activate":
            return try activateApp(params: params)
        case "app.list":
            return listApps()

        // Browser automation
        case "browser.status":
            return try await browserStatus(params: params)
        case "browser.launch":
            return try await browserLaunch(params: params)
        case "browser.launch_and_open":
            return try await browserLaunchAndOpen(params: params)
        case "browser.tabs":
            return try await browserTabs(params: params)
        case "browser.open_tab":
            return try await browserOpenTab(params: params)
        case "browser.activate_tab":
            return try await browserActivateTab(params: params)
        case "browser.navigate":
            return try await browserNavigate(params: params)
        case "browser.eval":
            return try await browserEval(params: params)
        case "browser.click":
            return try await browserClick(params: params)
        case "browser.type":
            return try await browserType(params: params)
        case "browser.press_key":
            return try await browserPressKey(params: params)
        case "browser.screenshot":
            return try await browserScreenshot(params: params)

        // Shell command execution
        case "shell.exec":
            return try execShellCommand(params: params)

        // Accessibility permission
        case "accessibility.check":
            return checkAccessibility()

        // Accessibility tree (AXUIElement)
        case "ax.tree":
            return axGetTree(params: params)
        case "ax.find":
            return axFindElements(params: params)
        case "ax.press":
            return axPressElement(params: params)
        case "ax.set_value":
            return axSetValue(params: params)
        case "ax.focused":
            return axFocusedElement()
        case "ax.actionable":
            return axActionableElements(params: params)

        // Safety settings
        case "safety.settings":
            return SafetyGuard.shared.currentSettings()
        case "safety.configure":
            return configureSafety(params: params)
        case "safety.log":
            let count = params?["count"] as? Int ?? 20
            return ["actions": SafetyGuard.shared.recentActions(count: count)]

        // Agent Control Lock — blocks user input while agent runs
        case "input.lock_for_agent":
            return lockForAgent(params: params)
        case "input.unlock":
            return unlockForUser()
        case "input.lock_status":
            return AgentControlLock.shared.status()

        // App lifecycle extras
        case "app.quit":
            return try quitApp(params: params)
        case "app.relaunch":
            return try relaunchApp(params: params)
        case "app.hide":
            return try hideApp(params: params)

        // Window manipulation
        case "window.move":
            return try moveWindow(params: params)
        case "window.resize":
            return try resizeWindow(params: params)
        case "window.minimize":
            return try minimizeWindow(params: params)
        case "window.restore":
            return try restoreWindow(params: params)

        // Sleep / delay
        case "sleep":
            return try sleepMs(params: params)

        default:
            throw AgentError.methodNotFound(method)
        }
    }

    /// Gate check — returns an error result if the action is blocked, nil if allowed.
    private func safetyGate(
        action: String,
        targetApp: String? = nil,
        characteristics: Set<SafetyGuard.ActionCharacteristic> = []
    ) -> [String: Any]? {
        let (allowed, reason) = SafetyGuard.shared.checkAction(
            action,
            targetApp: targetApp,
            characteristics: characteristics
        )
        if !allowed {
            return ["ok": false, "error": reason ?? "Action blocked by safety guard"]
        }
        return nil
    }

    private func configureSafety(params: [String: Any]?) -> [String: Any] {
        if let modeRaw = params?["execution_mode"] as? String,
           SafetyGuard.ExecutionMode(rawValue: modeRaw) == nil {
            return [
                "ok": false,
                "error": "Invalid execution_mode '\(modeRaw)'. Valid: foreground, background_safe, background_strict",
            ]
        }
        if let settings = params {
            SafetyGuard.shared.configure(settings)
        }
        return ["ok": true, "settings": SafetyGuard.shared.currentSettings()]
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
            "execution_mode": SafetyGuard.shared.currentSettings()["execution_mode"] as? String ?? "background_safe",
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

    private func startRecording(params: [String: Any]?) async throws -> [String: Any] {
        guard let coordinator = coordinator else { throw AgentError.appNotReady }
        guard let state = appState, !state.isRecording else {
            return ["ok": false, "reason": "Already recording"]
        }

        // Apply configuration from params
        if let camera = params?["camera"] as? Bool {
            state.isCameraEnabled = camera
        }
        if let mic = params?["mic"] as? Bool {
            state.isMicrophoneEnabled = mic
        }
        if let keystrokes = params?["keystrokes"] as? Bool {
            state.isKeystrokeOverlayEnabled = keystrokes
        }
        if let fps = params?["fps"] as? Int {
            state.frameRate = fps
        }

        await coordinator.toggleRecording()
        try await Task.sleep(nanoseconds: 500_000_000)
        return [
            "ok": true,
            "recording": appState?.isRecording ?? false,
            "mode": state.recordingMode == .ai ? "ai" : "normal",
        ]
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

    // MARK: - Pause / Resume

    private func pauseRecording() -> [String: Any] {
        guard let state = appState, state.isRecording else {
            return ["ok": false, "reason": "Not recording"]
        }
        state.isPaused = true
        return ["ok": true]
    }

    private func resumeRecording() -> [String: Any] {
        guard let state = appState, state.isRecording else {
            return ["ok": false, "reason": "Not recording"]
        }
        state.isPaused = false
        return ["ok": true]
    }

    // MARK: - Annotation Mode

    private func activateAnnotation() -> [String: Any] {
        guard let state = appState else { return ["ok": false] }
        if !state.isAnnotationModeActive {
            // Route through coordinator so onAnnotationModeChanged fires (registers hotkeys)
            coordinator?.toggleAnnotationMode()
        }
        state.isAnnotationVisible = true
        return ["ok": true]
    }

    private func deactivateAnnotation() -> [String: Any] {
        guard let state = appState else { return ["ok": false] }
        if state.isAnnotationModeActive {
            // Route through coordinator so onAnnotationModeChanged fires (unregisters hotkeys)
            coordinator?.toggleAnnotationMode()
        }
        return ["ok": true]
    }

    // MARK: - Annotation Drawing

    private func addAnnotations(params: [String: Any]?) throws -> [String: Any] {
        guard let state = appState else { throw AgentError.appNotReady }
        guard var params = params else { throw AgentError.invalidParams("Missing params") }

        // Activate annotation mode if not already active
        if !state.isAnnotationModeActive {
            coordinator?.toggleAnnotationMode()  // fires onAnnotationModeChanged -> registers hotkeys
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

        // Size control params
        let scaleFactor = params?["scale"] as? Double ?? 1.0        // 0.0–1.0 downsample
        let jpegQuality = params?["quality"] as? Double             // nil = PNG, 0–1 = JPEG
        let maxBytes    = params?["max_bytes"] as? Int ?? 4_900_000 // 4.9 MB (just under 5 MB API limit)

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
            // Full screen — capture the display where the app resides
            // or the key window display (NSScreen.main).
            guard let screen = NSScreen.main else {
                restoreAfterCapture(coordinator: coordinator, wasVisible: wasAnnotationVisible, clean: clean)
                throw AgentError.captureError("No primary screen")
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

        // --- Size Control ---
        // 1. Optional downscale
        var finalImage: CGImage = cgImage
        if scaleFactor > 0 && scaleFactor < 1.0 {
            let newW = Int(Double(cgImage.width) * scaleFactor)
            let newH = Int(Double(cgImage.height) * scaleFactor)
            if newW > 0 && newH > 0,
               let ctx = CGContext(
                    data: nil, width: newW, height: newH,
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
               ) {
                ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
                finalImage = ctx.makeImage() ?? cgImage
            }
        }

        // 2. Encode — JPEG if quality specified, else PNG
        let bitmapRep = NSBitmapImageRep(cgImage: finalImage)

        func encode(quality q: Double?) -> Data? {
            if let q = q {
                return bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: q])
            }
            return bitmapRep.representation(using: .png, properties: [:])
        }

        var imageData: Data
        if var q = jpegQuality {
            // User specified JPEG — honour their quality but still cap at maxBytes
            guard var data = encode(quality: q) else {
                throw AgentError.captureError("JPEG encoding failed")
            }
            // Auto-reduce quality until under maxBytes
            while data.count > maxBytes && q > 0.05 {
                q = max(q - 0.1, 0.05)
                data = encode(quality: q) ?? data
            }
            imageData = data
        } else {
            // No quality specified — try PNG first
            guard let pngData = encode(quality: nil) else {
                throw AgentError.captureError("PNG encoding failed")
            }
            if pngData.count <= maxBytes {
                imageData = pngData
            } else {
                // PNG too large — auto convert to JPEG and reduce until it fits
                var q = 0.8
                var jpegData = encode(quality: q) ?? pngData
                while jpegData.count > maxBytes && q > 0.05 {
                    q = max(q - 0.1, 0.05)
                    jpegData = encode(quality: q) ?? jpegData
                }
                imageData = jpegData
            }
        }

        // 3. Write to disk (use .jpg extension if JPEG)
        var writeURL = outputURL
        if jpegQuality != nil || imageData.count != (encode(quality: nil)?.count ?? 0) {
            if writeURL.pathExtension.lowercased() == "png" {
                writeURL = writeURL.deletingPathExtension().appendingPathExtension("jpg")
            }
        }
        try imageData.write(to: writeURL)

        var result: [String: Any] = [
            "ok": true,
            "file": writeURL.path,
            "width": finalImage.width,
            "height": finalImage.height,
            "size_bytes": imageData.count,
        ]

        if returnBase64 {
            result["base64"] = imageData.base64EncodedString()
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

    private func findWindowOwnerPid(windowId: Int) -> pid_t? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in windowList {
            let currentId = info[kCGWindowNumber as String] as? Int ?? 0
            if currentId == windowId {
                let pid = info[kCGWindowOwnerPID as String] as? Int32 ?? 0
                return pid == 0 ? nil : pid
            }
        }
        return nil
    }

    private func findWindowOwnerName(windowId: Int) -> String? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in windowList {
            let currentId = info[kCGWindowNumber as String] as? Int ?? 0
            if currentId == windowId {
                let owner = info[kCGWindowOwnerName as String] as? String
                return owner?.isEmpty == false ? owner : nil
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

    // MARK: - Input Synthesis (Computer Control)

    /// Helper to resolve optional window-relative coordinates.
    /// If window_ref or window_ref_id is provided, coordinates are offset by the window's origin.
    private func resolveWindowOffset(params: [String: Any]?) -> CGPoint {
        if let windowRef = params?["window_ref"] as? String {
            if let wid = findWindowId(appName: windowRef),
               let bounds = findWindowBounds(windowId: wid) {
                return bounds.origin
            }
        } else if let windowRefId = params?["window_ref_id"] as? Int {
            if let bounds = findWindowBounds(windowId: windowRefId) {
                return bounds.origin
            }
        }
        return .zero
    }

    /// Resolve a CGPoint from params, applying window offset if provided.
    private func resolvePoint(x: Double, y: Double, offset: CGPoint) -> CGPoint {
        return CGPoint(x: x + Double(offset.x), y: y + Double(offset.y))
    }

    private func resolveTargetPid(params: [String: Any]?) -> pid_t {
        if let pid = params?["pid"] as? Int32, pid != 0 {
            return pid
        }
        if let pid = params?["pid"] as? Int, pid != 0 {
            return pid_t(pid)
        }
        if let windowId = params?["window_id"] as? Int,
           let pid = findWindowOwnerPid(windowId: windowId) {
            return pid
        }
        if let windowRefId = params?["window_ref_id"] as? Int,
           let pid = findWindowOwnerPid(windowId: windowRefId) {
            return pid
        }
        if let windowName = params?["window"] as? String,
           let windowId = findWindowId(appName: windowName),
           let pid = findWindowOwnerPid(windowId: windowId) {
            return pid
        }
        if let windowRef = params?["window_ref"] as? String,
           let windowId = findWindowId(appName: windowRef),
           let pid = findWindowOwnerPid(windowId: windowId) {
            return pid
        }
        let appName = (params?["app"] as? String) ?? (params?["target_app"] as? String)
        if let appName,
           let app = NSWorkspace.shared.runningApplications.first(where: {
               $0.localizedName?.localizedCaseInsensitiveContains(appName) ?? false
           }) {
            return app.processIdentifier
        }
        return 0
    }

    private func resolveTargetAppName(params: [String: Any]?) -> String? {
        if let app = params?["app"] as? String, !app.isEmpty {
            return app
        }
        if let targetApp = params?["target_app"] as? String, !targetApp.isEmpty {
            return targetApp
        }
        if let window = params?["window"] as? String, !window.isEmpty {
            return window
        }
        if let windowRef = params?["window_ref"] as? String, !windowRef.isEmpty {
            return windowRef
        }
        if let windowId = params?["window_id"] as? Int,
           let owner = findWindowOwnerName(windowId: windowId) {
            return owner
        }
        if let windowRefId = params?["window_ref_id"] as? Int,
           let owner = findWindowOwnerName(windowId: windowRefId) {
            return owner
        }
        if let pid = params?["pid"] as? Int {
            return NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid_t(pid) })?.localizedName
        }
        if let pid = params?["pid"] as? Int32 {
            return NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid })?.localizedName
        }
        return nil
    }

    private func inputClick(params: [String: Any]?) throws -> [String: Any] {
        guard InputSynthesizer.checkAccessibilityPermission() else {
            return ["ok": false, "error": "Accessibility permission not granted. Open System Settings → Privacy & Security → Accessibility and add Screen Recorder."]
        }
        guard let x = params?["x"] as? Double, let y = params?["y"] as? Double else {
            throw AgentError.invalidParams("Missing 'x' and 'y' coordinates")
        }
        let offset = resolveWindowOffset(params: params)
        let point = resolvePoint(x: x, y: y, offset: offset)
        let clickCount = params?["click_count"] as? Int ?? 1
        let targetPid = resolveTargetPid(params: params)
        let characteristics: Set<SafetyGuard.ActionCharacteristic> = targetPid == 0 ? [.usesFrontmostInput, .movesRealCursor] : []
        if let blocked = safetyGate(
            action: "click at (\(Int(point.x)), \(Int(point.y)))",
            targetApp: resolveTargetAppName(params: params),
            characteristics: characteristics
        ) { return blocked }
        inputSynthesizer.click(at: point, clickCount: clickCount, targetPid: targetPid)
        return ["ok": true, "clicked_at": ["x": point.x, "y": point.y], "click_count": clickCount, "target_pid": Int(targetPid)]
    }

    private func inputRightClick(params: [String: Any]?) throws -> [String: Any] {
        guard InputSynthesizer.checkAccessibilityPermission() else {
            return ["ok": false, "error": "Accessibility permission not granted"]
        }
        guard let x = params?["x"] as? Double, let y = params?["y"] as? Double else {
            throw AgentError.invalidParams("Missing 'x' and 'y' coordinates")
        }
        let offset = resolveWindowOffset(params: params)
        let point = resolvePoint(x: x, y: y, offset: offset)
        let targetPid = resolveTargetPid(params: params)
        let characteristics: Set<SafetyGuard.ActionCharacteristic> = targetPid == 0 ? [.usesFrontmostInput, .movesRealCursor] : []
        if let blocked = safetyGate(
            action: "right-click at (\(Int(point.x)), \(Int(point.y)))",
            targetApp: resolveTargetAppName(params: params),
            characteristics: characteristics
        ) { return blocked }
        inputSynthesizer.rightClick(at: point, targetPid: targetPid)
        return ["ok": true, "right_clicked_at": ["x": point.x, "y": point.y], "target_pid": Int(targetPid)]
    }

    private func inputDoubleClick(params: [String: Any]?) throws -> [String: Any] {
        guard InputSynthesizer.checkAccessibilityPermission() else {
            return ["ok": false, "error": "Accessibility permission not granted"]
        }
        guard let x = params?["x"] as? Double, let y = params?["y"] as? Double else {
            throw AgentError.invalidParams("Missing 'x' and 'y' coordinates")
        }
        let offset = resolveWindowOffset(params: params)
        let point = resolvePoint(x: x, y: y, offset: offset)
        let targetPid = resolveTargetPid(params: params)
        let characteristics: Set<SafetyGuard.ActionCharacteristic> = targetPid == 0 ? [.usesFrontmostInput, .movesRealCursor] : []
        if let blocked = safetyGate(
            action: "double-click at (\(Int(point.x)), \(Int(point.y)))",
            targetApp: resolveTargetAppName(params: params),
            characteristics: characteristics
        ) { return blocked }
        inputSynthesizer.doubleClick(at: point, targetPid: targetPid)
        return ["ok": true, "double_clicked_at": ["x": point.x, "y": point.y], "target_pid": Int(targetPid)]
    }

    private func inputMiddleClick(params: [String: Any]?) throws -> [String: Any] {
        guard InputSynthesizer.checkAccessibilityPermission() else {
            return ["ok": false, "error": "Accessibility permission not granted"]
        }
        guard let x = params?["x"] as? Double, let y = params?["y"] as? Double else {
            throw AgentError.invalidParams("Missing 'x' and 'y' coordinates")
        }
        let offset = resolveWindowOffset(params: params)
        let point = resolvePoint(x: x, y: y, offset: offset)
        let targetPid = resolveTargetPid(params: params)
        let characteristics: Set<SafetyGuard.ActionCharacteristic> = targetPid == 0 ? [.usesFrontmostInput, .movesRealCursor] : []
        if let blocked = safetyGate(
            action: "middle-click at (\(Int(point.x)), \(Int(point.y)))",
            targetApp: resolveTargetAppName(params: params),
            characteristics: characteristics
        ) { return blocked }
        inputSynthesizer.middleClick(at: point, targetPid: targetPid)
        return ["ok": true, "middle_clicked_at": ["x": point.x, "y": point.y], "target_pid": Int(targetPid)]
    }

    private func inputDrag(params: [String: Any]?) throws -> [String: Any] {
        guard InputSynthesizer.checkAccessibilityPermission() else {
            return ["ok": false, "error": "Accessibility permission not granted"]
        }
        guard let fromX = params?["from_x"] as? Double, let fromY = params?["from_y"] as? Double,
              let toX = params?["to_x"] as? Double, let toY = params?["to_y"] as? Double
        else {
            throw AgentError.invalidParams("Missing 'from_x', 'from_y', 'to_x', 'to_y' coordinates")
        }
        if resolveTargetPid(params: params) != 0 {
            return ["ok": false, "error": "Background drag is not supported yet. Use focused drag or an app-specific AX action instead."]
        }
        let offset = resolveWindowOffset(params: params)
        let from = resolvePoint(x: fromX, y: fromY, offset: offset)
        let to = resolvePoint(x: toX, y: toY, offset: offset)
        let duration = params?["duration"] as? Double ?? 0.5
        let steps = params?["steps"] as? Int ?? 20
        if let blocked = safetyGate(
            action: "drag (\(Int(from.x)),\(Int(from.y))) → (\(Int(to.x)),\(Int(to.y)))",
            targetApp: resolveTargetAppName(params: params),
            characteristics: [.usesFrontmostInput, .movesRealCursor]
        ) { return blocked }
        inputSynthesizer.drag(from: from, to: to, duration: duration, steps: steps)
        return ["ok": true, "dragged_from": ["x": from.x, "y": from.y], "dragged_to": ["x": to.x, "y": to.y]]
    }

    private func inputScroll(params: [String: Any]?) throws -> [String: Any] {
        guard InputSynthesizer.checkAccessibilityPermission() else {
            return ["ok": false, "error": "Accessibility permission not granted"]
        }
        guard let x = params?["x"] as? Double, let y = params?["y"] as? Double else {
            throw AgentError.invalidParams("Missing 'x' and 'y' coordinates")
        }
        let offset = resolveWindowOffset(params: params)
        let point = resolvePoint(x: x, y: y, offset: offset)
        let deltaX = Int32(params?["delta_x"] as? Double ?? 0)
        let deltaY = Int32(params?["delta_y"] as? Double ?? 0)
        let targetPid = resolveTargetPid(params: params)
        guard deltaX != 0 || deltaY != 0 else {
            throw AgentError.invalidParams("At least one of 'delta_x' or 'delta_y' must be non-zero")
        }
        let characteristics: Set<SafetyGuard.ActionCharacteristic> = targetPid == 0 ? [.usesFrontmostInput, .movesRealCursor] : []
        if let blocked = safetyGate(
            action: "scroll at (\(Int(point.x)), \(Int(point.y))) dy=\(deltaY)",
            targetApp: resolveTargetAppName(params: params),
            characteristics: characteristics
        ) { return blocked }
        inputSynthesizer.scroll(at: point, deltaX: deltaX, deltaY: deltaY, targetPid: targetPid)
        return ["ok": true, "scrolled_at": ["x": point.x, "y": point.y], "delta_x": deltaX, "delta_y": deltaY, "target_pid": Int(targetPid)]
    }

    private func inputMoveMouse(params: [String: Any]?) throws -> [String: Any] {
        guard InputSynthesizer.checkAccessibilityPermission() else {
            return ["ok": false, "error": "Accessibility permission not granted"]
        }
        guard let x = params?["x"] as? Double, let y = params?["y"] as? Double else {
            throw AgentError.invalidParams("Missing 'x' and 'y' coordinates")
        }
        let offset = resolveWindowOffset(params: params)
        let point = resolvePoint(x: x, y: y, offset: offset)
        if let blocked = safetyGate(
            action: "move mouse to (\(Int(point.x)), \(Int(point.y)))",
            targetApp: resolveTargetAppName(params: params),
            characteristics: [.movesRealCursor]
        ) { return blocked }
        inputSynthesizer.moveMouse(to: point)
        return ["ok": true, "moved_to": ["x": point.x, "y": point.y]]
    }

    private func inputTypeText(params: [String: Any]?) throws -> [String: Any] {
        guard InputSynthesizer.checkAccessibilityPermission() else {
            return ["ok": false, "error": "Accessibility permission not granted"]
        }
        guard let text = params?["text"] as? String else {
            throw AgentError.invalidParams("Missing 'text' parameter")
        }
        let intervalMs = params?["interval_ms"] as? Int ?? 50
        let targetPid = resolveTargetPid(params: params)
        let characteristics: Set<SafetyGuard.ActionCharacteristic> = targetPid == 0 ? [.usesFrontmostInput] : []
        if let blocked = safetyGate(
            action: "type text: \"\(text.prefix(50))\"",
            targetApp: resolveTargetAppName(params: params),
            characteristics: characteristics
        ) { return blocked }
        inputSynthesizer.typeText(text, intervalMs: intervalMs, targetPid: targetPid)
        return ["ok": true, "typed": text, "char_count": text.count, "target_pid": Int(targetPid)]
    }

    private func inputPressKey(params: [String: Any]?) throws -> [String: Any] {
        guard InputSynthesizer.checkAccessibilityPermission() else {
            return ["ok": false, "error": "Accessibility permission not granted"]
        }
        guard let key = params?["key"] as? String else {
            throw AgentError.invalidParams("Missing 'key' parameter")
        }

        // Parse optional modifiers
        var flags: CGEventFlags = []
        if let modifiers = params?["modifiers"] as? [String] {
            for mod in modifiers {
                switch mod.lowercased() {
                case "cmd", "command", "⌘": flags.insert(.maskCommand)
                case "shift", "⇧":         flags.insert(.maskShift)
                case "alt", "opt", "option", "⌥": flags.insert(.maskAlternate)
                case "ctrl", "control", "⌃": flags.insert(.maskControl)
                default: break
                }
            }
        }

        let targetPid = resolveTargetPid(params: params)
        let characteristics: Set<SafetyGuard.ActionCharacteristic> = targetPid == 0 ? [.usesFrontmostInput] : []
        if let blocked = safetyGate(
            action: "press key: \(key)",
            targetApp: resolveTargetAppName(params: params),
            characteristics: characteristics
        ) { return blocked }
        guard inputSynthesizer.pressNamedKey(key, modifiers: flags, targetPid: targetPid) else {
            throw AgentError.invalidParams("Unknown key name: '\(key)'. Valid: return, tab, space, delete, escape, up, down, left, right, home, end, pageup, pagedown, f1-f12")
        }
        return ["ok": true, "pressed": key, "target_pid": Int(targetPid)]
    }

    private func inputHotkey(params: [String: Any]?) throws -> [String: Any] {
        guard InputSynthesizer.checkAccessibilityPermission() else {
            return ["ok": false, "error": "Accessibility permission not granted"]
        }
        guard let hotkeyString = params?["keys"] as? String else {
            throw AgentError.invalidParams("Missing 'keys' parameter (e.g. 'cmd+c', 'ctrl+shift+4')")
        }
        let targetPid = resolveTargetPid(params: params)
        let characteristics: Set<SafetyGuard.ActionCharacteristic> = targetPid == 0 ? [.usesFrontmostInput] : []
        if let blocked = safetyGate(
            action: "hotkey: \(hotkeyString)",
            targetApp: resolveTargetAppName(params: params),
            characteristics: characteristics
        ) { return blocked }
        guard inputSynthesizer.parseAndExecuteHotkey(hotkeyString, targetPid: targetPid) else {
            throw AgentError.invalidParams("Could not parse hotkey: '\(hotkeyString)'. Format: 'cmd+c', 'ctrl+shift+a'")
        }
        return ["ok": true, "executed": hotkeyString, "target_pid": Int(targetPid)]
    }

    private func inputClickElement(params: [String: Any]?) async throws -> [String: Any] {
        guard InputSynthesizer.checkAccessibilityPermission() else {
            return ["ok": false, "error": "Accessibility permission not granted"]
        }
        guard let text = params?["text"] as? String else {
            throw AgentError.invalidParams("Missing 'text' parameter — the element text to find and click")
        }

        // Use element detection to find the text
        var detectParams: [String: Any] = ["min_confidence": 0.5]
        if let window = params?["window"] as? String { detectParams["window"] = window }
        if let windowId = params?["window_id"] as? Int { detectParams["window_id"] = windowId }

        let result = try await detectElements(params: detectParams)
        guard let elements = result["elements"] as? [[String: Any]] else {
            return ["ok": false, "error": "Element detection returned no results"]
        }

        // Find element matching the text (case-insensitive, substring match)
        let searchText = text.lowercased()
        guard let match = elements.first(where: {
            ($0["text"] as? String ?? "").lowercased().contains(searchText)
        }) else {
            let available = elements.compactMap { $0["text"] as? String }.prefix(10)
            return ["ok": false, "error": "Element '\(text)' not found", "available_elements": Array(available)]
        }

        // Get center coordinates of the matched element
        var cx: Double
        var cy: Double
        if let center = match["center"] as? [String: Any],
           let ocx = center["x"] as? Double,
           let ocy = center["y"] as? Double {
            cx = ocx
            cy = ocy
        } else {
            // OCR found text but couldn't get coordinates (common for browser chrome UI).
            // Fall back to AX API: search the target app's accessibility tree.
            let appName = (params?["window"] as? String) ?? ""
            let axRoot: AXUIElement?
            if !appName.isEmpty {
                axRoot = AccessibilityBridge.appElement(named: appName)
            } else {
                axRoot = AccessibilityBridge.focusedApplication()
            }
            if let root = axRoot,
               let el = AccessibilityBridge.findElement(in: root, withTitle: text),
               let center = AccessibilityBridge.center(of: el) {
                cx = Double(center.x)
                cy = Double(center.y)
            } else {
                return ["ok": false, "error": "Element '\(text)' found via OCR but has no center coordinates, and AX fallback also failed. Try clicking by coordinate using 'sr detect' to find position."]
            }
        }

        let clickCount = params?["click_count"] as? Int ?? 1
        let targetPid = resolveTargetPid(params: params)
        let characteristics: Set<SafetyGuard.ActionCharacteristic> = targetPid == 0 ? [.usesFrontmostInput, .movesRealCursor] : []
        if let blocked = safetyGate(
            action: "click element '\(text)'",
            targetApp: resolveTargetAppName(params: params),
            characteristics: characteristics
        ) { return blocked }
        inputSynthesizer.click(at: CGPoint(x: cx, y: cy), clickCount: clickCount, targetPid: targetPid)

        return [
            "ok": true,
            "clicked_element": match["text"] ?? text,
            "clicked_at": ["x": cx, "y": cy],
            "click_count": clickCount,
            "confidence": match["confidence"] ?? 0,
            "target_pid": Int(targetPid),
        ]
    }

    // MARK: - input.type_to_field

    /// Atomically focus an AX text field by label/placeholder and type into it.
    private func inputTypeToField(params: [String: Any]?) async throws -> [String: Any] {
        guard InputSynthesizer.checkAccessibilityPermission() else {
            return ["ok": false, "error": "Accessibility permission not granted"]
        }
        guard let fieldHint = params?["field"] as? String else {
            throw AgentError.invalidParams("Missing 'field' parameter — label or placeholder of the text field")
        }
        guard let text = params?["text"] as? String else {
            throw AgentError.invalidParams("Missing 'text' parameter")
        }
        let intervalMs = params?["interval_ms"] as? Int ?? 50
        let targetPid = resolveTargetPid(params: params)
        let characteristics: Set<SafetyGuard.ActionCharacteristic> = targetPid == 0 ? [.usesFrontmostInput, .movesRealCursor] : []

        // Resolve target app
        let axRoot: AXUIElement?
        if let appName = params?["app"] as? String, !appName.isEmpty {
            axRoot = AccessibilityBridge.appElement(named: appName)
        } else {
            axRoot = AccessibilityBridge.focusedApplication()
        }
        guard let root = axRoot else {
            return ["ok": false, "error": "Could not resolve target application"]
        }

        // Search for a text field with matching label/placeholder/title
        let textFields = AccessibilityBridge.findElements(in: root, role: "AXTextField", maxResults: 30)
            + AccessibilityBridge.findElements(in: root, role: "AXTextArea", maxResults: 10)
            + AccessibilityBridge.findElements(in: root, role: "AXComboBox", maxResults: 10)
        let hint = fieldHint.lowercased()
        let match = textFields.first(where: { el in
            let title = AccessibilityBridge.stringAttribute(kAXTitleAttribute as String, of: el)?.lowercased() ?? ""
            let desc  = AccessibilityBridge.stringAttribute(kAXDescriptionAttribute as String, of: el)?.lowercased() ?? ""
            let ph    = AccessibilityBridge.stringAttribute(kAXPlaceholderValueAttribute as String, of: el)?.lowercased() ?? ""
            let label = AccessibilityBridge.stringAttribute(kAXLabelValueAttribute as String, of: el)?.lowercased() ?? ""
            return title.contains(hint) || desc.contains(hint) || ph.contains(hint) || label.contains(hint)
        })

        if let el = match {
            if let blocked = safetyGate(
                action: "type to field '\(fieldHint)': \"\(text.prefix(50))\"",
                targetApp: resolveTargetAppName(params: params),
                characteristics: characteristics
            ) { return blocked }
            // Focus via AX first
            AccessibilityBridge.setFocus(on: el)
            // Give focus a moment to settle
            try await Task.sleep(nanoseconds: 150_000_000)
            // Also click its center to ensure cursor is in field
            if let center = AccessibilityBridge.center(of: el) {
                inputSynthesizer.click(at: center, targetPid: targetPid)
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            inputSynthesizer.typeText(text, intervalMs: intervalMs, targetPid: targetPid)
            return ["ok": true, "typed": text, "field": fieldHint, "method": "ax", "target_pid": Int(targetPid)]
        }

        // Fallback: OCR detect + click + type
        let detectParams: [String: Any] = ["min_confidence": 0.5]
        let detected = try await detectElements(params: detectParams)
        if let elements = detected["elements"] as? [[String: Any]],
           let ocrMatch = elements.first(where: { ($0["text"] as? String ?? "").lowercased().contains(hint) }),
           let center = ocrMatch["center"] as? [String: Any],
           let cx = center["x"] as? Double, let cy = center["y"] as? Double {
            if let blocked = safetyGate(
                action: "type to field '\(fieldHint)' (OCR): \"\(text.prefix(50))\"",
                targetApp: resolveTargetAppName(params: params),
                characteristics: characteristics
            ) { return blocked }
            inputSynthesizer.click(at: CGPoint(x: cx, y: cy), targetPid: targetPid)
            try await Task.sleep(nanoseconds: 150_000_000)
            inputSynthesizer.typeText(text, intervalMs: intervalMs, targetPid: targetPid)
            return ["ok": true, "typed": text, "field": fieldHint, "method": "ocr_fallback", "target_pid": Int(targetPid)]
        }

        return ["ok": false, "error": "Field '\(fieldHint)' not found via AX or OCR. Use 'sr input click <x> <y>' with coordinates from 'sr detect --json'."]
    }

    // MARK: - App Control

    private func launchApp(params: [String: Any]?) throws -> [String: Any] {
        guard let name = params?["name"] as? String else {
            throw AgentError.invalidParams("Missing 'name' parameter (app name or bundle identifier)")
        }
        let activate = params?["activate"] as? Bool ?? false
        if activate,
           let blocked = safetyGate(
               action: "launch and activate app '\(name)'",
               targetApp: name,
               characteristics: [.changesFocus]
           ) {
            return blocked
        }
        guard InputSynthesizer.launchApp(named: name, activate: activate) else {
            return ["ok": false, "error": "Could not launch app: \(name)"]
        }
        let focused = activate ? waitForFocus(appName: name, timeoutMs: 3000) : false
        return ["ok": true, "launched": name, "focused": focused, "activated": activate]
    }

    private func activateApp(params: [String: Any]?) throws -> [String: Any] {
        guard let name = params?["name"] as? String else {
            throw AgentError.invalidParams("Missing 'name' parameter")
        }
        if let blocked = safetyGate(
            action: "activate app '\(name)'",
            targetApp: name,
            characteristics: [.changesFocus]
        ) { return blocked }
        guard InputSynthesizer.activateApp(named: name) else {
            return ["ok": false, "error": "Could not activate app: \(name). Is it running?"]
        }
        // Wait for app to become frontmost (up to 2s)
        let focused = waitForFocus(appName: name, timeoutMs: 2000)
        return ["ok": true, "activated": name, "focused": focused]
    }

    /// Poll until the named app is frontmost or timeout expires.
    /// Returns true if focus was confirmed, false if timed out.
    private func waitForFocus(appName: String, timeoutMs: Int) -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            let frontName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            if frontName.localizedCaseInsensitiveContains(appName) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private func listApps() -> [String: Any] {
        let apps = InputSynthesizer.listRunningApps()
        return ["apps": apps, "count": apps.count]
    }

    // MARK: - Browser Automation

    private func browserStatus(params: [String: Any]?) async throws -> [String: Any] {
        try await BrowserAutomationManager.shared.status(params: params)
    }

    private func browserLaunch(params: [String: Any]?) async throws -> [String: Any] {
        try await BrowserAutomationManager.shared.launch(params: params)
    }

    private func browserLaunchAndOpen(params: [String: Any]?) async throws -> [String: Any] {
        try await BrowserAutomationManager.shared.launchAndOpen(params: params)
    }

    private func browserTabs(params: [String: Any]?) async throws -> [String: Any] {
        try await BrowserAutomationManager.shared.listTabs(params: params)
    }

    private func browserOpenTab(params: [String: Any]?) async throws -> [String: Any] {
        try await BrowserAutomationManager.shared.openTab(params: params)
    }

    private func browserActivateTab(params: [String: Any]?) async throws -> [String: Any] {
        try await BrowserAutomationManager.shared.activateTab(params: params)
    }

    private func browserNavigate(params: [String: Any]?) async throws -> [String: Any] {
        try await BrowserAutomationManager.shared.navigate(params: params)
    }

    private func browserEval(params: [String: Any]?) async throws -> [String: Any] {
        try await BrowserAutomationManager.shared.evaluate(params: params)
    }

    private func browserClick(params: [String: Any]?) async throws -> [String: Any] {
        try await BrowserAutomationManager.shared.click(params: params)
    }

    private func browserType(params: [String: Any]?) async throws -> [String: Any] {
        try await BrowserAutomationManager.shared.type(params: params)
    }

    private func browserPressKey(params: [String: Any]?) async throws -> [String: Any] {
        try await BrowserAutomationManager.shared.pressKey(params: params)
    }

    private func browserScreenshot(params: [String: Any]?) async throws -> [String: Any] {
        try await BrowserAutomationManager.shared.screenshot(params: params)
    }

    // MARK: - Shell Command Execution

    private func execShellCommand(params: [String: Any]?) throws -> [String: Any] {
        guard let command = params?["command"] as? String else {
            throw AgentError.invalidParams("Missing 'command' parameter")
        }
        let timeout = params?["timeout"] as? Double ?? 30
        return InputSynthesizer.runShellCommand(command, timeout: timeout)
    }

    // MARK: - Accessibility Permission

    private func checkAccessibility() -> [String: Any] {
        let granted = InputSynthesizer.checkAccessibilityPermission()
        if !granted {
            // Trigger the permission prompt
            InputSynthesizer.requestAccessibilityPermission()
        }
        return [
            "granted": granted,
            "message": granted
                ? "Accessibility permission is granted. Computer control is available."
                : "Accessibility permission not granted. A system dialog should have appeared. Please grant access in System Settings → Privacy & Security → Accessibility, then restart the app.",
        ]
    }

    // MARK: - Accessibility Tree (AXUIElement)

    /// Resolve the root AXUIElement from params (app name, bundle_id, or pid).
    /// Falls back to the focused application.
    private func resolveAXRoot(params: [String: Any]?) -> AXUIElement? {
        if let appName = params?["app"] as? String {
            return AccessibilityBridge.appElement(named: appName)
        } else if let bundleId = params?["bundle_id"] as? String {
            return AccessibilityBridge.appElement(bundleId: bundleId)
        } else if let pid = params?["pid"] as? Int {
            return AccessibilityBridge.appElement(pid: pid_t(pid))
        } else {
            return AccessibilityBridge.focusedApplication()
        }
    }

    private func hasExplicitAXTarget(params: [String: Any]?) -> Bool {
        if let app = params?["app"] as? String, !app.isEmpty {
            return true
        }
        if let bundleId = params?["bundle_id"] as? String, !bundleId.isEmpty {
            return true
        }
        if params?["pid"] != nil {
            return true
        }
        return false
    }

    private func axGetTree(params: [String: Any]?) -> [String: Any] {
        guard InputSynthesizer.checkAccessibilityPermission() else {
            return ["ok": false, "error": "Accessibility permission not granted"]
        }
        guard let root = resolveAXRoot(params: params) else {
            return ["ok": false, "error": "Could not find the target application"]
        }

        let maxDepth = params?["max_depth"] as? Int ?? 3
        let tree = AccessibilityBridge.serialize(root, includeChildren: true, maxDepth: maxDepth)
        return ["ok": true, "tree": tree]
    }

    private func axFindElements(params: [String: Any]?) -> [String: Any] {
        guard InputSynthesizer.checkAccessibilityPermission() else {
            return ["ok": false, "error": "Accessibility permission not granted"]
        }
        guard let root = resolveAXRoot(params: params) else {
            return ["ok": false, "error": "Could not find the target application"]
        }

        // Search by title or role
        if let title = params?["title"] as? String {
            if let element = AccessibilityBridge.findElement(in: root, withTitle: title) {
                let serialized = AccessibilityBridge.serialize(element)
                return ["ok": true, "found": true, "element": serialized]
            }
            return ["ok": true, "found": false, "error": "Element with title '\(title)' not found"]
        }

        if let role = params?["role"] as? String {
            let maxResults = params?["max_results"] as? Int ?? 50
            let elements = AccessibilityBridge.findElements(in: root, role: role, maxResults: maxResults)
            let serialized = elements.map { AccessibilityBridge.serialize($0) }
            return ["ok": true, "elements": serialized, "count": serialized.count]
        }

        return ["ok": false, "error": "Provide 'title' or 'role' to search for"]
    }

    private func axPressElement(params: [String: Any]?) -> [String: Any] {
        guard InputSynthesizer.checkAccessibilityPermission() else {
            return ["ok": false, "error": "Accessibility permission not granted"]
        }
        let explicitTarget = hasExplicitAXTarget(params: params)
        let characteristics: Set<SafetyGuard.ActionCharacteristic> = explicitTarget ? [] : [.usesFrontmostInput]
        guard let root = resolveAXRoot(params: params) else {
            return ["ok": false, "error": "Could not find the target application"]
        }
        guard let title = params?["title"] as? String else {
            return ["ok": false, "error": "Missing 'title' parameter — the element to press"]
        }
        if let blocked = safetyGate(
            action: "AX press '\(title)'",
            targetApp: resolveTargetAppName(params: params),
            characteristics: characteristics
        ) { return blocked }

        guard let element = AccessibilityBridge.findElement(in: root, withTitle: title) else {
            return ["ok": false, "error": "Element '\(title)' not found"]
        }

        let action = params?["action"] as? String ?? kAXPressAction as String
        let success = AccessibilityBridge.performAction(action, on: element)
        return ["ok": success, "pressed": title, "action": action]
    }

    private func axSetValue(params: [String: Any]?) -> [String: Any] {
        guard InputSynthesizer.checkAccessibilityPermission() else {
            return ["ok": false, "error": "Accessibility permission not granted"]
        }
        let explicitTarget = hasExplicitAXTarget(params: params)
        let characteristics: Set<SafetyGuard.ActionCharacteristic> = explicitTarget ? [] : [.usesFrontmostInput]
        guard let root = resolveAXRoot(params: params) else {
            return ["ok": false, "error": "Could not find the target application"]
        }
        guard let title = params?["title"] as? String else {
            return ["ok": false, "error": "Missing 'title' parameter — the element to set value on"]
        }
        guard let value = params?["value"] as? String else {
            return ["ok": false, "error": "Missing 'value' parameter"]
        }
        if let blocked = safetyGate(
            action: "AX set value '\(title)'",
            targetApp: resolveTargetAppName(params: params),
            characteristics: characteristics
        ) { return blocked }

        guard let element = AccessibilityBridge.findElement(in: root, withTitle: title) else {
            return ["ok": false, "error": "Element '\(title)' not found"]
        }

        let success = AccessibilityBridge.setValue(value, on: element)
        return ["ok": success, "element": title, "value": value]
    }

    private func axFocusedElement() -> [String: Any] {
        guard InputSynthesizer.checkAccessibilityPermission() else {
            return ["ok": false, "error": "Accessibility permission not granted"]
        }
        guard let element = AccessibilityBridge.focusedElement() else {
            return ["ok": false, "error": "No focused element found"]
        }
        let serialized = AccessibilityBridge.serialize(element)
        return ["ok": true, "element": serialized]
    }

    private func axActionableElements(params: [String: Any]?) -> [String: Any] {
        guard InputSynthesizer.checkAccessibilityPermission() else {
            return ["ok": false, "error": "Accessibility permission not granted"]
        }
        guard let root = resolveAXRoot(params: params) else {
            return ["ok": false, "error": "Could not find the target application"]
        }

        let maxDepth = params?["max_depth"] as? Int ?? 10
        let maxResults = params?["max_results"] as? Int ?? 100
        let elements = AccessibilityBridge.serializeActionableElements(of: root, maxDepth: maxDepth, maxResults: maxResults)
        return ["ok": true, "elements": elements, "count": elements.count]
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

    // MARK: - Agent Control Lock

    private func lockForAgent(params: [String: Any]?) -> [String: Any] {
        let unlockKey = params?["unlock_key"] as? String
        AgentControlLock.shared.lock(unlockKey: unlockKey)
        return AgentControlLock.shared.status()
    }

    private func unlockForUser() -> [String: Any] {
        AgentControlLock.shared.unlock()
        return AgentControlLock.shared.status()
    }

    // MARK: - App Lifecycle Extras

    private func quitApp(params: [String: Any]?) throws -> [String: Any] {
        guard let name = params?["name"] as? String else {
            throw AgentError.invalidParams("Missing 'name' parameter")
        }
        if let blocked = safetyGate(
            action: "quit app '\(name)'",
            targetApp: name,
            characteristics: [.disruptsApps]
        ) { return blocked }
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.localizedName?.localizedCaseInsensitiveContains(name) ?? false ||
            ($0.bundleIdentifier?.localizedCaseInsensitiveContains(name) ?? false)
        }
        guard !apps.isEmpty else {
            return ["ok": false, "error": "No running app found: \(name)"]
        }
        let force = params?["force"] as? Bool ?? false
        for app in apps {
            if force {
                app.forceTerminate()
            } else {
                app.terminate()
            }
        }
        return ["ok": true, "terminated": apps.compactMap { $0.localizedName }]
    }

    private func relaunchApp(params: [String: Any]?) throws -> [String: Any] {
        guard let name = params?["name"] as? String else {
            throw AgentError.invalidParams("Missing 'name' parameter")
        }
        if let blocked = safetyGate(
            action: "relaunch app '\(name)'",
            targetApp: name,
            characteristics: [.disruptsApps]
        ) { return blocked }
        // Quit then relaunch
        _ = try? quitApp(params: params)
        Thread.sleep(forTimeInterval: 1.0)
        let launched = InputSynthesizer.launchApp(named: name)
        return ["ok": launched, "action": "relaunch", "app": name]
    }

    private func hideApp(params: [String: Any]?) throws -> [String: Any] {
        guard let name = params?["name"] as? String else {
            throw AgentError.invalidParams("Missing 'name' parameter")
        }
        if let blocked = safetyGate(
            action: "hide app '\(name)'",
            targetApp: name,
            characteristics: [.disruptsApps]
        ) { return blocked }
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.localizedName?.localizedCaseInsensitiveContains(name) ?? false
        }
        guard let app = apps.first else {
            return ["ok": false, "error": "No running app found: \(name)"]
        }
        app.hide()
        return ["ok": true, "hidden": app.localizedName ?? name]
    }

    // MARK: - Window Manipulation (via AXUIElement)

    private func moveWindow(params: [String: Any]?) throws -> [String: Any] {
        guard let x = params?["x"] as? Double, let y = params?["y"] as? Double else {
            throw AgentError.invalidParams("Missing 'x' and 'y' parameters")
        }
        if let blocked = safetyGate(
            action: "move window to (\(Int(x)), \(Int(y)))",
            targetApp: resolveTargetAppName(params: params),
            characteristics: [.mutatesWindows]
        ) { return blocked }
        let axApp = try targetAXApp(params: params)
        guard let window = firstWindow(of: axApp) else {
            return ["ok": false, "error": "No window found"]
        }
        var point = CGPoint(x: x, y: y)
        let value = AXValueCreate(.cgPoint, &point)!
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        return ["ok": true, "moved_to": ["x": x, "y": y]]
    }

    private func resizeWindow(params: [String: Any]?) throws -> [String: Any] {
        guard let w = params?["width"] as? Double, let h = params?["height"] as? Double else {
            throw AgentError.invalidParams("Missing 'width' and 'height' parameters")
        }
        if let blocked = safetyGate(
            action: "resize window to \(Int(w))×\(Int(h))",
            targetApp: resolveTargetAppName(params: params),
            characteristics: [.mutatesWindows]
        ) { return blocked }
        let axApp = try targetAXApp(params: params)
        guard let window = firstWindow(of: axApp) else {
            return ["ok": false, "error": "No window found"]
        }
        var size = CGSize(width: w, height: h)
        let value = AXValueCreate(.cgSize, &size)!
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        return ["ok": true, "resized_to": ["width": w, "height": h]]
    }

    private func minimizeWindow(params: [String: Any]?) throws -> [String: Any] {
        if let blocked = safetyGate(
            action: "minimize window",
            targetApp: resolveTargetAppName(params: params),
            characteristics: [.mutatesWindows]
        ) { return blocked }
        let axApp = try targetAXApp(params: params)
        guard let window = firstWindow(of: axApp) else {
            return ["ok": false, "error": "No window found"]
        }
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, true as CFTypeRef)
        return ["ok": true]
    }

    private func restoreWindow(params: [String: Any]?) throws -> [String: Any] {
        if let blocked = safetyGate(
            action: "restore window",
            targetApp: resolveTargetAppName(params: params),
            characteristics: [.mutatesWindows]
        ) { return blocked }
        let axApp = try targetAXApp(params: params)
        guard let window = firstWindow(of: axApp) else {
            return ["ok": false, "error": "No window found"]
        }
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        return ["ok": true]
    }

    /// Resolve an AXUIElement for a running app from params containing "app" or "pid".
    private func targetAXApp(params: [String: Any]?) throws -> AXUIElement {
        if let pid = params?["pid"] as? Int32 {
            return AXUIElementCreateApplication(pid)
        }
        if let name = params?["app"] as? String {
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName?.localizedCaseInsensitiveContains(name) ?? false
            }) else {
                throw AgentError.invalidParams("No running app: \(name)")
            }
            return AXUIElementCreateApplication(app.processIdentifier)
        }
        // Default: frontmost app
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw AgentError.invalidParams("No frontmost app")
        }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    private func firstWindow(of axApp: AXUIElement) -> AXUIElement? {
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let first = windows.first
        else { return nil }
        return first
    }

    // MARK: - Sleep

    private func sleepMs(params: [String: Any]?) throws -> [String: Any] {
        let ms = params?["ms"] as? Int ?? params?["duration"] as? Int ?? 500
        usleep(UInt32(ms) * 1000)
        return ["ok": true, "slept_ms": ms]
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
