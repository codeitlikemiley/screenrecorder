import Cocoa
import QuartzCore

class AgentCursorOverlay {
    static let shared = AgentCursorOverlay()
    
    private var window: NSWindow?
    private var cursorLayer: CALayer?
    
    private init() {
        setupWindow()
    }
    
    private func setupWindow() {
        let screenRect = NSScreen.screens.map { $0.frame }.reduce(CGRect.null) { $0.union($1) }
        
        window = NSWindow(
            contentRect: screenRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        window?.isOpaque = false
        window?.backgroundColor = .clear
        window?.ignoresMouseEvents = true
        window?.level = .floating
        window?.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        
        let contentView = NSView(frame: screenRect)
        contentView.wantsLayer = true
        window?.contentView = contentView
        
        cursorLayer = CALayer()
        cursorLayer?.bounds = CGRect(x: 0, y: 0, width: 20, height: 20)
        cursorLayer?.cornerRadius = 10
        cursorLayer?.backgroundColor = NSColor(hex: "#00D26A").withAlphaComponent(0.8).cgColor
        cursorLayer?.borderWidth = 2
        cursorLayer?.borderColor = NSColor.white.cgColor
        cursorLayer?.opacity = 0
        
        if let layer = cursorLayer {
            contentView.layer?.addSublayer(layer)
        }
    }
    
    func showCursorGliding(to target: CGPoint, duration: TimeInterval = 0.3) {
        guard let window = window, let cursorLayer = cursorLayer else { return }
        
        let currentMouseLoc = NSEvent.mouseLocation
        let startPoint = currentMouseLoc
        let endPoint = target
        
        // Convert screen coordinates to window coordinates
        let startWindowPt = window.convertPoint(fromScreen: startPoint)
        let endWindowPt = window.convertPoint(fromScreen: endPoint)
        
        cursorLayer.position = startWindowPt
        cursorLayer.opacity = 1
        window.makeKeyAndOrderFront(nil)
        
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        
        cursorLayer.position = endWindowPt
        
        CATransaction.commit()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.5) {
            self.hide()
        }
    }
    
    func showElementHighlight(frame: CGRect, duration: TimeInterval = 0.4) {
        guard let window = window else { return }
        
        let highlightLayer = CALayer()
        let windowFrame = window.convertFromScreen(frame)
        highlightLayer.frame = windowFrame
        highlightLayer.borderColor = NSColor(hex: "#00D26A").cgColor
        highlightLayer.borderWidth = 3
        highlightLayer.cornerRadius = 4
        highlightLayer.backgroundColor = NSColor(hex: "#00D26A").withAlphaComponent(0.2).cgColor
        
        window.contentView?.layer?.addSublayer(highlightLayer)
        window.makeKeyAndOrderFront(nil)
        
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
    
    private func hide() {
        cursorLayer?.opacity = 0
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
