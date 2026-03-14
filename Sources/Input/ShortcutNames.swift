import KeyboardShortcuts

/// All global keyboard shortcut names for the app.
/// Each name has a `default:` binding that matches the pre-migration hardcoded shortcuts.
/// Users can customize these via the Settings → Keyboard Shortcuts section.
extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording", default: .init(.s, modifiers: [.command, .shift]))
    static let toggleCamera = Self("toggleCamera", default: .init(.c, modifiers: [.command, .shift]))
    static let toggleMicrophone = Self("toggleMicrophone", default: .init(.m, modifiers: [.command, .shift]))
    static let toggleKeystrokeOverlay = Self("toggleKeystrokeOverlay", default: .init(.k, modifiers: [.command, .shift]))
    static let toggleControlBar = Self("toggleControlBar", default: .init(.h, modifiers: [.command, .shift]))
    static let openSettings = Self("openSettings", default: .init(.comma, modifiers: [.command]))
    static let openRecordings = Self("openRecordings", default: .init(.f, modifiers: [.command, .shift]))
    static let openLibrary = Self("openLibrary", default: .init(.l, modifiers: [.command, .shift]))
    static let volumeUp = Self("volumeUp", default: .init(.equal, modifiers: [.command, .shift]))
    static let volumeDown = Self("volumeDown", default: .init(.minus, modifiers: [.command, .shift]))
    static let volumeReset = Self("volumeReset", default: .init(.zero, modifiers: [.command, .shift]))
}

/// CaseIterable conformance for enumerating all shortcuts in Settings UI.
extension KeyboardShortcuts.Name: @retroactive CaseIterable {
    public static let allCases: [Self] = [
        .toggleRecording,
        .toggleCamera,
        .toggleMicrophone,
        .toggleKeystrokeOverlay,
        .toggleControlBar,
        .openSettings,
        .openRecordings,
        .openLibrary,
        .volumeUp,
        .volumeDown,
        .volumeReset,
    ]
}

/// Human-readable labels for each shortcut (used in Settings UI).
extension KeyboardShortcuts.Name {
    private static let labels: [String: String] = [
        "toggleRecording": "Start / Stop Recording",
        "toggleCamera": "Toggle Camera",
        "toggleMicrophone": "Toggle Microphone",
        "toggleKeystrokeOverlay": "Toggle Keystroke Overlay",
        "toggleControlBar": "Show / Hide Control Bar",
        "openSettings": "Settings",
        "openRecordings": "Open Recordings",
        "openLibrary": "Recording Library",
        "volumeUp": "Mic Volume Up",
        "volumeDown": "Mic Volume Down",
        "volumeReset": "Reset Mic Volume",
    ]

    var label: String {
        Self.labels[rawValue] ?? rawValue
    }
}
