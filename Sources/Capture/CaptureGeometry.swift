import AppKit
import ScreenCaptureKit

/// Where the recorded content sat on screen, so interaction positions can be mapped
/// onto video frames.
///
/// All positions use **global display coordinates in points, top-left origin** (the
/// CoreGraphics / Accessibility space). `NSEvent.mouseLocation` uses a bottom-left
/// origin and must be converted with `globalTopLeft(fromCocoa:)` before comparing.
struct CaptureGeometry: Codable, Equatable {
    enum Kind: String, Codable {
        case display
        case window
        case application
        case unknown
    }

    var kind: Kind
    /// Top-left of the captured content in global points. Nil when it can't be determined
    /// (e.g. a window picked on macOS < 15.2); positions then can't be mapped.
    var originX: Double?
    var originY: Double?
    /// Size of the captured content in points.
    var width: Double
    var height: Double
    /// Pixels per point of the captured content.
    var scale: Double

    /// Video frame size in pixels this geometry produces.
    var pixelWidth: Int { max(2, Int((width * scale).rounded()) & ~1) }
    var pixelHeight: Int { max(2, Int((height * scale).rounded()) & ~1) }

    /// Map a global top-left point to a pixel position in an image of `imageSize` pixels
    /// (top-left origin). Returns nil if the origin is unknown or the point lies outside the content.
    func imagePoint(forGlobal point: CGPoint, imageSize: CGSize) -> CGPoint? {
        guard let originX, let originY, width > 0, height > 0 else { return nil }
        let relX = (Double(point.x) - originX) / width
        let relY = (Double(point.y) - originY) / height
        guard (0...1).contains(relX), (0...1).contains(relY) else { return nil }
        return CGPoint(x: relX * Double(imageSize.width), y: relY * Double(imageSize.height))
    }

    // MARK: - Coordinate conversion

    /// Height of the primary display (the one containing the menu bar), used to flip Cocoa coordinates.
    static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// Convert an `NSEvent.mouseLocation`-style point (bottom-left origin) to global top-left points.
    static func globalTopLeft(fromCocoa point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    // MARK: - From a content filter

    /// Resolve the geometry of what `filter` captures.
    static func resolve(for filter: SCContentFilter) -> CaptureGeometry {
        var geometry = resolveUnchecked(for: filter)
        // If the filter reported no size, fall back to the main screen (the old behaviour).
        if geometry.width <= 0 || geometry.height <= 0 {
            let screen = NSScreen.main ?? NSScreen.screens.first
            geometry.width = Double(screen?.frame.width ?? 1920)
            geometry.height = Double(screen?.frame.height ?? 1080)
            geometry.scale = Double(screen?.backingScaleFactor ?? 2)
            geometry.originX = nil
            geometry.originY = nil
        }
        return geometry
    }

    private static func resolveUnchecked(for filter: SCContentFilter) -> CaptureGeometry {
        let rect = filter.contentRect
        let scale = Double(filter.pointPixelScale > 0 ? filter.pointPixelScale : 2)
        var geometry = CaptureGeometry(
            kind: .unknown,
            originX: nil,
            originY: nil,
            width: Double(rect.width),
            height: Double(rect.height),
            scale: scale
        )

        switch filter.style {
        case .display: geometry.kind = .display
        case .window: geometry.kind = .window
        case .application: geometry.kind = .application
        default: break
        }

        // macOS 15.2+ tells us exactly which display/window was picked, with its global frame.
        if #available(macOS 15.2, *) {
            if geometry.kind == .window, let window = filter.includedWindows.first {
                geometry.setOrigin(window.frame.origin)
                return geometry
            }
            if let display = filter.includedDisplays.first {
                geometry.setOrigin(display.frame.origin)
                if geometry.width <= 0 || geometry.height <= 0 {
                    geometry.width = Double(display.frame.width)
                    geometry.height = Double(display.frame.height)
                }
                return geometry
            }
        }

        // Older systems: a display capture can be matched to an NSScreen by size.
        if geometry.kind == .display || geometry.kind == .application {
            let candidates = NSScreen.screens.filter {
                abs(Double($0.frame.width) - geometry.width) < 1 && abs(Double($0.frame.height) - geometry.height) < 1
            }
            if let screen = candidates.first(where: { $0 == NSScreen.main }) ?? candidates.first {
                // NSScreen frames are Cocoa (bottom-left); convert the top-left corner.
                let topLeft = globalTopLeft(fromCocoa: CGPoint(x: screen.frame.minX, y: screen.frame.maxY))
                geometry.setOrigin(topLeft)
            }
        }
        return geometry
    }

    private mutating func setOrigin(_ point: CGPoint) {
        originX = Double(point.x)
        originY = Double(point.y)
    }

    /// Legacy recordings (metadata v1) had no geometry: assume the primary display.
    static func legacyPrimaryDisplay() -> CaptureGeometry {
        let screen = NSScreen.screens.first
        return CaptureGeometry(
            kind: .display,
            originX: 0,
            originY: 0,
            width: Double(screen?.frame.width ?? 1920),
            height: Double(screen?.frame.height ?? 1080),
            scale: Double(screen?.backingScaleFactor ?? 2)
        )
    }
}
