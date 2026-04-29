import AppKit
import SwiftUI

/// A scoped overlay that sits above a single controlled window and absorbs mouse input.
final class ShieldOverlayWindow: NSPanel {
    private let hostingView: ShieldBlockingHostingView

    init(frame: CGRect, message: String) {
        self.hostingView = ShieldBlockingHostingView(rootView: ShieldOverlayContentView(message: message))
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        animationBehavior = .none
        contentView = hostingView
    }

    func update(frame: CGRect, message: String) {
        setFrame(frame, display: true)
        hostingView.rootView = ShieldOverlayContentView(message: message)
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ShieldBlockingHostingView: NSHostingView<ShieldOverlayContentView> {
    override func hitTest(_ point: NSPoint) -> NSView? { self }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDragged(with event: NSEvent) {}
    override func otherMouseDragged(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}

private struct ShieldOverlayContentView: View {
    let message: String

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.23, green: 0.56, blue: 0.99).opacity(0.85),
                                        Color(red: 0.20, green: 0.82, blue: 0.55).opacity(0.75),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2
                            )
                    )
                    .padding(2)

                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(red: 0.96, green: 0.33, blue: 0.33))
                        .frame(width: 8, height: 8)
                    Text(message)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.black.opacity(0.72))
                .clipShape(Capsule())
                .padding(16)
            }
            .ignoresSafeArea()
        }
    }
}
