import SwiftUI
import AppKit

/// Manages the recording library window lifecycle.
/// Opens a dedicated NSWindow with the LibraryView.
@MainActor
class LibraryWindowManager {
    static let shared = LibraryWindowManager()
    private var window: NSWindow?
    private let library = RecordingLibrary()

    /// Open the library window pointing at the given recordings directory.
    func open(directory: URL) {
        // If already open, just focus and refresh
        if let existingWindow = window, existingWindow.isVisible {
            Task { await library.scan(directory: directory) }
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Scan recordings
        Task { await library.scan(directory: directory) }

        let contentView = LibraryView(library: library, directory: directory)
        let hostingView = NSHostingView(rootView: contentView)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        newWindow.contentView = hostingView
        newWindow.title = "Recording Library"
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        newWindow.center()
        newWindow.setFrameAutosaveName("RecordingLibrary")
        newWindow.isReleasedWhenClosed = false
        newWindow.minSize = NSSize(width: 600, height: 360)

        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = newWindow
    }
}
