import SwiftUI
import AppKit

class AgentActivityIndicator {
    static let shared = AgentActivityIndicator()
    
    private var window: NSWindow?
    private var hideWorkItem: DispatchWorkItem?
    
    private init() {}
    
    func show(message: String, isFallback: Bool = false) {
        DispatchQueue.main.async {
            self.hideWorkItem?.cancel()
            
            if self.window == nil {
                self.setupWindow()
            }
            
            let hostingView = NSHostingView(rootView: IndicatorView(message: message, isFallback: isFallback))
            self.window?.contentView = hostingView
            self.positionWindow()
            self.window?.alphaValue = 1.0
            // orderFrontRegardless: never take key status away from the user's app.
            self.window?.orderFrontRegardless()
            
            let workItem = DispatchWorkItem { [weak self] in
                self?.hide()
            }
            self.hideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
        }
    }
    
    private func setupWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        self.window = window
    }

    private func positionWindow() {
        guard let window, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: frame.maxX - window.frame.width - 20, y: frame.minY + 20))
    }
    
    private func hide() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            self.window?.animator().alphaValue = 0
        }, completionHandler: {
            self.window?.orderOut(nil)
            self.window?.alphaValue = 1.0
        })
    }
}

struct IndicatorView: View {
    let message: String
    let isFallback: Bool
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isFallback ? Color.orange : Color.green)
                .frame(width: 8, height: 8)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.8))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }
}
