import AppKit
import CoreGraphics
import Carbon.HIToolbox

/// Synthesizes mouse and keyboard input events using the CGEvent API.
/// Requires macOS Accessibility permission (System Preferences → Security & Privacy → Accessibility).
///
/// This is the counterpart to `MouseMonitor` and `KeystrokeMonitor` which *observe* input;
/// `InputSynthesizer` *generates* input, enabling AI agents to control the computer.
class InputSynthesizer {
    /// Shared source for all synthesized events (can be nil — system default source)
    private let eventSource: CGEventSource?

    init() {
        // .hidSystemState creates events that look like real HID events
        self.eventSource = CGEventSource(stateID: .hidSystemState)
    }

    // MARK: - Permission Check

    /// Check whether Accessibility permission has been granted.
    /// CGEvent.post() requires this, otherwise events are silently dropped.
    static func checkAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Prompt the system Accessibility permission dialog.
    /// The dialog only shows once; subsequent calls open System Preferences.
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Mouse: Move

    /// Move the cursor to specified screen coordinates without clicking.
    func moveMouse(to point: CGPoint) {
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Mouse: Click

    /// Perform a left-click at screen coordinates.
    /// - Parameters:
    ///   - point: Screen coordinates (top-left origin, points)
    ///   - clickCount: 1 = single, 2 = double, 3 = triple
    func click(at point: CGPoint, clickCount: Int = 1) {
        postClick(at: point, button: .left, downType: .leftMouseDown, upType: .leftMouseUp, clickCount: clickCount)
    }

    /// Perform a right-click at screen coordinates.
    func rightClick(at point: CGPoint) {
        postClick(at: point, button: .right, downType: .rightMouseDown, upType: .rightMouseUp, clickCount: 1)
    }

    /// Perform a double-click at screen coordinates.
    func doubleClick(at point: CGPoint) {
        click(at: point, clickCount: 2)
    }

    /// Perform a middle-click at screen coordinates.
    func middleClick(at point: CGPoint) {
        postClick(at: point, button: .center, downType: .otherMouseDown, upType: .otherMouseUp, clickCount: 1)
    }

    private func postClick(
        at point: CGPoint,
        button: CGMouseButton,
        downType: CGEventType,
        upType: CGEventType,
        clickCount: Int
    ) {
        // For multi-click, send the sequence (down/up) with incrementing click counts
        for i in 1...clickCount {
            guard let down = CGEvent(mouseEventSource: eventSource, mouseType: downType, mouseCursorPosition: point, mouseButton: button),
                  let up = CGEvent(mouseEventSource: eventSource, mouseType: upType, mouseCursorPosition: point, mouseButton: button)
            else { continue }

            down.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(i))

            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)

            // Brief pause between clicks in a multi-click sequence
            if i < clickCount {
                usleep(50_000) // 50ms
            }
        }
    }

    // MARK: - Mouse: Click with Modifiers

    /// Click with modifier keys held (e.g., ⌘+Click, ⌥+Click).
    func click(at point: CGPoint, modifiers: CGEventFlags, clickCount: Int = 1) {
        for i in 1...clickCount {
            guard let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
                  let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
            else { continue }

            down.flags = modifiers
            up.flags = modifiers
            down.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(i))

            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)

            if i < clickCount {
                usleep(50_000)
            }
        }
    }

    // MARK: - Mouse: Drag

    /// Drag from one point to another over a specified duration.
    /// - Parameters:
    ///   - from: Starting screen coordinates
    ///   - to: Ending screen coordinates
    ///   - duration: How long the drag takes (seconds). Default 0.5s.
    ///   - steps: Number of intermediate points for smooth movement.
    func drag(from: CGPoint, to: CGPoint, duration: TimeInterval = 0.5, steps: Int = 20) {
        // Mouse down at start
        guard let downEvent = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left) else { return }
        downEvent.post(tap: .cghidEventTap)

        let stepDelay = UInt32(duration / Double(steps) * 1_000_000) // microseconds

        // Interpolate movement
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = from.x + (to.x - from.x) * t
            let y = from.y + (to.y - from.y) * t
            let current = CGPoint(x: x, y: y)

            guard let dragEvent = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged, mouseCursorPosition: current, mouseButton: .left) else { continue }
            dragEvent.post(tap: .cghidEventTap)
            usleep(stepDelay)
        }

        // Mouse up at end
        guard let upEvent = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left) else { return }
        upEvent.post(tap: .cghidEventTap)
    }

    // MARK: - Mouse: Scroll

    /// Scroll at a screen position.
    /// - Parameters:
    ///   - at: Screen coordinates where the scroll happens
    ///   - deltaX: Horizontal scroll amount (positive = right, negative = left)
    ///   - deltaY: Vertical scroll amount (positive = up, negative = down)
    func scroll(at point: CGPoint, deltaX: Int32 = 0, deltaY: Int32) {
        // Move cursor to position first
        moveMouse(to: point)
        usleep(20_000) // 20ms settle

        guard let event = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard: Key Press

    /// Press and release a single key.
    /// - Parameters:
    ///   - keyCode: Virtual key code (see Carbon HIToolbox kVK_* constants)
    ///   - modifiers: Optional modifier flags (⌘, ⇧, ⌥, ⌃)
    func pressKey(keyCode: UInt16, modifiers: CGEventFlags = []) {
        guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: false)
        else { return }

        if !modifiers.isEmpty {
            down.flags = modifiers
            up.flags = modifiers
        }

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Execute a keyboard shortcut (e.g., ⌘+C, ⌘+⇧+4).
    func hotkey(modifiers: CGEventFlags, keyCode: UInt16) {
        pressKey(keyCode: keyCode, modifiers: modifiers)
    }

    // MARK: - Keyboard: Type Text

    /// Type a string of text character by character.
    /// Uses the Unicode input method to handle any character, not just ASCII.
    /// - Parameters:
    ///   - text: The text to type
    ///   - intervalMs: Delay between characters in milliseconds (default 50ms)
    func typeText(_ text: String, intervalMs: Int = 50) {
        for char in text {
            typeCharacter(char)
            usleep(UInt32(intervalMs) * 1000)
        }
    }

    /// Type a single character using CGEvent's Unicode input.
    private func typeCharacter(_ char: Character) {
        let utf16 = Array(String(char).utf16)

        guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false)
        else { return }

        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard: Named Key Helpers

    /// Press a named key (user-friendly names like "return", "tab", "escape", "space", etc.)
    /// Returns true if the key name was recognized.
    @discardableResult
    func pressNamedKey(_ name: String, modifiers: CGEventFlags = []) -> Bool {
        guard let keyCode = Self.keyCodeForName(name) else { return false }
        pressKey(keyCode: keyCode, modifiers: modifiers)
        return true
    }

    /// Parse a hotkey string like "cmd+shift+4" or "ctrl+c" into flags + keyCode.
    /// Returns nil if parsing fails.
    func parseAndExecuteHotkey(_ hotkeyString: String) -> Bool {
        let parts = hotkeyString.lowercased().split(separator: "+").map(String.init)
        guard !parts.isEmpty else { return false }

        var flags: CGEventFlags = []
        var keyPart: String?

        for part in parts {
            switch part {
            case "cmd", "command", "⌘":
                flags.insert(.maskCommand)
            case "shift", "⇧":
                flags.insert(.maskShift)
            case "alt", "opt", "option", "⌥":
                flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃":
                flags.insert(.maskControl)
            default:
                keyPart = part
            }
        }

        guard let key = keyPart else { return false }

        // Try named key first, then single character
        if let keyCode = Self.keyCodeForName(key) {
            pressKey(keyCode: keyCode, modifiers: flags)
            return true
        } else if key.count == 1, let char = key.first {
            // Map single ASCII character to key code
            if let keyCode = Self.keyCodeForCharacter(char) {
                pressKey(keyCode: keyCode, modifiers: flags)
                return true
            }
        }

        return false
    }

    // MARK: - App Control

    /// Launch an application by name or bundle identifier.
    /// - Returns: true if launch was initiated
    @discardableResult
    static func launchApp(named name: String) -> Bool {
        // Try as bundle identifier first
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
            return true
        }

        // Try as app name via path
        if let path = NSWorkspace.shared.fullPath(forApplication: name) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return true
        }

        return false
    }

    /// Bring an application to the foreground.
    /// - Returns: true if the app was found and activated
    @discardableResult
    static func activateApp(named name: String) -> Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: name)
        if let app = apps.first {
            return app.activate()
        }

        // Try by localized name
        let workspace = NSWorkspace.shared
        guard let app = workspace.runningApplications.first(where: {
            $0.localizedName?.localizedCaseInsensitiveContains(name) ?? false
        }) else { return false }

        return app.activate()
    }

    /// List running applications.
    static func listRunningApps() -> [[String: Any]] {
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> [String: Any]? in
                guard let name = app.localizedName else { return nil }
                return [
                    "name": name,
                    "bundle_id": app.bundleIdentifier ?? "",
                    "pid": app.processIdentifier,
                    "is_active": app.isActive,
                ]
            }
    }

    // MARK: - Shell Command Execution

    /// Run a shell command and return its output.
    /// - Parameters:
    ///   - command: Shell command string (executed via /bin/zsh -c)
    ///   - timeout: Maximum execution time in seconds (default 30)
    /// - Returns: Dictionary with stdout, stderr, exit code
    static func runShellCommand(_ command: String, timeout: TimeInterval = 30) -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()

            // Wait with timeout
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }

            if process.isRunning {
                process.terminate()
                return [
                    "ok": false,
                    "error": "Command timed out after \(Int(timeout))s",
                    "exit_code": -1,
                ]
            }

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            return [
                "ok": process.terminationStatus == 0,
                "stdout": stdout,
                "stderr": stderr,
                "exit_code": Int(process.terminationStatus),
            ]
        } catch {
            return [
                "ok": false,
                "error": error.localizedDescription,
                "exit_code": -1,
            ]
        }
    }

    // MARK: - Key Code Mapping

    /// Map user-friendly key names to virtual key codes.
    static func keyCodeForName(_ name: String) -> UInt16? {
        switch name.lowercased() {
        case "return", "enter", "↩":       return UInt16(kVK_Return)
        case "tab", "⇥":                   return UInt16(kVK_Tab)
        case "space":                       return UInt16(kVK_Space)
        case "delete", "backspace", "⌫":   return UInt16(kVK_Delete)
        case "forwarddelete", "⌦":         return UInt16(kVK_ForwardDelete)
        case "escape", "esc", "⎋":         return UInt16(kVK_Escape)
        case "up", "↑":                    return UInt16(kVK_UpArrow)
        case "down", "↓":                  return UInt16(kVK_DownArrow)
        case "left", "←":                  return UInt16(kVK_LeftArrow)
        case "right", "→":                 return UInt16(kVK_RightArrow)
        case "home", "↖":                  return UInt16(kVK_Home)
        case "end", "↘":                   return UInt16(kVK_End)
        case "pageup", "⇞":               return UInt16(kVK_PageUp)
        case "pagedown", "⇟":             return UInt16(kVK_PageDown)
        case "f1":  return UInt16(kVK_F1)
        case "f2":  return UInt16(kVK_F2)
        case "f3":  return UInt16(kVK_F3)
        case "f4":  return UInt16(kVK_F4)
        case "f5":  return UInt16(kVK_F5)
        case "f6":  return UInt16(kVK_F6)
        case "f7":  return UInt16(kVK_F7)
        case "f8":  return UInt16(kVK_F8)
        case "f9":  return UInt16(kVK_F9)
        case "f10": return UInt16(kVK_F10)
        case "f11": return UInt16(kVK_F11)
        case "f12": return UInt16(kVK_F12)
        default:    return nil
        }
    }

    /// Map a single ASCII character to a virtual key code.
    static func keyCodeForCharacter(_ char: Character) -> UInt16? {
        switch char.lowercased().first {
        case "a": return UInt16(kVK_ANSI_A)
        case "b": return UInt16(kVK_ANSI_B)
        case "c": return UInt16(kVK_ANSI_C)
        case "d": return UInt16(kVK_ANSI_D)
        case "e": return UInt16(kVK_ANSI_E)
        case "f": return UInt16(kVK_ANSI_F)
        case "g": return UInt16(kVK_ANSI_G)
        case "h": return UInt16(kVK_ANSI_H)
        case "i": return UInt16(kVK_ANSI_I)
        case "j": return UInt16(kVK_ANSI_J)
        case "k": return UInt16(kVK_ANSI_K)
        case "l": return UInt16(kVK_ANSI_L)
        case "m": return UInt16(kVK_ANSI_M)
        case "n": return UInt16(kVK_ANSI_N)
        case "o": return UInt16(kVK_ANSI_O)
        case "p": return UInt16(kVK_ANSI_P)
        case "q": return UInt16(kVK_ANSI_Q)
        case "r": return UInt16(kVK_ANSI_R)
        case "s": return UInt16(kVK_ANSI_S)
        case "t": return UInt16(kVK_ANSI_T)
        case "u": return UInt16(kVK_ANSI_U)
        case "v": return UInt16(kVK_ANSI_V)
        case "w": return UInt16(kVK_ANSI_W)
        case "x": return UInt16(kVK_ANSI_X)
        case "y": return UInt16(kVK_ANSI_Y)
        case "z": return UInt16(kVK_ANSI_Z)
        case "0": return UInt16(kVK_ANSI_0)
        case "1": return UInt16(kVK_ANSI_1)
        case "2": return UInt16(kVK_ANSI_2)
        case "3": return UInt16(kVK_ANSI_3)
        case "4": return UInt16(kVK_ANSI_4)
        case "5": return UInt16(kVK_ANSI_5)
        case "6": return UInt16(kVK_ANSI_6)
        case "7": return UInt16(kVK_ANSI_7)
        case "8": return UInt16(kVK_ANSI_8)
        case "9": return UInt16(kVK_ANSI_9)
        case "-": return UInt16(kVK_ANSI_Minus)
        case "=": return UInt16(kVK_ANSI_Equal)
        case "[": return UInt16(kVK_ANSI_LeftBracket)
        case "]": return UInt16(kVK_ANSI_RightBracket)
        case "\\": return UInt16(kVK_ANSI_Backslash)
        case ";": return UInt16(kVK_ANSI_Semicolon)
        case "'": return UInt16(kVK_ANSI_Quote)
        case ",": return UInt16(kVK_ANSI_Comma)
        case ".": return UInt16(kVK_ANSI_Period)
        case "/": return UInt16(kVK_ANSI_Slash)
        case "`": return UInt16(kVK_ANSI_Grave)
        default:  return nil
        }
    }
}
