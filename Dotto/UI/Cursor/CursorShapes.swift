import SwiftUI

// The pieces Dotto's cursor is drawn from: the shapes of each morph and the status text that circles the cursor.

/// The arrow and every morph layer are drawn in a 112-point box whose point (50, 50) is the arrow tip,
/// matching the lab's SVG viewBox (-50 -50 112 112), so every coordinate below is in "cursor points".
enum CursorLayerBox {
    static let sideLength: CGFloat = 112
    static let tipOffset: CGFloat = 50
    static func position(ofCursorPoint cursorPoint: CGPoint) -> CGPoint {
        CGPoint(x: tipOffset + cursorPoint.x, y: tipOffset + cursorPoint.y)
    }
}

/// The FigJam-style arrow from the lab, "M1.5 1.5 L19 8.2 L10.6 10.6 L8.2 19 Z", in a 20-point square.
struct CursorArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 20
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit) }
        var path = Path()
        path.move(to: point(1.5, 1.5))
        path.addLine(to: point(19, 8.2))
        path.addLine(to: point(10.6, 10.6))
        path.addLine(to: point(8.2, 19))
        path.closeSubpath()
        return path
    }
}

/// The typing I-beam, centered on the tip, drawn in cursor points (24-point square, center at 12, 12).
struct CursorIBeamShape: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.midX + x, y: rect.midY + y) }
        var path = Path()
        path.move(to: point(-4.5, -10))
        path.addQuadCurve(to: point(0, -5), control: point(0, -9))
        path.addLine(to: point(0, 7))
        path.addQuadCurve(to: point(-4.5, 12), control: point(0, 11))
        path.move(to: point(4.5, -10))
        path.addQuadCurve(to: point(0, -5), control: point(0, -9))
        path.move(to: point(0, 7))
        path.addQuadCurve(to: point(4.5, 12), control: point(0, 11))
        path.move(to: point(-2.8, 1))
        path.addLine(to: point(2.8, 1))
        return path
    }
}

struct CursorCheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.midX + x, y: rect.midY + y) }
        var path = Path()
        path.move(to: point(-5, 0.5))
        path.addLine(to: point(-1.5, 4))
        path.addLine(to: point(5.5, -3.5))
        return path
    }
}

// MARK: - Ring text

/// Lays a label around a circle the way SVG `textPath` does in the lab: the label plus a " · " separator
/// is repeated once around a ring whose radius grows to fit it, within a minimum and 38 points.
enum CursorRingTextLayout {
    static let fontSize: CGFloat = 7
    /// Advance of one 7-point monospaced glyph.
    static let glyphAdvance: CGFloat = fontSize * 0.66
    static let maximumRadius: CGFloat = 38

    static func layout(label: String, minimumRadius: CGFloat) -> (ringText: String, radius: CGFloat) {
        var ringText = label.uppercased() + " · "
        let fittingRadius = CGFloat(ringText.count) * glyphAdvance / (2 * .pi)
        let radius = max(minimumRadius, min(maximumRadius, fittingRadius))
        let maximumGlyphCount = Int((2 * .pi * radius / glyphAdvance).rounded(.down))
        if ringText.count > maximumGlyphCount {
            ringText = String(ringText.prefix(max(0, maximumGlyphCount - 4))) + "… · "
        }
        return (ringText, radius)
    }
}

struct CursorRingTextView: View {
    let ringText: String
    let radius: CGFloat
    let color: Color
    let rotationDegrees: Double

    static let canvasSideLength: CGFloat = (CursorRingTextLayout.maximumRadius + 10) * 2

    var body: some View {
        Canvas { graphicsContext, canvasSize in
            let ringCenter = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let glyphs = Array(ringText)
            guard !glyphs.isEmpty, radius > 0 else { return }
            // textLength = 98.5% of the circumference in the lab, spread evenly over the glyphs.
            let arcLengthPerGlyph = 2 * .pi * radius * 0.985 / CGFloat(glyphs.count)
            // Glyphs sit outside the ring with their baseline on it, so their centers are a little further out.
            let glyphCenterRadius = radius + CursorRingTextLayout.fontSize * 0.35
            let rotationRadians = rotationDegrees * .pi / 180
            for (glyphIndex, glyph) in glyphs.enumerated() {
                // The lab's path starts at 9 o'clock and runs clockwise over the top (y grows downward).
                let glyphAngle = Double.pi + Double((CGFloat(glyphIndex) + 0.5) * arcLengthPerGlyph / radius) + rotationRadians
                var glyphContext = graphicsContext
                glyphContext.translateBy(x: ringCenter.x + glyphCenterRadius * CGFloat(cos(glyphAngle)),
                                         y: ringCenter.y + glyphCenterRadius * CGFloat(sin(glyphAngle)))
                // The tangent of a clockwise path is the radius angle plus 90°, so glyphs stand upright at the top.
                glyphContext.rotate(by: .radians(glyphAngle + .pi / 2))
                glyphContext.draw(
                    Text(String(glyph))
                        .font(.system(size: CursorRingTextLayout.fontSize, weight: .semibold, design: .monospaced))
                        .foregroundColor(color),
                    at: .zero, anchor: .center)
            }
        }
        .frame(width: Self.canvasSideLength, height: Self.canvasSideLength)
        .allowsHitTesting(false)
    }
}

/// Accumulates the ring text's rotation across frames so a speed change (reading → thinking) doesn't jump.
final class CursorRingRotationAccumulator {
    var rotationDegrees: Double = 0
    var lastFrameDate: Date?

    func advance(to frameDate: Date, degreesPerSecond: Double) -> Double {
        let elapsedSeconds = min(0.05, max(0, frameDate.timeIntervalSince(lastFrameDate ?? frameDate)))
        lastFrameDate = frameDate
        rotationDegrees = (rotationDegrees + degreesPerSecond * elapsedSeconds).truncatingRemainder(dividingBy: 360)
        return rotationDegrees
    }
}
