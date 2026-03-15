import AppKit
import CoreGraphics

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
    /// - Parameters:
    ///   - imageURL: URL of the original frame PNG
    ///   - action: The aggregated action associated with this frame
    ///   - stepNumber: The step number to label
    ///   - outputDirectory: Where to save the annotated image
    /// - Returns: URL of the annotated image, or nil if annotation failed
    func annotateFrame(
        imageURL: URL,
        action: AggregatedAction,
        stepNumber: Int,
        outputDirectory: URL
    ) -> URL? {
        guard let nsImage = NSImage(contentsOf: imageURL) else {
            print("  ⚠️ Cannot load image for annotation: \(imageURL.lastPathComponent)")
            return nil
        }

        guard let position = action.position else {
            // No position data — just add step label to the image
            return addStepLabel(
                to: nsImage,
                stepNumber: stepNumber,
                action: action,
                outputDirectory: outputDirectory,
                originalFilename: imageURL.deletingPathExtension().lastPathComponent
            )
        }

        let imageSize = nsImage.size

        // Create a new image with annotations drawn on it
        let annotated = NSImage(size: imageSize)
        annotated.lockFocus()

        // Draw original image
        nsImage.draw(
            in: NSRect(origin: .zero, size: imageSize),
            from: NSRect(origin: .zero, size: imageSize),
            operation: .copy,
            fraction: 1.0
        )

        // Get graphics context
        guard let context = NSGraphicsContext.current?.cgContext else {
            annotated.unlockFocus()
            return nil
        }

        // Convert screen coordinates to image coordinates
        // Screen coordinates have origin at top-left, image at bottom-left
        let imagePos = convertToImageCoordinates(
            screenPosition: position,
            imageSize: imageSize
        )

        // Draw interaction indicator based on action type
        let color = annotationColor(for: action.actionType)

        switch action.actionType {
        case .click, .doubleClick, .rightClick:
            drawClickIndicator(
                context: context,
                at: imagePos,
                color: color,
                isDouble: action.actionType == .doubleClick
            )

        case .type, .formFill:
            drawTypeIndicator(
                context: context,
                at: imagePos,
                color: color,
                text: action.typedText
            )

        case .drag:
            // Draw start point with arrow hint
            drawClickIndicator(context: context, at: imagePos, color: color, isDouble: false)

        case .scroll:
            drawScrollIndicator(context: context, at: imagePos, color: color)

        case .shortcut, .keyPress:
            drawShortcutIndicator(
                context: context,
                at: imagePos,
                color: color,
                text: action.description
            )
        }

        // Draw step number badge
        drawStepBadge(context: context, stepNumber: stepNumber, color: color, imageSize: imageSize)

        // Draw action label
        drawActionLabel(
            context: context,
            action: action,
            near: imagePos,
            color: color,
            imageSize: imageSize
        )

        annotated.unlockFocus()

        // Save annotated image
        let outputFilename = imageURL.deletingPathExtension().lastPathComponent + "_annotated.png"
        let outputURL = outputDirectory.appendingPathComponent(outputFilename)

        guard let tiffData = annotated.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            return nil
        }

        do {
            try pngData.write(to: outputURL)
            return outputURL
        } catch {
            print("  ⚠️ Failed to save annotated frame: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Batch Annotate

    /// Annotate all frames for a set of workflow steps.
    func annotateAllFrames(
        steps: [WorkflowStep],
        actions: [AggregatedAction],
        framesDirectory: URL
    ) -> [String: String] {
        // Map of original filename → annotated filename
        var annotationMap: [String: String] = [:]

        for step in steps {
            guard let screenshotFile = step.screenshotFile else { continue }

            let imageURL = framesDirectory.appendingPathComponent(screenshotFile)

            // Find the matching aggregated action by timestamp proximity
            let matchingAction = actions.min(by: {
                abs($0.bestFrameTimestamp - step.timestampStart) <
                abs($1.bestFrameTimestamp - step.timestampStart)
            })

            guard let action = matchingAction else { continue }

            if let annotatedURL = annotateFrame(
                imageURL: imageURL,
                action: action,
                stepNumber: step.stepNumber,
                outputDirectory: framesDirectory
            ) {
                annotationMap[screenshotFile] = annotatedURL.lastPathComponent
            }
        }

        print("  🎨 Annotated \(annotationMap.count)/\(steps.count) frames")
        return annotationMap
    }

    // MARK: - Drawing Helpers

    /// Convert screen coordinates to image coordinates.
    /// Screen: origin top-left. Image (NSImage): origin bottom-left.
    /// We also need to account for the image being potentially scaled vs. screen resolution.
    private func convertToImageCoordinates(
        screenPosition: CGPoint,
        imageSize: NSSize
    ) -> CGPoint {
        // Assume the image represents the full screen
        // The screen capture image dimensions should match the screen
        // Flip Y axis: image origin is bottom-left
        return CGPoint(
            x: screenPosition.x,
            y: imageSize.height - screenPosition.y
        )
    }

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
        imageSize: NSSize
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
        imageSize: NSSize
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

    /// Add just a step label (when no position data available)
    private func addStepLabel(
        to image: NSImage,
        stepNumber: Int,
        action: AggregatedAction,
        outputDirectory: URL,
        originalFilename: String
    ) -> URL? {
        let imageSize = image.size
        let annotated = NSImage(size: imageSize)
        annotated.lockFocus()

        image.draw(
            in: NSRect(origin: .zero, size: imageSize),
            from: NSRect(origin: .zero, size: imageSize),
            operation: .copy,
            fraction: 1.0
        )

        guard let context = NSGraphicsContext.current?.cgContext else {
            annotated.unlockFocus()
            return nil
        }

        let color = annotationColor(for: action.actionType)
        drawStepBadge(context: context, stepNumber: stepNumber, color: color, imageSize: imageSize)

        annotated.unlockFocus()

        let outputURL = outputDirectory.appendingPathComponent("\(originalFilename)_annotated.png")
        guard let tiffData = annotated.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            return nil
        }

        do {
            try pngData.write(to: outputURL)
            return outputURL
        } catch {
            return nil
        }
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
