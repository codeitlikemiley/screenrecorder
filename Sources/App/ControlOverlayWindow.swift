import AppKit
import SwiftUI

/// Full-screen overlay panel displayed while an AI agent controls the computer.
///
/// Design goals:
/// - Clear, readable "Agent is controlling your Mac" message
/// - Pulsing animated border so the user knows input is blocked
/// - Shows the unlock hotkey prominently
/// - Does NOT intercept mouse events itself — event filtering is handled by `AgentControlLock`
/// - Does NOT steal keyboard focus (uses `NSPanel` with `becomesKeyOnlyIfNeeded`)
/// - Sits at `.screenSaver - 1` level so it's above normal windows but below the macOS menu bar
final class ControlOverlayWindow: NSPanel {

    private let unlockKey: String
    private var pulseTimer: Timer?

    // MARK: - Init

    init(unlockKey: String) {
        self.unlockKey = unlockKey

        guard let screen = NSScreen.main else {
            super.init(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            return
        }

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        configure()
    }

    // MARK: - Configuration

    private func configure() {
        // Window properties
        isOpaque = false
        backgroundColor = NSColor.clear
        hasShadow = false
        ignoresMouseEvents = true       // pass-through; AgentControlLock handles event blocking
        isMovable = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelKey.screenSaverWindow.rawValue) - 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        // Content view
        contentView = NSHostingView(rootView: OverlayContentView(unlockKey: unlockKey))
    }

    // MARK: - Show / Hide

    func showOverlay() {
        // Match current screen bounds (can change if display config changes)
        if let screen = NSScreen.main {
            setFrame(screen.frame, display: false)
        }
        alphaValue = 0
        orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }
    }

    func hideOverlay() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: {
            self.orderOut(nil)
        })
    }

    // NSPanel: do not become key window (never steal focus)
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Overlay SwiftUI View

private struct OverlayContentView: View {
    let unlockKey: String
    @State private var pulsation: CGFloat = 0.0
    @State private var dotCount: Int = 0

    private let dotTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    private let pulseTimer = Timer.publish(every: 0.04, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // Background — dark translucent overlay
            Color.black.opacity(0.40)
                .ignoresSafeArea()

            // Animated border ring around the entire screen
            Rectangle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color(red: 0.4, green: 0.6, blue: 1.0).opacity(0.5 + 0.5 * pulsation),
                            Color(red: 0.6, green: 0.3, blue: 1.0).opacity(0.5 + 0.5 * (1 - pulsation)),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 4
                )
                .ignoresSafeArea()

            // Center card
            VStack(spacing: 20) {
                // Spinner icon
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.4, green: 0.6, blue: 1.0),
                                         Color(red: 0.6, green: 0.3, blue: 1.0)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 72, height: 72)

                    Image(systemName: "cpu")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundColor(.white)
                }
                .shadow(color: Color(red: 0.4, green: 0.6, blue: 1.0).opacity(0.6 + 0.4 * pulsation), radius: 20)

                // Title
                Text("Agent is controlling your Mac")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)

                // Animated dots
                Text("Working\(String(repeating: ".", count: dotCount + 1))")
                    .font(.system(size: 14, weight: .regular, design: .monospaced))
                    .foregroundColor(.white.opacity(0.65))

                Divider()
                    .background(Color.white.opacity(0.15))
                    .padding(.horizontal, 32)

                // Unlock hint
                HStack(spacing: 8) {
                    Image(systemName: "lock.open.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.7))

                    Text("Press ")
                        .foregroundColor(.white.opacity(0.7))
                        .font(.system(size: 13))

                    Text(unlockKey.formatted)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                                )
                        )

                    Text(" to take back control")
                        .foregroundColor(.white.opacity(0.7))
                        .font(.system(size: 13))
                }
            }
            .padding(48)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color(red: 0.1, green: 0.1, blue: 0.15).opacity(0.9))
                    .shadow(color: .black.opacity(0.5), radius: 40)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(
                        Color.white.opacity(0.1 + 0.1 * pulsation),
                        lineWidth: 1.5
                    )
            )
        }
        .onReceive(pulseTimer) { _ in
            pulsation = (sin(Date().timeIntervalSinceReferenceDate * 2.0) + 1) / 2
        }
        .onReceive(dotTimer) { _ in
            dotCount = (dotCount + 1) % 3
        }
    }
}

// MARK: - String Formatting for Unlock Key

private extension String {
    /// Converts "cmd+shift+f12" → "⌘⇧F12" for display.
    var formatted: String {
        self.split(separator: "+").map { part in
            switch part.lowercased() {
            case "cmd", "command":    return "⌘"
            case "shift":             return "⇧"
            case "alt", "opt", "option": return "⌥"
            case "ctrl", "control":   return "⌃"
            case "f12": return "F12"
            case "f11": return "F11"
            case "f10": return "F10"
            case "escape", "esc": return "⎋"
            default:                  return part.uppercased()
            }
        }.joined()
    }
}
