import Cocoa
import QuartzCore

/// Cosmetic, click-through overlay that shows where the agent is acting.
/// Never moves the real cursor and never takes key/main status.
///
/// All public methods take **global display coordinates (top-left origin)** — the same
/// space used by CGEvent and the Accessibility API — and are safe to call from any thread.
class AgentCursorOverlay {
    static let shared = AgentCursorOverlay()

    private var window: NSWindow?
    private var cursorLayer: CALayer?
    private var hideWorkItem: DispatchWorkItem?

    private init() {}

    /// Glide a virtual cursor from the user's real cursor position to `target`.
    func showCursorGliding(to target: CGPoint, duration: TimeInterval = 0.3) {
        DispatchQueue.main.async {
            guard let window = self.ensureWindow(), let cursorLayer = self.cursorLayer else { return }
            self.hideWorkItem?.cancel()

            let start = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            let end = window.convertPoint(fromScreen: Self.cocoaPoint(fromGlobal: target))

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cursorLayer.position = start
            cursorLayer.opacity = 1
            CATransaction.commit()
            window.orderFrontRegardless()

            CATransaction.begin()
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            cursorLayer.position = end
            CATransaction.commit()

            let workItem = DispatchWorkItem { [weak self] in self?.hideCursor() }
            self.hideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.5, execute: workItem)
        }
    }

    /// Briefly outline an element the agent acted on (e.g. an AX press target).
    func showElementHighlight(frame: CGRect, duration: TimeInterval = 0.6) {
        DispatchQueue.main.async {
            guard let window = self.ensureWindow() else { return }

            let highlightLayer = CALayer()
            highlightLayer.frame = window.convertFromScreen(Self.cocoaRect(fromGlobal: frame))
            highlightLayer.borderColor = NSColor(hex: "#00D26A").cgColor
            highlightLayer.borderWidth = 3
            highlightLayer.cornerRadius = 4
            highlightLayer.backgroundColor = NSColor(hex: "#00D26A").withAlphaComponent(0.2).cgColor
            highlightLayer.opacity = 0

            window.contentView?.layer?.addSublayer(highlightLayer)
            window.orderFrontRegardless()

            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 1.0
            animation.toValue = 0.0
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            highlightLayer.add(animation, forKey: "fade")

            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                highlightLayer.removeFromSuperlayer()
            }
        }
    }

    // MARK: - Private (main thread)

    private func ensureWindow() -> NSWindow? {
        let screenRect = NSScreen.screens.map { $0.frame }.reduce(CGRect.null) { $0.union($1) }
        if let window {
            // Displays may have been added/removed since the window was created.
            if window.frame != screenRect { window.setFrame(screenRect, display: false) }
            return window
        }

        let window = NSWindow(
            contentRect: screenRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let contentView = NSView(frame: NSRect(origin: .zero, size: screenRect.size))
        contentView.wantsLayer = true
        window.contentView = contentView

        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 20, height: 20)
        layer.cornerRadius = 10
        layer.backgroundColor = NSColor(hex: "#00D26A").withAlphaComponent(0.8).cgColor
        layer.borderWidth = 2
        layer.borderColor = NSColor.white.cgColor
        layer.opacity = 0
        contentView.layer?.addSublayer(layer)

        self.window = window
        self.cursorLayer = layer
        return window
    }

    private func hideCursor() {
        cursorLayer?.opacity = 0
    }

    /// Height of the primary display — the reference for flipping global (top-left) coordinates.
    private static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    private static func cocoaPoint(fromGlobal point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    private static func cocoaRect(fromGlobal rect: CGRect) -> CGRect {
        CGRect(x: rect.origin.x, y: primaryScreenHeight - rect.origin.y - rect.height, width: rect.width, height: rect.height)
    }
}

extension NSColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int = UInt64()
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }
}
