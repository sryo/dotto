import CoreGraphics
import CoreText
import Foundation

/// Draws a mark layout onto a captured window image: a colored box around each marked element and its element id on a
/// label of the same color. It never resizes the image, so click_point's pixel coordinates are unchanged.
enum ScreenshotMarkRenderer {
    private static let labelFontSizeInPixels: CGFloat = 11
    private static let labelHeightInPixels: CGFloat = 14
    private static let labelHorizontalPaddingInPixels: CGFloat = 3
    private static let boxLineWidthInPixels: CGFloat = 2

    /// Saturated and dark enough for white text, and far enough apart to tell neighbouring marks apart.
    private static let paletteRedGreenBlue: [(CGFloat, CGFloat, CGFloat)] = [
        (0.86, 0.10, 0.24), (0.00, 0.45, 0.85), (0.05, 0.55, 0.25),
        (0.60, 0.20, 0.75), (0.85, 0.40, 0.00), (0.00, 0.50, 0.55),
    ]

    private static let labelFont: CTFont = {
        let systemFont = CTFontCreateUIFontForLanguage(.system, labelFontSizeInPixels, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, labelFontSizeInPixels, nil)
        return CTFontCreateCopyWithSymbolicTraits(systemFont, labelFontSizeInPixels, nil, .traitBold, .traitBold) ?? systemFont
    }()

    /// Every label is an "e" followed by digits, so the wider of the two bounds each character.
    static let labelMetrics: ScreenshotLabelMetrics = {
        let widestCharacterWidth = ["e", "0", "8"].map { character in
            CGFloat(CTLineGetTypographicBounds(makeLabelLine(character), nil, nil, nil))
        }.max() ?? labelFontSizeInPixels * 0.6
        return ScreenshotLabelMetrics(characterWidthInPixels: widestCharacterWidth.rounded(.up),
                                      labelHeightInPixels: labelHeightInPixels,
                                      horizontalPaddingInPixels: labelHorizontalPaddingInPixels)
    }()

    static func drawing(_ markLayout: ScreenshotMarkLayout, onto image: CGImage) -> CGImage {
        guard !markLayout.marks.isEmpty,
              let canvasContext = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return image }
        let imageHeight = CGFloat(image.height)
        canvasContext.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        // The layout is in top-left pixels; the bitmap context's origin is bottom-left.
        func contextRect(fromTopLeftPixelRect topLeftPixelRect: CGRect) -> CGRect {
            CGRect(x: topLeftPixelRect.minX, y: imageHeight - topLeftPixelRect.maxY,
                   width: topLeftPixelRect.width, height: topLeftPixelRect.height)
        }

        for mark in markLayout.marks {
            let (red, green, blue) = paletteRedGreenBlue[mark.paletteIndex % paletteRedGreenBlue.count]
            let markColor = CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
            canvasContext.setStrokeColor(markColor)
            canvasContext.setLineWidth(boxLineWidthInPixels)
            // Inset by half the line so the stroke stays inside the element's box.
            canvasContext.stroke(contextRect(fromTopLeftPixelRect: mark.boxInImagePixels)
                .insetBy(dx: boxLineWidthInPixels / 2, dy: boxLineWidthInPixels / 2))

            let labelRect = contextRect(fromTopLeftPixelRect: mark.labelRectInImagePixels)
            canvasContext.setFillColor(markColor)
            canvasContext.fill(labelRect)
            let labelLine = makeLabelLine(mark.elementIdentifier)
            var descent: CGFloat = 0
            var ascent: CGFloat = 0
            _ = CTLineGetTypographicBounds(labelLine, &ascent, &descent, nil)
            canvasContext.textPosition = CGPoint(x: labelRect.minX + labelHorizontalPaddingInPixels,
                                                 y: labelRect.minY + (labelRect.height - ascent - descent) / 2 + descent)
            CTLineDraw(labelLine, canvasContext)
        }
        return canvasContext.makeImage() ?? image
    }

    private static func makeLabelLine(_ labelText: String) -> CTLine {
        let labelAttributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): labelFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: labelText, attributes: labelAttributes))
    }
}
