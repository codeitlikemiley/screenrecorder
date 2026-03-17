import Foundation
import Carbon.HIToolbox

/// Safety guard for AI-driven computer control actions.
/// Provides configurable safety boundaries to prevent unintended actions.
///
/// Safety features:
/// - **Kill switch**: Global hotkey (⌘⌥⎋) to instantly disable all input synthesis
/// - **Confirmation mode**: Require user approval before each action (via callback)
/// - **App allowlist**: Restrict actions to specific applications
/// - **Rate limiting**: Prevent runaway action loops
/// - **Action logging**: All actions are logged for audit
class SafetyGuard {
    /// Shared instance for app-wide safety enforcement.
    static let shared = SafetyGuard()

    /// Whether computer control is currently enabled.
    /// Toggled by the kill switch hotkey.
    private(set) var isEnabled: Bool = true

    /// When true, every action requires confirmation before execution.
    var confirmationMode: Bool = false

    /// Optional callback for confirmation mode.
    /// Called with an action description; returns true if the action should proceed.
    var confirmationHandler: ((String) -> Bool)?

    /// If non-empty, only actions targeting these apps/bundle IDs are allowed.
    var appAllowlist: Set<String> = []

    /// Maximum actions per second (0 = unlimited).
    var maxActionsPerSecond: Int = 10

    /// Recent action timestamps for rate limiting.
    private var actionTimestamps: [Date] = []

    /// Action log for audit trail.
    private var actionLog: [(timestamp: Date, action: String, allowed: Bool)] = []
    private let logQueue = DispatchQueue(label: "safety-guard-log")

    /// Maximum log entries to keep in memory.
    private let maxLogEntries = 1000

    // MARK: - Kill Switch

    /// Register the global kill switch hotkey: ⌘⌥⎋ (Cmd+Option+Escape)
    /// This instantly disables all computer control.
    func registerKillSwitch() {
        // Use a dedicated Carbon event handler for the kill switch
        // so it works even when the app isn't focused
        let hotKeyID = EventHotKeyID(signature: OSType(0x53525F4B), // "SR_K"
                                      id: 1)
        var hotKeyRef: EventHotKeyRef?

        // ⌘⌥⎋ = cmdKey + optionKey + kVK_Escape
        RegisterEventHotKey(
            UInt32(kVK_Escape),
            UInt32(cmdKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        // Install handler
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                var hkID = EventHotKeyID()
                GetEventParameter(event!, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                if hkID.id == 1 {
                    SafetyGuard.shared.toggleKillSwitch()
                }
                return noErr
            },
            1, &eventType,
            nil, nil
        )
    }

    /// Toggle the kill switch.
    func toggleKillSwitch() {
        isEnabled.toggle()
        let status = isEnabled ? "ENABLED ✅" : "DISABLED ⛔️"
        NSLog("[SafetyGuard] Computer control \(status)")

        // Post a system notification so the user knows
        let notification = NSUserNotification()
        notification.title = "Screen Recorder"
        notification.informativeText = "Computer control \(status)"
        notification.soundName = isEnabled ? nil : NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }

    // MARK: - Gate Check

    /// Check if an action is allowed. Call this before executing any synthesized input.
    /// - Parameters:
    ///   - action: Human-readable description of the action (e.g., "click at (500, 300)")
    ///   - targetApp: Optional app name/bundle ID for allowlist checking
    /// - Returns: (allowed: Bool, reason: String?) — if not allowed, reason explains why.
    func checkAction(_ action: String, targetApp: String? = nil) -> (allowed: Bool, reason: String?) {
        // Kill switch
        guard isEnabled else {
            logAction(action, allowed: false)
            return (false, "Computer control is disabled (kill switch active). Press ⌘⌥⎋ to re-enable.")
        }

        // Rate limiting
        if maxActionsPerSecond > 0 {
            let now = Date()
            actionTimestamps = actionTimestamps.filter { now.timeIntervalSince($0) < 1.0 }
            if actionTimestamps.count >= maxActionsPerSecond {
                logAction(action, allowed: false)
                return (false, "Rate limit exceeded (\(maxActionsPerSecond) actions/second)")
            }
            actionTimestamps.append(now)
        }

        // App allowlist
        if !appAllowlist.isEmpty, let app = targetApp {
            let allowed = appAllowlist.contains(where: { app.localizedCaseInsensitiveContains($0) })
            if !allowed {
                logAction(action, allowed: false)
                return (false, "App '\(app)' is not in the allowlist. Allowed: \(appAllowlist.joined(separator: ", "))")
            }
        }

        // Confirmation mode
        if confirmationMode {
            if let handler = confirmationHandler {
                if !handler(action) {
                    logAction(action, allowed: false)
                    return (false, "Action rejected by user confirmation")
                }
            }
        }

        logAction(action, allowed: true)
        return (true, nil)
    }

    // MARK: - Configuration

    /// Configure safety settings from a dictionary (useful for JSON-RPC).
    func configure(_ settings: [String: Any]) {
        if let enabled = settings["enabled"] as? Bool {
            isEnabled = enabled
        }
        if let confirm = settings["confirmation_mode"] as? Bool {
            confirmationMode = confirm
        }
        if let rate = settings["max_actions_per_second"] as? Int {
            maxActionsPerSecond = max(0, rate)
        }
        if let allowlist = settings["app_allowlist"] as? [String] {
            appAllowlist = Set(allowlist)
        }
    }

    /// Get current safety configuration.
    func currentSettings() -> [String: Any] {
        return [
            "enabled": isEnabled,
            "confirmation_mode": confirmationMode,
            "max_actions_per_second": maxActionsPerSecond,
            "app_allowlist": Array(appAllowlist),
            "recent_actions": recentActions(count: 5),
        ]
    }

    // MARK: - Logging

    private func logAction(_ action: String, allowed: Bool) {
        logQueue.async { [weak self] in
            guard let self else { return }
            self.actionLog.append((timestamp: Date(), action: action, allowed: allowed))
            if self.actionLog.count > self.maxLogEntries {
                self.actionLog.removeFirst(self.actionLog.count - self.maxLogEntries)
            }
        }
    }

    /// Get recent actions from the audit log.
    func recentActions(count: Int = 20) -> [[String: Any]] {
        let formatter = ISO8601DateFormatter()
        return logQueue.sync {
            return actionLog.suffix(count).map {
                [
                    "timestamp": formatter.string(from: $0.timestamp),
                    "action": $0.action,
                    "allowed": $0.allowed,
                ]
            }
        }
    }
}
