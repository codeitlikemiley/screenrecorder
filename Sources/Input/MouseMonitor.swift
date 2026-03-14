import AppKit
import CoreGraphics

/// Monitors global mouse events (clicks, drags, scrolls) using NSEvent global monitors.
/// Similar architecture to KeystrokeMonitor but for pointer interactions.
/// Requires no additional permissions beyond what the app already has.
class MouseMonitor {
    private var clickMonitor: Any?
    private var rightClickMonitor: Any?
    private var scrollMonitor: Any?
    private var dragMonitor: Any?
    private(set) var isMonitoring = false

    // Drag tracking state
    private var dragStartPosition: CGPoint?
    private var dragStartTime: Date?

    // Callbacks
    var onMouseClick: ((CGPoint, MouseButton, Int) -> Void)?     // position, button, clickCount
    var onMouseDrag: ((CGPoint, CGPoint, TimeInterval) -> Void)? // start, end, duration
    var onMouseScroll: ((CGPoint, CGFloat, CGFloat) -> Void)?    // position, deltaX, deltaY

    // MARK: - Start Monitoring

    func startMonitoring() {
        guard !isMonitoring else { return }

        // Left clicks (single, double, triple)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            let position = NSEvent.mouseLocation
            self?.onMouseClick?(position, .left, event.clickCount)
        }

        // Right clicks
        rightClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            let position = NSEvent.mouseLocation
            self?.onMouseClick?(position, .right, event.clickCount)
        }

        // Scroll events (coalesced — only log significant scrolls)
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            // Filter out tiny momentum scroll events
            guard abs(event.scrollingDeltaY) > 2 || abs(event.scrollingDeltaX) > 2 else { return }
            let position = NSEvent.mouseLocation
            self?.onMouseScroll?(position, event.scrollingDeltaX, event.scrollingDeltaY)
        }

        // Drag detection: track mouse-down → mouse-up with movement
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self = self else { return }

            switch event.type {
            case .leftMouseDragged:
                if self.dragStartPosition == nil {
                    self.dragStartPosition = NSEvent.mouseLocation
                    self.dragStartTime = Date()
                }
            case .leftMouseUp:
                if let startPos = self.dragStartPosition, let startTime = self.dragStartTime {
                    let endPos = NSEvent.mouseLocation
                    let distance = hypot(endPos.x - startPos.x, endPos.y - startPos.y)
                    // Only log as drag if moved more than 10 pixels
                    if distance > 10 {
                        let duration = Date().timeIntervalSince(startTime)
                        self.onMouseDrag?(startPos, endPos, duration)
                    }
                }
                self.dragStartPosition = nil
                self.dragStartTime = nil
            default:
                break
            }
        }

        isMonitoring = true
        print("🖱️ Mouse monitoring started")
    }

    // MARK: - Stop Monitoring

    func stopMonitoring() {
        guard isMonitoring else { return }

        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        if let m = rightClickMonitor { NSEvent.removeMonitor(m) }
        if let m = scrollMonitor { NSEvent.removeMonitor(m) }
        if let m = dragMonitor { NSEvent.removeMonitor(m) }

        clickMonitor = nil
        rightClickMonitor = nil
        scrollMonitor = nil
        dragMonitor = nil
        dragStartPosition = nil
        dragStartTime = nil
        isMonitoring = false

        print("🖱️ Mouse monitoring stopped")
    }

    deinit {
        stopMonitoring()
    }
}
