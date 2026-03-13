import AppKit
import CoreGraphics
import Carbon.HIToolbox

/// Monitors global keyboard events using CGEvent tap.
/// Requires Accessibility permission in System Preferences.
class KeystrokeMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private(set) var isMonitoring = false

    var onKeystroke: ((KeystrokeEvent) -> Void)?

    // MARK: - Start Monitoring

    func startMonitoring() {
        guard !isMonitoring else { return }

        // Try NSEvent global monitor first (higher-level Cocoa API)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleNSEvent(event)
        }

        if globalMonitor != nil {
            isMonitoring = true
            print("✅ Keystroke monitoring active (NSEvent global monitor)")
            return
        }

        // Fallback: CGEvent tap
        print("⚠️ NSEvent monitor failed, trying CGEvent tap...")
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passRetained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let monitor = Unmanaged<KeystrokeMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handleCGEvent(type: type, event: event)
                return Unmanaged.passRetained(event)
            },
            userInfo: userInfo
        ) else {
            print("❌ CGEvent.tapCreate() also failed — Accessibility permission not granted")
            Unmanaged<KeystrokeMonitor>.fromOpaque(userInfo).release()
            return
        }

        print("✅ Keystroke monitoring active (CGEvent tap)")
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        isMonitoring = true
    }

    // MARK: - Stop Monitoring

    func stopMonitoring() {
        guard isMonitoring else { return }

        // Clean up NSEvent monitor
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }

        // Clean up CGEvent tap
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        isMonitoring = false
    }

    // MARK: - Handle NSEvent (preferred)

    private func handleNSEvent(_ event: NSEvent) {
        let keyCode = Int(event.keyCode)
        var modifiers: [ModifierKey] = []
        let flags = event.modifierFlags
        if flags.contains(.control) { modifiers.append(.control) }
        if flags.contains(.option) { modifiers.append(.option) }
        if flags.contains(.shift) { modifiers.append(.shift) }
        if flags.contains(.command) { modifiers.append(.command) }

        let isSpecial = Self.isSpecialKey(keyCode: keyCode)
        let keyString: String

        if isSpecial {
            // Special keys (backspace, return, tab, arrows, etc.) — use symbol
            keyString = Self.specialKeyName(keyCode: keyCode)
        } else if let chars = event.charactersIgnoringModifiers, !chars.isEmpty,
           let scalar = chars.unicodeScalars.first, scalar.value >= 32, scalar.value < 127 {
            // Printable ASCII characters
            keyString = chars.uppercased()
        } else {
            keyString = Self.specialKeyName(keyCode: keyCode)
        }

        let keystroke = KeystrokeEvent(
            keyString: keyString,
            modifiers: modifiers,
            isSpecialKey: isSpecial
        )

        DispatchQueue.main.async { [weak self] in
            self?.onKeystroke?(keystroke)
        }
    }

    // MARK: - Handle CGEvent (fallback)

    private func handleCGEvent(type: CGEventType, event: CGEvent) {
        guard type == .keyDown else { return }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Build modifier list
        var modifiers: [ModifierKey] = []
        if flags.contains(.maskControl) { modifiers.append(.control) }
        if flags.contains(.maskAlternate) { modifiers.append(.option) }
        if flags.contains(.maskShift) { modifiers.append(.shift) }
        if flags.contains(.maskCommand) { modifiers.append(.command) }

        let keyString = Self.keyCodeToString(keyCode: Int(keyCode), event: event)
        let isSpecial = Self.isSpecialKey(keyCode: Int(keyCode))

        let keystroke = KeystrokeEvent(
            keyString: keyString,
            modifiers: modifiers,
            isSpecialKey: isSpecial
        )

        DispatchQueue.main.async { [weak self] in
            self?.onKeystroke?(keystroke)
        }
    }

    // MARK: - Key Code Translation

    static func keyCodeToString(keyCode: Int, event: CGEvent) -> String {
        // Try to get the character from the event first
        if let chars = event.copy(), let nsEvent = NSEvent(cgEvent: chars) {
            if let characters = nsEvent.charactersIgnoringModifiers, !characters.isEmpty {
                let char = characters.uppercased()
                // Filter out non-printable characters
                if char.unicodeScalars.first?.value ?? 0 >= 32 {
                    return char
                }
            }
        }

        // Fallback to known key codes for special keys
        return specialKeyName(keyCode: keyCode)
    }

    static func isSpecialKey(keyCode: Int) -> Bool {
        return [36, 48, 49, 51, 53, 76, 115, 116, 117, 119, 121, 123, 124, 125, 126].contains(keyCode)
    }

    static func specialKeyName(keyCode: Int) -> String {
        switch keyCode {
        case 36: return "↩"     // Return
        case 48: return "⇥"     // Tab
        case 49: return "Space"  // Space
        case 51: return "⌫"     // Delete
        case 53: return "⎋"     // Escape
        case 76: return "↩"     // Enter (numpad)
        case 115: return "↖"    // Home
        case 116: return "⇞"    // Page Up
        case 117: return "⌦"    // Forward Delete
        case 119: return "↘"    // End
        case 121: return "⇟"    // Page Down
        case 123: return "←"    // Left Arrow
        case 124: return "→"    // Right Arrow
        case 125: return "↓"    // Down Arrow
        case 126: return "↑"    // Up Arrow
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default: return "?"
        }
    }

    deinit {
        stopMonitoring()
    }
}
