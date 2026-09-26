import AppKit
import CoreGraphics
import ImageIO

/// Draws bounding box annotations on extracted key frames to highlight interaction locations.
/// Creates annotated copies of frame images with colored circles/boxes at click positions,
/// step number labels, and action type indicators.
class FrameAnnotator {

    struct AnnotationStyle {
        /// Radius of the click indicator circle
        var clickRadius: CGFloat = 24.0
        /// Width of the bounding box stroke
        var strokeWidth: CGFloat = 3.0
        /// Font size for step number labels
        var labelFontSize: CGFloat = 14.0
        /// Size of the typing indicator box
        var typeBoxSize: CGSize = CGSize(width: 200, height: 40)
    }

    private let style: AnnotationStyle

    init(style: AnnotationStyle = AnnotationStyle()) {
        self.style = style
    }

    // MARK: - Annotate Frame

    /// Create an annotated copy of a frame image with interaction indicators.
    /// Uses a private bitmap context, so it is safe to call off the main thread.
    /// - Parameters:
    ///   - imageURL: URL of the original frame
    ///   - action: The aggregated action this frame shows
    ///   - stepNumber: The step number to label
    ///   - geometry: Where the recorded content was on screen (maps positions onto the frame)
    ///   - outputURL: Where to save the annotated JPEG
    /// - Returns: `outputURL` on success
    func annotateFrame(
        imageURL: URL,
        action: AggregatedAction?,
        stepNumber: Int,
        geometry: CaptureGeometry?,
        outputURL: URL
    ) -> URL? {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            print("  ⚠️ Cannot load image for annotation: \(imageURL.lastPathComponent)")
            return nil
        }
        let imageSize = CGSize(width: image.width, height: image.height)
        let color = action.map { annotationColor(for: $0.actionType) }
            ?? CGColor(red: 0.45, green: 0.45, blue: 0.5, alpha: 1)

        // Position in image pixels, bottom-left origin (CoreGraphics). Nil when the interaction
        // happened outside the captured area or the capture origin is unknown.
        let imagePos: CGPoint? = action?.position.flatMap { global in
            geometry?.imagePoint(forGlobal: global, imageSize: imageSize).map {
                CGPoint(x: $0.x, y: imageSize.height - $0.y)
            }
        }

        let rendered = render(image) { context in
            if let action, let imagePos {
                switch action.actionType {
                case .click, .doubleClick, .rightClick:
                    drawClickIndicator(context: context, at: imagePos, color: color, isDouble: action.actionType == .doubleClick)
                case .type, .formFill:
                    drawTypeIndicator(context: context, at: imagePos, color: color, text: action.typedText)
                case .drag:
                    drawClickIndicator(context: context, at: imagePos, color: color, isDouble: false)
                case .scroll:
                    drawScrollIndicator(context: context, at: imagePos, color: color)
                case .shortcut, .keyPress:
                    drawShortcutIndicator(context: context, at: imagePos, color: color, text: action.description)
                }
                drawActionLabel(context: context, action: action, near: imagePos, color: color, imageSize: imageSize)
            }
            drawStepBadge(context: context, stepNumber: stepNumber, color: color, imageSize: imageSize)
        }

        guard let rendered else { return nil }
        do {
            try KeyFrameExtractor.writeJPEG(rendered, to: outputURL, quality: 0.85)
            return outputURL
        } catch {
            print("  ⚠️ Failed to save annotated frame: \(error.localizedDescription)")
            return nil
        }
    }

    /// Draw `image` into a fresh bitmap context, run `draw`, and return the result.
    /// Sets a thread-local NSGraphicsContext so NSString drawing lands in the same context.
    private func render(_ image: CGImage, draw: (CGContext) -> Void) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        draw(context)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    // MARK: - Batch Annotate

    /// Annotate one frame per workflow step, using the action each step maps to.
    /// - Returns: step number → annotated filename (each step gets its own file, even when
    ///   two steps share a screenshot).
    func annotateAllFrames(
        steps: [WorkflowStep],
        actions: [AggregatedAction],
        framesDirectory: URL,
        geometry: CaptureGeometry?
    ) -> [Int: String] {
        var annotationMap: [Int: String] = [:]

        for step in steps {
            guard let screenshotFile = step.screenshotFile else { continue }
            let imageURL = framesDirectory.appendingPathComponent(screenshotFile)
            let action = step.actionIndex.flatMap { index in actions.first { $0.sequenceNumber == index } }
            let base = (screenshotFile as NSString).deletingPathExtension
            let outputURL = framesDirectory.appendingPathComponent("\(base)_step\(step.stepNumber)_annotated.jpg")

            if let annotated = annotateFrame(
                imageURL: imageURL,
                action: action,
                stepNumber: step.stepNumber,
                geometry: geometry,
                outputURL: outputURL
            ) {
                annotationMap[step.stepNumber] = annotated.lastPathComponent
            }
        }

        print("  🎨 Annotated \(annotationMap.count)/\(steps.count) frames")
        return annotationMap
    }

    // MARK: - Drawing Helpers

    /// Draw a click indicator (circle + crosshair)
    private func drawClickIndicator(
        context: CGContext,
        at point: CGPoint,
        color: CGColor,
        isDouble: Bool
    ) {
        let radius = style.clickRadius

        context.saveGState()

        // Outer circle
        context.setStrokeColor(color)
        context.setLineWidth(style.strokeWidth)
        context.strokeEllipse(in: CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        ))

        // Semi-transparent fill
        context.setFillColor(color.copy(alpha: 0.15)!)
        context.fillEllipse(in: CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        ))

        // Crosshair lines
        let crossSize: CGFloat = radius * 0.6
        context.setLineWidth(1.5)
        context.move(to: CGPoint(x: point.x - crossSize, y: point.y))
        context.addLine(to: CGPoint(x: point.x + crossSize, y: point.y))
        context.move(to: CGPoint(x: point.x, y: point.y - crossSize))
        context.addLine(to: CGPoint(x: point.x, y: point.y + crossSize))
        context.strokePath()

        // Double-click: add second outer ring
        if isDouble {
            let outerRadius = radius + 6
            context.setLineWidth(2.0)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.strokeEllipse(in: CGRect(
                x: point.x - outerRadius,
                y: point.y - outerRadius,
                width: outerRadius * 2,
                height: outerRadius * 2
            ))
        }

        context.restoreGState()
    }

    /// Draw a typing indicator (rounded rect representing a text field)
    private func drawTypeIndicator(
        context: CGContext,
        at point: CGPoint,
        color: CGColor,
        text: String?
    ) {
        let boxSize = style.typeBoxSize

        context.saveGState()

        // Draw a rounded rectangle around the type area
        let rect = CGRect(
            x: point.x - boxSize.width / 2,
            y: point.y - boxSize.height / 2,
            width: boxSize.width,
            height: boxSize.height
        )

        let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.setStrokeColor(color)
        context.setLineWidth(style.strokeWidth)
        context.setLineDash(phase: 0, lengths: [6, 3])
        context.addPath(path)
        context.strokePath()

        // Semi-transparent fill
        context.setFillColor(color.copy(alpha: 0.08)!)
        context.addPath(path)
        context.fillPath()

        context.restoreGState()
    }

    /// Draw a scroll indicator (vertical arrows)
    private func drawScrollIndicator(
        context: CGContext,
        at point: CGPoint,
        color: CGColor
    ) {
        context.saveGState()
        context.setStrokeColor(color)
        context.setLineWidth(style.strokeWidth)

        let arrowHeight: CGFloat = 30.0
        let arrowWidth: CGFloat = 12.0

        // Up arrow
        context.move(to: CGPoint(x: point.x, y: point.y + arrowHeight))
        context.addLine(to: CGPoint(x: point.x - arrowWidth, y: point.y + arrowHeight - 10))
        context.move(to: CGPoint(x: point.x, y: point.y + arrowHeight))
        context.addLine(to: CGPoint(x: point.x + arrowWidth, y: point.y + arrowHeight - 10))

        // Vertical line
        context.move(to: CGPoint(x: point.x, y: point.y + arrowHeight))
        context.addLine(to: CGPoint(x: point.x, y: point.y - arrowHeight))

        // Down arrow
        context.move(to: CGPoint(x: point.x, y: point.y - arrowHeight))
        context.addLine(to: CGPoint(x: point.x - arrowWidth, y: point.y - arrowHeight + 10))
        context.move(to: CGPoint(x: point.x, y: point.y - arrowHeight))
        context.addLine(to: CGPoint(x: point.x + arrowWidth, y: point.y - arrowHeight + 10))

        context.strokePath()
        context.restoreGState()
    }

    /// Draw a shortcut/key press indicator (rounded badge)
    private func drawShortcutIndicator(
        context: CGContext,
        at point: CGPoint,
        color: CGColor,
        text: String
    ) {
        // Just draw a small highlighted badge
        let badgeWidth: CGFloat = max(60, CGFloat(text.count * 10))
        let badgeHeight: CGFloat = 28.0
        let rect = CGRect(
            x: point.x - badgeWidth / 2,
            y: point.y - badgeHeight / 2,
            width: badgeWidth,
            height: badgeHeight
        )

        context.saveGState()

        let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.setFillColor(color.copy(alpha: 0.2)!)
        context.addPath(path)
        context.fillPath()

        context.setStrokeColor(color)
        context.setLineWidth(2.0)
        context.addPath(path)
        context.strokePath()

        context.restoreGState()
    }

    /// Draw step number badge in top-left corner
    private func drawStepBadge(
        context: CGContext,
        stepNumber: Int,
        color: CGColor,
        imageSize: CGSize
    ) {
        let badgeSize: CGFloat = 32
        let margin: CGFloat = 12
        let badgeRect = CGRect(
            x: margin,
            y: imageSize.height - margin - badgeSize,
            width: badgeSize,
            height: badgeSize
        )

        context.saveGState()

        // Circle background
        context.setFillColor(color)
        context.fillEllipse(in: badgeRect)

        // Step number text
        let text = "\(stepNumber)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: style.labelFontSize, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attrs)
        let textPoint = NSPoint(
            x: badgeRect.midX - textSize.width / 2,
            y: badgeRect.midY - textSize.height / 2
        )

        NSGraphicsContext.saveGraphicsState()
        text.draw(at: textPoint, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()

        context.restoreGState()
    }

    /// Draw action label near the interaction point
    private func drawActionLabel(
        context: CGContext,
        action: AggregatedAction,
        near point: CGPoint,
        color: CGColor,
        imageSize: CGSize
    ) {
        let labelText = action.description as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = labelText.size(withAttributes: attrs)
        let padding: CGFloat = 6
        let bgWidth = textSize.width + padding * 2
        let bgHeight = textSize.height + padding * 2

        // Position label below the interaction point, clamped to image bounds
        var labelX = point.x - bgWidth / 2
        var labelY = point.y - style.clickRadius - bgHeight - 4

        // Clamp to image bounds
        labelX = max(4, min(imageSize.width - bgWidth - 4, labelX))
        labelY = max(4, min(imageSize.height - bgHeight - 4, labelY))

        let bgRect = CGRect(x: labelX, y: labelY, width: bgWidth, height: bgHeight)

        context.saveGState()

        // Background pill
        let path = CGPath(roundedRect: bgRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.7))
        context.addPath(path)
        context.fillPath()

        // Border
        context.setStrokeColor(color.copy(alpha: 0.6)!)
        context.setLineWidth(1.0)
        context.addPath(path)
        context.strokePath()

        // Text
        NSGraphicsContext.saveGraphicsState()
        labelText.draw(
            at: NSPoint(x: labelX + padding, y: labelY + padding),
            withAttributes: attrs
        )
        NSGraphicsContext.restoreGraphicsState()

        context.restoreGState()
    }

    // MARK: - Colors

    private func annotationColor(for actionType: AggregatedAction.ActionType) -> CGColor {
        switch actionType {
        case .click:       return CGColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 1.0)  // Blue
        case .doubleClick: return CGColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 1.0)  // Blue
        case .rightClick:  return CGColor(red: 0.8, green: 0.4, blue: 0.0, alpha: 1.0)  // Orange
        case .type:        return CGColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 1.0)  // Green
        case .keyPress:    return CGColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1.0)  // Gray
        case .shortcut:    return CGColor(red: 0.6, green: 0.2, blue: 0.8, alpha: 1.0)  // Purple
        case .scroll:      return CGColor(red: 0.6, green: 0.3, blue: 0.9, alpha: 1.0)  // Purple
        case .drag:        return CGColor(red: 0.9, green: 0.5, blue: 0.1, alpha: 1.0)  // Orange
        case .formFill:    return CGColor(red: 0.0, green: 0.7, blue: 0.7, alpha: 1.0)  // Teal
        }
    }
}
