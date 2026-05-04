import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Captures the screen (including annotation overlays) and saves as PNG.
/// Uses ScreenCaptureKit for reliable capture that includes the correct
/// foreground windows, falling back to CGWindowListCreateImage.
@MainActor
class ScreenshotCapture {

    /// Capture the main display and prompt the user to save as PNG.
    /// - Parameters:
    ///   - defaultDirectory: Default save location for the save panel
    ///   - hideToolbar: Closure to temporarily hide the annotation toolbar before capture
    ///   - showToolbar: Closure to re-show the annotation toolbar after capture
    static func captureAndSave(
        defaultDirectory: URL,
        hideToolbar: (() -> Void)? = nil,
        showToolbar: (() -> Void)? = nil
    ) {
        // 1. Temporarily hide the toolbar so it doesn't appear in the screenshot
        hideToolbar?()

        // Slightly longer delay to ensure the toolbar is fully gone
        // and the window server has updated the composite
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            Task {
                defer { showToolbar?() }

                // Try SCK first for better quality, fall back to CGWindowList
                let cgImage: CGImage? = await captureWithSCK() ?? captureWithCGWindowList()

                guard let image = cgImage else {
                    print("⚠️ Screenshot capture failed — no image")
                    return
                }

                // Convert to PNG
                let bitmapRep = NSBitmapImageRep(cgImage: image)
                guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                    print("⚠️ Screenshot capture failed — could not generate PNG data")
                    return
                }

                // Flash effect
                flashScreen()

                // Show NSSavePanel
                let savePanel = NSSavePanel()
                savePanel.title = "Save Annotation Screenshot"
                savePanel.nameFieldStringValue = generateFilename()
                savePanel.allowedContentTypes = [.png]
                savePanel.canCreateDirectories = true
                savePanel.directoryURL = defaultDirectory

                let response = savePanel.runModal()

                if response == .OK, let url = savePanel.url {
                    do {
                        try pngData.write(to: url)
                        print("📸 Screenshot saved to: \(url.path)")
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } catch {
                        print("⚠️ Failed to save screenshot: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    // MARK: - ScreenCaptureKit Capture

    /// Capture using ScreenCaptureKit for high-fidelity display capture
    /// that correctly composites all visible windows.
    private static func captureWithSCK() async -> CGImage? {
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else { return nil }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width * 2  // Retina
            config.height = display.height * 2
            config.capturesAudio = false
            config.showsCursor = true

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            return image
        } catch {
            print("⚠️ SCK screenshot failed, falling back to CGWindowList: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - CGWindowList Fallback

    /// Fallback capture using CGWindowListCreateImage.
    /// Captures the main display composited image.
    private static func captureWithCGWindowList() -> CGImage? {
        guard let mainDisplay = NSScreen.main else { return nil }
        let displayID = mainDisplay.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            ?? CGMainDisplayID()

        // Capture the specific display rather than .infinite to get the correct composited result
        let displayBounds = CGDisplayBounds(displayID)
        return CGWindowListCreateImage(
            displayBounds,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        )
    }

    // MARK: - Helpers

    /// Generate a timestamp-based filename
    private static func generateFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "Annotation_\(formatter.string(from: Date())).png"
    }

    /// Brief white flash effect to indicate capture (like macOS screenshot)
    private static func flashScreen() {
        guard let screen = NSScreen.main else { return }

        let flashWindow = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        flashWindow.level = .screenSaver + 2
        flashWindow.isOpaque = false
        flashWindow.backgroundColor = NSColor.white.withAlphaComponent(0.3)
        flashWindow.ignoresMouseEvents = true
        flashWindow.collectionBehavior = [.canJoinAllSpaces]
        flashWindow.orderFrontRegardless()

        // Fade out and remove
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            flashWindow.animator().alphaValue = 0
        }, completionHandler: {
            flashWindow.orderOut(nil)
        })
    }
}
