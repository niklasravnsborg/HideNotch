import AppKit

/// Draws the same screen outline and notch for the menu bar and app icon.
@MainActor
public enum NotchIcon {
    enum GlyphLayout {
        static let heightFraction: CGFloat = 14.0 / 18.0
    }

    /// Fractions describing how the glyph sits on the app icon's rounded-square canvas.
    enum AppIconLayout {
        /// Square inset from the canvas edge, as a fraction of the canvas side (100/1024).
        static let squareInsetFraction: CGFloat = 100.0 / 1024.0
        /// Corner radius of the rounded square, as a fraction of the canvas side (185/1024).
        static let squareCornerRadiusFraction: CGFloat = 185.0 / 1024.0
        /// Glyph width as a fraction of the square's width.
        static let glyphWidthFraction: CGFloat = 0.6
    }

    /// An 18×18 pt template image for the status item; AppKit adapts its color
    /// to the current menu-bar appearance.
    public static func menuBarImage() -> NSImage {
        let canvas = NSRect(x: 0, y: 0, width: 18, height: 18)
        let image = NSImage(size: canvas.size, flipped: false) { rect in
            let glyph = glyphRect(width: 18, centeredIn: rect)
            drawGlyph(in: glyph, color: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "HideNotch"
        return image
    }

    /// Renders the app icon (rounded square, light gradient, centered glyph) into an
    /// exactly `pixels`×`pixels` bitmap and returns it as PNG data.
    public static func appIconPNG(pixels: Int) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = NSSize(width: pixels, height: pixels)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        drawAppIcon(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else {
            preconditionFailure("Failed to encode AppIcon PNG")
        }
        return png
    }

    /// The rect for the glyph with the given `width` (height follows the fixed aspect
    /// ratio), centered inside `container`.
    static func glyphRect(width: CGFloat, centeredIn container: CGRect) -> CGRect {
        let height = width * GlyphLayout.heightFraction
        return CGRect(
            x: container.midX - width / 2,
            y: container.midY - height / 2,
            width: width,
            height: height
        )
    }

    /// Draws the rounded square background (light vertical gradient) and the glyph on top.
    private static func drawAppIcon(in canvas: CGRect) {
        let side = canvas.width
        let inset = side * AppIconLayout.squareInsetFraction
        let square = canvas.insetBy(dx: inset, dy: inset)
        let cornerRadius = side * AppIconLayout.squareCornerRadiusFraction
        let squarePath = NSBezierPath(roundedRect: square, xRadius: cornerRadius, yRadius: cornerRadius)

        NSGraphicsContext.saveGraphicsState()
        squarePath.addClip()
        let gradient = NSGradient(starting: .white, ending: NSColor(red: 0xE5 / 255, green: 0xE5 / 255, blue: 0xEA / 255, alpha: 1))!
        gradient.draw(in: square, angle: 90)
        NSGraphicsContext.restoreGraphicsState()

        let glyph = glyphRect(width: square.width * AppIconLayout.glyphWidthFraction, centeredIn: square)
        drawGlyph(in: glyph, color: .black)
    }

    /// Scales the 18-point menu-bar glyph to the requested size.
    /// AppKit drawing coordinates use a bottom-left origin.
    static func drawGlyph(in rect: CGRect, color: NSColor) {
        let scale = rect.width / 18
        let lineWidth = 1.4 * scale
        let outlineRect = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let outline = NSBezierPath(roundedRect: outlineRect, xRadius: 2.5 * scale, yRadius: 2.5 * scale)
        outline.lineWidth = lineWidth
        color.setStroke()
        outline.stroke()

        let notch = CGRect(x: rect.midX - 3.5 * scale, y: rect.maxY - 4 * scale, width: 7 * scale, height: 4 * scale)
        color.setFill()
        NSBezierPath(roundedRect: notch, xRadius: scale, yRadius: scale).fill()
    }
}
