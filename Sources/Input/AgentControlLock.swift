import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Locks user input (mouse + keyboard) while an AI agent is controlling the computer.
///
/// How it works:
/// - Installs a `CGEventTap` at the **HID** level, the lowest possible interception point.
/// - While locked, all user mouse and keyboard events are swallowed before reaching any app.
/// - Agent-synthesized events posted via `CGEventPost(.cghidEventTap)` in `InputSynthesizer`
///   bypass this tap entirely — they are posted *into* the stream, not intercepted by it.
/// - The unlock combo (default ⌘⇧F12) is always checked before swallowing, so the user can
///   always escape even if the agent crashes.
///
/// Requires: Accessibility permission (`AXIsProcessTrusted()` must return true).
final class AgentControlLock {

    // MARK: - Singleton

    static let shared = AgentControlLock()

    // MARK: - State

    private(set) var isLocked: Bool = false

    /// The hotkey string the user presses to reclaim control. Default: cmd+shift+f12.
    var unlockKey: String {
        get { UserDefaults.standard.string(forKey: "agentControlLockUnlockKey") ?? "cmd+shift+f12" }
        set { UserDefaults.standard.set(newValue, forKey: "agentControlLockUnlockKey") }
    }

    /// Parsed unlock key cached at lock-time (avoids repeated parsing in the tap callback).
    private var unlockKeyCode: UInt16 = UInt16(kVK_F12)
    private var unlockModifiers: CGEventFlags = [.maskCommand, .maskShift]

    // MARK: - Event Tap

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var tapThread: Thread?
    private let stateLock = NSLock()

    /// Overlay window shown while locked.
    private var overlayWindow: ControlOverlayWindow?

    // MARK: - Init

    private init() {}

    // MARK: - Public API

    /// Lock user input and show the overlay.
    /// - Parameter unlockKey: Optional override for unlock combo (e.g. "cmd+shift+f12").
    func lock(unlockKey: String? = nil) {
        stateLock.lock()
        let alreadyLocked = isLocked
        stateLock.unlock()
        guard !alreadyLocked else { return }

        if let key = unlockKey {
            self.unlockKey = key
        }

        // Parse the unlock combo once so the tap callback doesn't have to
        parseUnlockKey(self.unlockKey)

        // Install the event tap on a dedicated background thread
        installEventTap()

        stateLock.lock()
        isLocked = true
        stateLock.unlock()

        showOverlay()

        NSLog("[AgentControlLock] 🔒 User input locked. Unlock: \(self.unlockKey)")
    }

    /// Unlock user input and dismiss the overlay.
    func unlock() {
        stateLock.lock()
        let wasLocked = isLocked
        stateLock.unlock()
        guard wasLocked else { return }

        removeEventTap()
        stateLock.lock()
        isLocked = false
        stateLock.unlock()

        hideOverlay()

        NSLog("[AgentControlLock] 🔓 User input unlocked")
    }

    /// Current status dictionary (for RPC/MCP responses).
    func status() -> [String: Any] {
        stateLock.lock()
        let locked = isLocked
        stateLock.unlock()
        return [
            "locked": locked,
            "unlock_key": unlockKey,
        ]
    }

    // MARK: - Event Tap Install / Remove

    private func installEventTap() {
        // We need to install the tap on a thread that has its own run loop.
        // Otherwise the tap callback will never fire.
        let thread = Thread {
            self.runTapOnThread()
        }
        thread.name = "AgentControlLock.EventTap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
    }

    /// Runs on a dedicated background thread with its own run loop so the event tap stays alive.
    private func runTapOnThread() {
        // Build the event mask in sub-expressions so the type-checker doesn't time out.
        let keyboardMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        let mouseMask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)
        let motionMask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)
        let eventMask: CGEventMask = keyboardMask | mouseMask | motionMask

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,          // HID level — before window server routes events
            place: .headInsertEventTap,    // Before all other taps
            options: .defaultTap,          // Can filter (return nil to swallow)
            eventsOfInterest: eventMask,
            callback: AgentControlLock.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("[AgentControlLock] ⚠️ Failed to create event tap — check Accessibility permission")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let runLoop = CFRunLoopGetCurrent()

        stateLock.lock()
        self.eventTap = tap
        self.runLoopSource = source
        self.tapRunLoop = runLoop
        stateLock.unlock()

        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Run until stopped
        CFRunLoopRun()
    }

    private func removeEventTap() {
        stateLock.lock()
        let tap = eventTap
        let source = runLoopSource
        let runLoop = tapRunLoop
        let thread = tapThread
        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
        stateLock.unlock()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source, let runLoop {
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
                CFRunLoopStop(runLoop)
            }
            thread?.cancel()
        }
    }

    // MARK: - Tap Callback (C-compatible)

    /// CGEventTap callback. Called for every intercepted event.
    /// Returns nil to swallow the event, or the event unchanged to pass it through.
    private static let tapCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let lock = Unmanaged<AgentControlLock>.fromOpaque(userInfo).takeUnretainedValue()
        return lock.handleEvent(proxy: proxy, type: type, event: event)
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Tap disabled or re-enabled by system — re-enable it
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stateLock.lock()
            let tap = eventTap
            stateLock.unlock()
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Always check for the unlock combo before deciding to swallow
        if isUnlockCombo(event: event, type: type) {
            // Dispatch unlock to the main thread
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.unlock()
            }
            return nil // Swallow the unlock key itself (don't let it reach apps)
        }

        // Also honour the existing SafetyGuard kill switch (⌘⌥⎋)
        if isKillSwitchCombo(event: event, type: type) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                SafetyGuard.shared.toggleKillSwitch()
                self.unlock() // kill switch also unlocks
            }
            return nil
        }

        // Swallow all user input while locked
        return nil
    }

    // MARK: - Unlock / Kill-Switch Detection

    private func isUnlockCombo(event: CGEvent, type: CGEventType) -> Bool {
        guard type == .keyDown else { return false }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        return keyCode == unlockKeyCode && flags == unlockModifiers
    }

    private func isKillSwitchCombo(event: CGEvent, type: CGEventType) -> Bool {
        guard type == .keyDown else { return false }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        // SafetyGuard kill switch: ⌘⌥⎋
        return keyCode == UInt16(kVK_Escape) && flags == [.maskCommand, .maskAlternate]
    }

    // MARK: - Unlock Key Parsing

    private func parseUnlockKey(_ key: String) {
        let parts = key.lowercased().split(separator: "+").map(String.init)
        var flags: CGEventFlags = []
        var keyPart: String?

        for part in parts {
            switch part {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift":          flags.insert(.maskShift)
            case "alt", "opt", "option": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default:               keyPart = part
            }
        }

        unlockModifiers = flags

        if let k = keyPart {
            if let code = InputSynthesizer.keyCodeForName(k) {
                unlockKeyCode = code
            } else if k.count == 1, let char = k.first, let code = InputSynthesizer.keyCodeForCharacter(char) {
                unlockKeyCode = code
            }
        }
    }

    // MARK: - Overlay

    private func showOverlay() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.overlayWindow == nil {
                self.overlayWindow = ControlOverlayWindow(unlockKey: self.unlockKey)
            }
            self.overlayWindow?.showOverlay()
        }
    }

    private func hideOverlay() {
        DispatchQueue.main.async { [weak self] in
            self?.overlayWindow?.hideOverlay()
        }
    }
}
