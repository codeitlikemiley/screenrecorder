import Foundation
import ApplicationServices
import AppKit

enum InputMethod {
    case axPress(element: AXUIElement)
    case axSetValue(element: AXUIElement, value: String)
    case cgEventClick(point: CGPoint, targetPid: pid_t)
    case cgEventType(text: String, targetPid: pid_t)
    case ocrClick(text: String)
    case unsupported(reason: String)
    
    var methodName: String {
        switch self {
        case .axPress: return "ax_press"
        case .axSetValue: return "ax_set_value"
        case .cgEventClick(let point, let pid): return pid == 0 ? "cg_event_global" : "cg_event_to_pid"
        case .cgEventType(_, let pid): return pid == 0 ? "cg_event_global" : "cg_event_to_pid"
        case .ocrClick: return "ocr_fallback"
        case .unsupported: return "unsupported"
        }
    }
}

class InputOrchestrator {
    private let inputSynthesizer: InputSynthesizer
    
    init(inputSynthesizer: InputSynthesizer) {
        self.inputSynthesizer = inputSynthesizer
    }
    
    /// Try AX → CGEvent(toPid) → CGEvent(global) → OCR → fail
    func click(title: String?, point: CGPoint?, targetPid: pid_t, targetApp: String?) async -> [String: Any] {
        return ["ok": false, "error": "Not implemented yet"]
    }
    
    func type(text: String, field: String?, targetPid: pid_t, targetApp: String?) async -> [String: Any] {
        return ["ok": false, "error": "Not implemented yet"]
    }
}
