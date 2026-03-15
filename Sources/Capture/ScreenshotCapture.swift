import AppKit
import CoreGraphics

/// Captures the screen (including annotation overlays) and saves as PNG.
/// Uses CGWindowListCreateImage for capture and NSSavePanel for save location.
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

        // Small delay to let the toolbar disappear before capture
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            defer { showToolbar?() }

            // 2. Capture the entire main display
            guard let cgImage = CGWindowListCreateImage(
                .infinite,
                .optionOnScreenOnly,
                kCGNullWindowID,
                [.bestResolution]
            ) else {
                print("⚠️ Screenshot capture failed — CGWindowListCreateImage returned nil")
                return
            }

            // 3. Convert CGImage to PNG data
            let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
            guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                print("⚠️ Screenshot capture failed — could not generate PNG data")
                return
            }

            // 4. Show NSSavePanel
            let savePanel = NSSavePanel()
            savePanel.title = "Save Annotation Screenshot"
            savePanel.nameFieldStringValue = generateFilename()
            savePanel.allowedContentTypes = [.png]
            savePanel.canCreateDirectories = true
            savePanel.directoryURL = defaultDirectory

            // Brief white flash animation (like macOS screenshot)
            flashScreen()

            let response = savePanel.runModal()

            if response == .OK, let url = savePanel.url {
                do {
                    try pngData.write(to: url)
                    print("📸 Screenshot saved to: \(url.path)")

                    // Reveal in Finder
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    print("⚠️ Failed to save screenshot: \(error.localizedDescription)")
                }
            }
        }
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
