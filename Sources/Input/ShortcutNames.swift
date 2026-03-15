import KeyboardShortcuts

/// All global keyboard shortcut names for the app.
/// Each name has a `default:` binding that matches the pre-migration hardcoded shortcuts.
/// Users can customize these via the Settings → Keyboard Shortcuts section.
extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording", default: .init(.four, modifiers: [.command, .shift]))
    static let toggleRecordingAlt = Self("toggleRecordingAlt", default: .init(.s, modifiers: [.command, .shift]))
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
    static let toggleAnnotation = Self("toggleAnnotation", default: .init(.d, modifiers: [.command, .shift]))
    static let clearAnnotations = Self("clearAnnotations", default: .init(.x, modifiers: [.command, .shift]))
    static let annotationScreenshot = Self("annotationScreenshot", default: .init(.three, modifiers: [.command, .shift]))
    static let annotationScreenshotAlt = Self("annotationScreenshotAlt", default: .init(.three, modifiers: [.command, .shift, .option]))
    static let toolPen = Self("toolPen", default: .init(.one, modifiers: [.command]))
    static let toolLine = Self("toolLine", default: .init(.two, modifiers: [.command]))
    static let toolArrow = Self("toolArrow", default: .init(.three, modifiers: [.command]))
    static let toolRectangle = Self("toolRectangle", default: .init(.four, modifiers: [.command]))
    static let toolEllipse = Self("toolEllipse", default: .init(.five, modifiers: [.command]))
    static let toolText = Self("toolText", default: .init(.six, modifiers: [.command]))
    static let toolMove = Self("toolMove", default: .init(.seven, modifiers: [.command]))
    static let annotationUndo = Self("annotationUndo", default: .init(.z, modifiers: [.command]))
    static let annotationRedo = Self("annotationRedo", default: .init(.z, modifiers: [.command, .shift]))
}

/// CaseIterable conformance for enumerating all shortcuts in Settings UI.
extension KeyboardShortcuts.Name: @retroactive CaseIterable {
    public static let allCases: [Self] = [
        .toggleRecording,
        .toggleRecordingAlt,
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
        .toggleAnnotation,
        .clearAnnotations,
        .annotationScreenshot,
        .annotationScreenshotAlt,
        .toolPen,
        .toolLine,
        .toolArrow,
        .toolRectangle,
        .toolEllipse,
        .toolText,
        .toolMove,
        .annotationUndo,
        .annotationRedo,
    ]
}

/// Human-readable labels for each shortcut (used in Settings UI).
extension KeyboardShortcuts.Name {
    private static let labels: [String: String] = [
        "toggleRecording": "Start / Stop Recording",
        "toggleRecordingAlt": "Start / Stop Recording (Alt)",
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
        "toggleAnnotation": "Toggle Annotation Mode",
        "clearAnnotations": "Clear Annotations",
        "annotationScreenshot": "Annotation Screenshot",
        "annotationScreenshotAlt": "Annotation Screenshot (Alt)",
        "toolPen": "Pen Tool",
        "toolLine": "Line Tool",
        "toolArrow": "Arrow Tool",
        "toolRectangle": "Rectangle Tool",
        "toolEllipse": "Ellipse Tool",
        "toolText": "Text Tool",
        "toolMove": "Move Tool",
        "annotationUndo": "Undo Annotation",
        "annotationRedo": "Redo Annotation",
    ]

    var label: String {
        Self.labels[rawValue] ?? rawValue
    }
}
