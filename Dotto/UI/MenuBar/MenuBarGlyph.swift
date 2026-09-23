import AppKit

/// Dotto's menu bar mark: the app icon's lowercase d (icon lab concept D, variant D2 "Overlap") as a one-color
/// template image. The bowl is Dotto's dot and it sinks into the stem, whose top is cut like a pointer tip.
///
/// Drawn per backing scale instead of from a vector, so each size can apply the small-size hinting the app
/// icon uses below 32 px and snap the stem to whole pixels. That keeps the stem edge and baseline crisp at 1x and 2x.
enum MenuBarGlyph {
    private static let imageSideLengthInPoints: CGFloat = 18
    /// The d's taller side fills 16 of the 18 points, leaving a 1 pt margin like other status items.
    private static let glyphSideLengthInPoints: CGFloat = 16
    private static let backingScalesToRender: [CGFloat] = [1, 2]

    // D2 geometry in glyph units: the bowl is centered on the origin and y grows downward. Stem width, ascender
    // and overlap are fractions of the bowl's diameter; the tip cut is in degrees below horizontal.
    private static let bowlDiameter: CGFloat = 330
    private static let bowlRadius: CGFloat = 165
    private static let stemWidthFractionOfBowl: CGFloat = 0.42
    private static let ascenderFractionOfBowl: CGFloat = 0.62
    private static let bowlOverlapFractionOfBowl: CGFloat = 0.14
    private static let tipCutDegrees: CGFloat = 35
    /// Round shapes overshoot flat ones: the stem's baseline sits 3% of the radius above the bowl's bottom.
    private static let bowlOvershootFractionOfRadius: CGFloat = 0.03
    private static let stemCornerRadius: CGFloat = 9

    // Small-size hinting, shared with the app icon's 16 and 32 px masters.
    private static let minimumStemWidthInPixels: CGFloat = 2.4
    private static let minimumTipDropInPixels: CGFloat = 1.5

    static func makeTemplateImage() -> NSImage {
        let imageSize = NSSize(width: imageSideLengthInPoints, height: imageSideLengthInPoints)
        let templateImage = NSImage(size: imageSize)
        for backingScale in backingScalesToRender {
            if let bitmapRepresentation = makeBitmapRepresentation(backingScale: backingScale) {
                templateImage.addRepresentation(bitmapRepresentation)
            }
        }
        templateImage.isTemplate = true
        return templateImage
    }

    private struct StemGeometry {
        var stemLeft: CGFloat
        var stemRight: CGFloat
        var stemTop: CGFloat
        var stemBottom: CGFloat
        var tipDrop: CGFloat

        var glyphBoundingBox: CGRect {
            let glyphRight = max(stemRight, MenuBarGlyph.bowlRadius)
            return CGRect(x: -MenuBarGlyph.bowlRadius, y: stemTop,
                          width: glyphRight + MenuBarGlyph.bowlRadius, height: MenuBarGlyph.bowlRadius - stemTop)
        }
    }

    /// Applies the icon's small-size rules for the given pixel density: the stem is at least 2.4 px wide and the
    /// tip keeps at least 1.5 px of drop so the pointer cut stays visible.
    private static func makeHintedStemGeometry(pixelsPerGlyphUnit: CGFloat) -> StemGeometry {
        let stemWidth = max(stemWidthFractionOfBowl * bowlDiameter,
                            min(minimumStemWidthInPixels / pixelsPerGlyphUnit, bowlDiameter * 0.6))
        var tipCutRadians = tipCutDegrees * .pi / 180
        if stemWidth * tan(tipCutRadians) * pixelsPerGlyphUnit < minimumTipDropInPixels {
            tipCutRadians = min(55 * .pi / 180, atan(minimumTipDropInPixels / pixelsPerGlyphUnit / stemWidth))
        }
        let stemLeft = bowlRadius - bowlOverlapFractionOfBowl * bowlDiameter
        let stemBottom = bowlRadius - bowlOvershootFractionOfRadius * bowlRadius
        let stemTop = -bowlRadius - ascenderFractionOfBowl * bowlDiameter
        let tipDrop = min(stemWidth * tan(tipCutRadians), (stemBottom - stemTop) * 0.85)
        return StemGeometry(stemLeft: stemLeft, stemRight: stemLeft + stemWidth,
                            stemTop: stemTop, stemBottom: stemBottom, tipDrop: tipDrop)
    }

    private static func makeBitmapRepresentation(backingScale: CGFloat) -> NSBitmapImageRep? {
        let pixelSideLength = Int(imageSideLengthInPoints * backingScale)
        guard let bitmapRepresentation = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelSideLength, pixelsHigh: pixelSideLength,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let bitmapGraphicsContext = NSGraphicsContext(bitmapImageRep: bitmapRepresentation) else { return nil }
        bitmapRepresentation.size = NSSize(width: imageSideLengthInPoints, height: imageSideLengthInPoints)

        let unhintedBoundingBoxHeight = bowlRadius * 2 + ascenderFractionOfBowl * bowlDiameter
        let pixelsPerGlyphUnit = glyphSideLengthInPoints * backingScale / unhintedBoundingBoxHeight
        var stemGeometry = makeHintedStemGeometry(pixelsPerGlyphUnit: pixelsPerGlyphUnit)
        let glyphBoundingBox = stemGeometry.glyphBoundingBox
        let imageCenterInPixels = CGFloat(pixelSideLength) / 2
        var glyphOffsetXInPixels = imageCenterInPixels - glyphBoundingBox.midX * pixelsPerGlyphUnit
        var glyphOffsetYInPixels = imageCenterInPixels - glyphBoundingBox.midY * pixelsPerGlyphUnit

        // Pixel snapping: shift the whole d so the stem's left edge and baseline sit on pixel boundaries, then
        // round the stem's width and top to whole pixels. The bowl moves with the shift, so the overlap is kept.
        let stemLeftInPixels = stemGeometry.stemLeft * pixelsPerGlyphUnit + glyphOffsetXInPixels
        let stemBottomInPixels = stemGeometry.stemBottom * pixelsPerGlyphUnit + glyphOffsetYInPixels
        glyphOffsetXInPixels += stemLeftInPixels.rounded() - stemLeftInPixels
        glyphOffsetYInPixels += stemBottomInPixels.rounded() - stemBottomInPixels
        var snappedStemWidthInPixels = ((stemGeometry.stemRight - stemGeometry.stemLeft) * pixelsPerGlyphUnit).rounded()
        if snappedStemWidthInPixels < minimumStemWidthInPixels {
            snappedStemWidthInPixels = minimumStemWidthInPixels.rounded(.up)
        }
        stemGeometry.stemRight = stemGeometry.stemLeft + snappedStemWidthInPixels / pixelsPerGlyphUnit
        let stemTopInPixels = stemGeometry.stemTop * pixelsPerGlyphUnit + glyphOffsetYInPixels
        stemGeometry.stemTop = (stemTopInPixels.rounded() - glyphOffsetYInPixels) / pixelsPerGlyphUnit

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = bitmapGraphicsContext
        let graphicsContext = bitmapGraphicsContext.cgContext
        // Flip to y-down so the glyph units read like the icon's SVG space.
        graphicsContext.translateBy(x: 0, y: CGFloat(pixelSideLength))
        graphicsContext.scaleBy(x: 1, y: -1)
        graphicsContext.translateBy(x: glyphOffsetXInPixels, y: glyphOffsetYInPixels)
        graphicsContext.scaleBy(x: pixelsPerGlyphUnit, y: pixelsPerGlyphUnit)
        graphicsContext.addPath(makeGlyphPath(stemGeometry: stemGeometry))
        graphicsContext.setFillColor(NSColor.black.cgColor)
        graphicsContext.fillPath(using: .winding)
        bitmapGraphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmapRepresentation
    }

    /// The bowl plus the stem: vertical left edge, highest point top-left, a cut falling to the right, and every
    /// stem corner softened by the same radius the app icon uses.
    private static func makeGlyphPath(stemGeometry: StemGeometry) -> CGPath {
        let glyphPath = CGMutablePath()
        glyphPath.addEllipse(in: CGRect(x: -bowlRadius, y: -bowlRadius, width: bowlDiameter, height: bowlDiameter))
        let stemCorners = [
            CGPoint(x: stemGeometry.stemLeft, y: stemGeometry.stemBottom),
            CGPoint(x: stemGeometry.stemLeft, y: stemGeometry.stemTop),
            CGPoint(x: stemGeometry.stemRight, y: stemGeometry.stemTop + stemGeometry.tipDrop),
            CGPoint(x: stemGeometry.stemRight, y: stemGeometry.stemBottom),
        ]
        // Start halfway along the bottom edge so every corner, including the first, gets rounded by addArc.
        let bottomEdgeMidpoint = CGPoint(x: (stemGeometry.stemLeft + stemGeometry.stemRight) / 2, y: stemGeometry.stemBottom)
        glyphPath.move(to: bottomEdgeMidpoint)
        for cornerIndex in stemCorners.indices {
            let nextCorner = stemCorners[(cornerIndex + 1) % stemCorners.count]
            glyphPath.addArc(tangent1End: stemCorners[cornerIndex], tangent2End: nextCorner, radius: stemCornerRadius)
        }
        glyphPath.closeSubpath()
        return glyphPath
    }
}
