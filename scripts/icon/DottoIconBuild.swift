// Draws Dotto's app icon (icon lab concept D, variant D2 "Overlap", light background, Klein blue)
// with CoreGraphics and writes the PNG ladder plus the layered SVGs for Icon Composer.
//
// Usage: DottoIconBuild <png-output-directory> <svg-output-directory>
//
// Geometry follows lowercaseD()/iconSVG() in dotto-icon-lab.html with the lab defaults
// (weight 4, dot size 1, glyph scale 1). Glyph units: the bowl's center is the origin, y grows downward.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Constants from the lab

let canvasSide: Double = 1024
let squircleSemiAxis: Double = 412          // 824 body / 2
let squircleExponent: Double = 5
let glyphFitTarget: Double = 520            // the glyph's larger side on the 1024 canvas, at glyph scale 1
let smallMasterScale: Double = 1.08         // hinted master draws the d 8% larger

let referenceBowlDiameter: Double = 330
let bowlRadius: Double = 165
let stemWidthFraction: Double = 0.42
let ascenderFraction: Double = 0.62
let tipCutDegrees: Double = 35
let joinFraction: Double = -0.14            // negative = the bowl overlaps the stem
let cornerRounding: Double = 6 + 4 * 3      // lab: 6 + weight * 3, weight 4
let bowlOvershootFraction: Double = 0.03    // stem baseline sits 3% of the radius above the bowl's bottom

let kleinBlueHex = "#3B2BF0"
let backgroundTopHex = "#FFFDFB"
let backgroundBottomHex = "#EEE9F1"
let sheenTopOpacity: Double = 0.35
let sheenFadeEndFraction: Double = 0.45
let hairlineOpacity: Double = 0.08
let hairlineWidth: Double = 4

// MARK: - Geometry

struct LowercaseDGeometry {
    var stemLeft: Double
    var stemRight: Double
    var stemTop: Double
    var stemBottom: Double
    var tipDrop: Double

    var boundingBox: CGRect {
        let maximumX = max(stemRight, bowlRadius)
        return CGRect(x: -bowlRadius, y: stemTop, width: maximumX + bowlRadius, height: bowlRadius - stemTop)
    }

    /// The stem's outer outline before corner rounding: vertical left edge, highest point top-left,
    /// cut falling to the right. Clockwise on screen (y down).
    var stemOutlinePoints: [CGPoint] {
        [CGPoint(x: stemLeft, y: stemBottom),
         CGPoint(x: stemLeft, y: stemTop),
         CGPoint(x: stemRight, y: stemTop + tipDrop),
         CGPoint(x: stemRight, y: stemBottom)]
    }
}

/// `hintPixelsPerGlyphUnit` is set below 32 px and applies the lab's small-size rules:
/// stem at least 2.4 px, a near-kiss merges into a 1 px overlap, a thin gap opens to 1.5 px,
/// and the tip keeps at least 1.5 px of drop.
func makeLowercaseDGeometry(hintPixelsPerGlyphUnit: Double?) -> LowercaseDGeometry {
    var stemWidth = stemWidthFraction * referenceBowlDiameter
    var join = joinFraction * referenceBowlDiameter
    var tipDegrees = tipCutDegrees
    let ascender = ascenderFraction * referenceBowlDiameter
    if let pixelsPerUnit = hintPixelsPerGlyphUnit {
        stemWidth = max(stemWidth, min(2.4 / pixelsPerUnit, referenceBowlDiameter * 0.6))
        let joinInPixels = join * pixelsPerUnit
        if abs(joinInPixels) <= 0.35 {
            join = -1 / pixelsPerUnit
        } else if joinInPixels > 0 && joinInPixels < 1.5 {
            join = 1.5 / pixelsPerUnit
        }
        let tipDropInPixels = stemWidth * tan(tipDegrees * .pi / 180) * pixelsPerUnit
        if tipDegrees > 0 && tipDropInPixels < 1.5 {
            tipDegrees = min(55, atan(1.5 / pixelsPerUnit / stemWidth) * 180 / .pi)
        }
    }
    let stemLeft = bowlRadius + join
    let stemBottom = bowlRadius - bowlOvershootFraction * bowlRadius
    let stemTop = -bowlRadius - ascender
    let tipDrop = min(stemWidth * tan(tipDegrees * .pi / 180), (stemBottom - stemTop) * 0.85)
    return LowercaseDGeometry(stemLeft: stemLeft, stemRight: stemLeft + stemWidth,
                              stemTop: stemTop, stemBottom: stemBottom, tipDrop: tipDrop)
}

/// Moves every edge of a simple polygon inward by `distance` and re-intersects neighbours (lab's insetPolygon).
func insetPolygon(_ points: [CGPoint], distance: Double) -> [CGPoint] {
    let count = points.count
    var doubledArea = 0.0
    for index in 0..<count {
        let start = points[index], end = points[(index + 1) % count]
        doubledArea += start.x * end.y - end.x * start.y
    }
    let inwardSign: Double = doubledArea > 0 ? 1 : -1
    struct OffsetEdge { var pointX: Double; var pointY: Double; var deltaX: Double; var deltaY: Double }
    let offsetEdges: [OffsetEdge] = (0..<count).map { index in
        let start = points[index], end = points[(index + 1) % count]
        let deltaX = end.x - start.x, deltaY = end.y - start.y
        let length = max(hypot(deltaX, deltaY), 1e-9)
        let normalX = (-deltaY / length) * inwardSign, normalY = (deltaX / length) * inwardSign
        return OffsetEdge(pointX: start.x + normalX * distance, pointY: start.y + normalY * distance, deltaX: deltaX, deltaY: deltaY)
    }
    return (0..<count).map { index in
        let edge = offsetEdges[index], previous = offsetEdges[(index - 1 + count) % count]
        let cross = previous.deltaX * edge.deltaY - previous.deltaY * edge.deltaX
        if abs(cross) < 1e-9 { return CGPoint(x: edge.pointX, y: edge.pointY) }
        let t = ((edge.pointX - previous.pointX) * edge.deltaY - (edge.pointY - previous.pointY) * edge.deltaX) / cross
        return CGPoint(x: previous.pointX + previous.deltaX * t, y: previous.pointY + previous.deltaY * t)
    }
}

/// One piece of the rounded stem outline: a straight edge, then the corner arc that ends it.
struct RoundedOutlineSegment {
    var lineEnd: CGPoint
    var arcCenter: CGPoint
    var arcEnd: CGPoint
}

/// The lab draws the stem as an inset polygon stroked with a round join. The union of that fill and stroke is
/// the original outline with each convex corner replaced by an arc of radius rounding/2 around the inset vertex,
/// so this builds that outline directly as a fill-only path (Icon Composer tints fills, not strokes).
func roundedStemOutline(_ geometry: LowercaseDGeometry) -> (start: CGPoint, segments: [RoundedOutlineSegment]) {
    let cornerRadius = cornerRounding / 2
    let insetVertices = insetPolygon(geometry.stemOutlinePoints, distance: cornerRadius)
    let count = insetVertices.count
    // Outward normal of the edge from inset vertex i to i+1. The outline runs clockwise on screen (y down),
    // so outward is (dy, -dx): the left edge, travelling up, gets (-1, 0).
    func outwardNormal(_ edgeIndex: Int) -> CGPoint {
        let start = insetVertices[edgeIndex], end = insetVertices[(edgeIndex + 1) % count]
        let deltaX = end.x - start.x, deltaY = end.y - start.y, length = hypot(deltaX, deltaY)
        return CGPoint(x: deltaY / length, y: -deltaX / length)
    }
    var segments: [RoundedOutlineSegment] = []
    let firstNormal = outwardNormal(0)
    let start = CGPoint(x: insetVertices[0].x + firstNormal.x * cornerRadius, y: insetVertices[0].y + firstNormal.y * cornerRadius)
    for edgeIndex in 0..<count {
        let normal = outwardNormal(edgeIndex), nextNormal = outwardNormal((edgeIndex + 1) % count)
        let cornerVertex = insetVertices[(edgeIndex + 1) % count]
        segments.append(RoundedOutlineSegment(
            lineEnd: CGPoint(x: cornerVertex.x + normal.x * cornerRadius, y: cornerVertex.y + normal.y * cornerRadius),
            arcCenter: cornerVertex,
            arcEnd: CGPoint(x: cornerVertex.x + nextNormal.x * cornerRadius, y: cornerVertex.y + nextNormal.y * cornerRadius)))
    }
    return (start, segments)
}

// MARK: - Placement on the canvas

/// Maps glyph units to output pixels: pixel = glyphUnit * pixelsPerGlyphUnit + offset (y down).
struct GlyphPlacement {
    var geometry: LowercaseDGeometry
    var pixelsPerGlyphUnit: Double
    var offsetX: Double
    var offsetY: Double
}

func placeGlyphInIcon(outputPixelSize: Int, usesSmallMaster: Bool, snapsToPixels: Bool) -> GlyphPlacement {
    let outputScale = Double(outputPixelSize) / canvasSide
    var geometry = makeLowercaseDGeometry(hintPixelsPerGlyphUnit: nil)
    var fit = glyphFitTarget / max(geometry.boundingBox.width, geometry.boundingBox.height)
    if usesSmallMaster {
        let hintPixelsPerGlyphUnit = fit * smallMasterScale * outputScale
        geometry = makeLowercaseDGeometry(hintPixelsPerGlyphUnit: hintPixelsPerGlyphUnit)
        fit = glyphFitTarget / max(geometry.boundingBox.width, geometry.boundingBox.height) * smallMasterScale
    }
    let box = geometry.boundingBox
    let translateX = canvasSide / 2 - box.midX * fit
    let translateY = canvasSide / 2 - box.midY * fit
    var placement = GlyphPlacement(geometry: geometry, pixelsPerGlyphUnit: fit * outputScale,
                                   offsetX: translateX * outputScale, offsetY: translateY * outputScale)
    if snapsToPixels { snapStemToPixelGrid(&placement, minimumStemPixels: usesSmallMaster ? 2.4 : 1) }
    return placement
}

/// Shifts the whole glyph so the stem's left edge and baseline land on pixel boundaries, then rounds the stem's
/// width and its top to whole pixels. The bowl moves with the shift, so the overlap and overshoot are kept.
func snapStemToPixelGrid(_ placement: inout GlyphPlacement, minimumStemPixels: Double) {
    let scale = placement.pixelsPerGlyphUnit
    let stemLeftPixels = placement.geometry.stemLeft * scale + placement.offsetX
    let stemBottomPixels = placement.geometry.stemBottom * scale + placement.offsetY
    placement.offsetX += stemLeftPixels.rounded() - stemLeftPixels
    placement.offsetY += stemBottomPixels.rounded() - stemBottomPixels

    let stemWidthPixels = (placement.geometry.stemRight - placement.geometry.stemLeft) * scale
    var snappedStemWidthPixels = stemWidthPixels.rounded()
    if snappedStemWidthPixels < minimumStemPixels { snappedStemWidthPixels = minimumStemPixels.rounded(.up) }
    placement.geometry.stemRight = placement.geometry.stemLeft + snappedStemWidthPixels / scale

    let stemTopPixels = placement.geometry.stemTop * scale + placement.offsetY
    placement.geometry.stemTop = (stemTopPixels.rounded() - placement.offsetY) / scale
}

// MARK: - CoreGraphics drawing

let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func cgColor(hex: String, alpha: Double = 1) -> CGColor {
    let digits = Int(hex.dropFirst(), radix: 16)!
    return CGColor(colorSpace: sRGBColorSpace, components: [
        Double((digits >> 16) & 0xFF) / 255, Double((digits >> 8) & 0xFF) / 255, Double(digits & 0xFF) / 255, alpha])!
}

func squirclePoints(stepCount: Int = 720) -> [CGPoint] {
    (0..<stepCount).map { step in
        let angle = Double(step) / Double(stepCount) * 2 * .pi
        let cosine = cos(angle), sine = sin(angle)
        let exponent = 2 / squircleExponent
        return CGPoint(x: canvasSide / 2 + squircleSemiAxis * (cosine < 0 ? -1 : 1) * pow(abs(cosine), exponent),
                       y: canvasSide / 2 + squircleSemiAxis * (sine < 0 ? -1 : 1) * pow(abs(sine), exponent))
    }
}

func squircleCGPath() -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: squirclePoints())
    path.closeSubpath()
    return path
}

func lowercaseDCGPath(_ geometry: LowercaseDGeometry) -> CGPath {
    let path = CGMutablePath()
    path.addEllipse(in: CGRect(x: -bowlRadius, y: -bowlRadius, width: bowlRadius * 2, height: bowlRadius * 2))
    let outline = roundedStemOutline(geometry)
    path.move(to: outline.start)
    for segment in outline.segments {
        path.addLine(to: segment.lineEnd)
        path.addArc(tangent1End: cornerTangentPoint(segment), tangent2End: segment.arcEnd, radius: cornerRounding / 2)
        path.addLine(to: segment.arcEnd)
    }
    path.closeSubpath()
    return path
}

/// The corner of the original (un-rounded) outline, where the two tangent lines of an arc meet.
func cornerTangentPoint(_ segment: RoundedOutlineSegment) -> CGPoint {
    let fromCenterToLineEnd = CGPoint(x: segment.lineEnd.x - segment.arcCenter.x, y: segment.lineEnd.y - segment.arcCenter.y)
    let fromCenterToArcEnd = CGPoint(x: segment.arcEnd.x - segment.arcCenter.x, y: segment.arcEnd.y - segment.arcCenter.y)
    let bisector = CGPoint(x: fromCenterToLineEnd.x + fromCenterToArcEnd.x, y: fromCenterToLineEnd.y + fromCenterToArcEnd.y)
    let bisectorLength = hypot(bisector.x, bisector.y)
    let radius = cornerRounding / 2
    let cosineOfHalfAngle = bisectorLength / (2 * radius)
    let distanceToCorner = radius / cosineOfHalfAngle
    return CGPoint(x: segment.arcCenter.x + bisector.x / bisectorLength * distanceToCorner,
                   y: segment.arcCenter.y + bisector.y / bisectorLength * distanceToCorner)
}

func makeBitmapContext(pixelSize: Int) -> CGContext {
    let context = CGContext(data: nil, width: pixelSize, height: pixelSize, bitsPerComponent: 8, bytesPerRow: 0,
                            space: sRGBColorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Flip to y-down so every coordinate matches the SVG/lab space.
    context.translateBy(x: 0, y: CGFloat(pixelSize))
    context.scaleBy(x: 1, y: -1)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    return context
}

func drawIcon(pixelSize: Int) -> CGImage {
    let usesSmallMaster = pixelSize <= 32
    let snapsToPixels = pixelSize <= 64
    let context = makeBitmapContext(pixelSize: pixelSize)
    let canvasScale = Double(pixelSize) / canvasSide
    let squircle = squircleCGPath()
    var canvasToPixels = CGAffineTransform(scaleX: canvasScale, y: canvasScale)
    let squircleInPixels = squircle.copy(using: &canvasToPixels)!
    let bodyTop = canvasSide / 2 - squircleSemiAxis, bodyBottom = canvasSide / 2 + squircleSemiAxis

    // Background gradient, clipped to the squircle.
    context.saveGState()
    context.scaleBy(x: canvasScale, y: canvasScale)
    context.addPath(squircle)
    context.clip()
    let backgroundGradient = CGGradient(colorsSpace: sRGBColorSpace,
                                        colors: [cgColor(hex: backgroundTopHex), cgColor(hex: backgroundBottomHex)] as CFArray,
                                        locations: [0, 1])!
    context.drawLinearGradient(backgroundGradient, start: CGPoint(x: 0, y: bodyTop), end: CGPoint(x: 0, y: bodyBottom), options: [])
    context.restoreGState()

    // Glyph, clipped to the squircle, in snapped pixel space.
    let placement = placeGlyphInIcon(outputPixelSize: pixelSize, usesSmallMaster: usesSmallMaster, snapsToPixels: snapsToPixels)
    context.saveGState()
    context.addPath(squircleInPixels)
    context.clip()
    context.translateBy(x: placement.offsetX, y: placement.offsetY)
    context.scaleBy(x: placement.pixelsPerGlyphUnit, y: placement.pixelsPerGlyphUnit)
    context.addPath(lowercaseDCGPath(placement.geometry))
    context.setFillColor(cgColor(hex: kleinBlueHex))
    context.fillPath(using: .winding)
    context.restoreGState()

    // Top sheen and hairline edge.
    context.saveGState()
    context.scaleBy(x: canvasScale, y: canvasScale)
    context.saveGState()
    context.addPath(squircle)
    context.clip()
    let sheenGradient = CGGradient(colorsSpace: sRGBColorSpace,
                                   colors: [cgColor(hex: "#FFFFFF", alpha: sheenTopOpacity), cgColor(hex: "#FFFFFF", alpha: 0)] as CFArray,
                                   locations: [0, 1])!
    context.drawLinearGradient(sheenGradient, start: CGPoint(x: 0, y: bodyTop),
                               end: CGPoint(x: 0, y: bodyTop + (bodyBottom - bodyTop) * sheenFadeEndFraction), options: [])
    context.restoreGState()
    context.addPath(squircle)
    context.setStrokeColor(cgColor(hex: "#000000", alpha: hairlineOpacity))
    context.setLineWidth(hairlineWidth)
    context.strokePath()
    context.restoreGState()

    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: 72, kCGImagePropertyDPIHeight: 72] as CFDictionary)
    precondition(CGImageDestinationFinalize(destination), "Could not write \(url.path)")
}

// MARK: - SVG output

func format(_ value: Double) -> String {
    let rounded = (value * 100).rounded() / 100
    return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.2f", rounded)
}

/// The d as fill-only SVG path data on the 1024 canvas (no transforms), at the flattened icon's size.
func lowercaseDSVGPathData() -> (bowl: String, stem: String) {
    let placement = placeGlyphInIcon(outputPixelSize: Int(canvasSide), usesSmallMaster: false, snapsToPixels: false)
    let scale = placement.pixelsPerGlyphUnit
    func canvasX(_ glyphX: Double) -> String { format(glyphX * scale + placement.offsetX) }
    func canvasY(_ glyphY: Double) -> String { format(glyphY * scale + placement.offsetY) }
    let radius = format(bowlRadius * scale)
    let bowl = "M \(canvasX(-bowlRadius)) \(canvasY(0)) A \(radius) \(radius) 0 1 0 \(canvasX(bowlRadius)) \(canvasY(0)) A \(radius) \(radius) 0 1 0 \(canvasX(-bowlRadius)) \(canvasY(0)) Z"
    let outline = roundedStemOutline(placement.geometry)
    let cornerRadius = format(cornerRounding / 2 * scale)
    var stem = "M \(canvasX(outline.start.x)) \(canvasY(outline.start.y))"
    for segment in outline.segments {
        stem += " L \(canvasX(segment.lineEnd.x)) \(canvasY(segment.lineEnd.y))"
        stem += " A \(cornerRadius) \(cornerRadius) 0 0 1 \(canvasX(segment.arcEnd.x)) \(canvasY(segment.arcEnd.y))"
    }
    stem += " Z"
    return (bowl, stem)
}

func squircleSVGPathData() -> String {
    "M " + squirclePoints(stepCount: 360).map { "\(format($0.x)) \(format($0.y))" }.joined(separator: " L ") + " Z"
}

func svgDocument(_ body: String) -> String {
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1024 1024\" width=\"1024\" height=\"1024\">\n\(body)\n</svg>\n"
}

func writeSVGs(to directory: URL) throws {
    let glyphPaths = lowercaseDSVGPathData()
    let squircle = squircleSVGPathData()
    let glyphBody = { (color: String) in
        "  <path d=\"\(glyphPaths.bowl)\" fill=\"\(color)\"/>\n  <path d=\"\(glyphPaths.stem)\" fill=\"\(color)\"/>"
    }

    let background = svgDocument("""
      <defs>
        <linearGradient id="background" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="\(backgroundTopHex)"/>
          <stop offset="1" stop-color="\(backgroundBottomHex)"/>
        </linearGradient>
      </defs>
      <rect width="1024" height="1024" fill="url(#background)"/>
    """)
    let glyph = svgDocument(glyphBody(kleinBlueHex))
    let glyphMono = svgDocument(glyphBody("#000000"))
    let flattened = svgDocument("""
      <defs>
        <linearGradient id="background" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="\(backgroundTopHex)"/>
          <stop offset="1" stop-color="\(backgroundBottomHex)"/>
        </linearGradient>
        <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#FFFFFF" stop-opacity="\(format(sheenTopOpacity))"/>
          <stop offset="\(format(sheenFadeEndFraction))" stop-color="#FFFFFF" stop-opacity="0"/>
        </linearGradient>
        <clipPath id="body"><path d="\(squircle)"/></clipPath>
      </defs>
      <path d="\(squircle)" fill="url(#background)"/>
      <g clip-path="url(#body)">
    \(glyphBody(kleinBlueHex))
      </g>
      <path d="\(squircle)" fill="url(#sheen)"/>
      <path d="\(squircle)" fill="none" stroke="#000000" stroke-opacity="\(format(hairlineOpacity))" stroke-width="\(format(hairlineWidth))"/>
    """)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try background.write(to: directory.appendingPathComponent("background.svg"), atomically: true, encoding: .utf8)
    try glyph.write(to: directory.appendingPathComponent("glyph.svg"), atomically: true, encoding: .utf8)
    try glyphMono.write(to: directory.appendingPathComponent("glyph-mono.svg"), atomically: true, encoding: .utf8)
    try flattened.write(to: directory.appendingPathComponent("icon-1024.svg"), atomically: true, encoding: .utf8)
}

// MARK: - Main

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write("usage: DottoIconBuild <png-output-directory> <svg-output-directory>\n".data(using: .utf8)!)
    exit(64)
}
let pngDirectory = URL(fileURLWithPath: arguments[1])
let svgDirectory = URL(fileURLWithPath: arguments[2])
try FileManager.default.createDirectory(at: pngDirectory, withIntermediateDirectories: true)
for pixelSize in [16, 32, 64, 128, 256, 512, 1024] {
    writePNG(drawIcon(pixelSize: pixelSize), to: pngDirectory.appendingPathComponent("icon_\(pixelSize).png"))
}
try writeSVGs(to: svgDirectory)

let unhinted = makeLowercaseDGeometry(hintPixelsPerGlyphUnit: nil)
let iconPlacement = placeGlyphInIcon(outputPixelSize: 1024, usesSmallMaster: false, snapsToPixels: false)
print("glyph units: bowl r \(bowlRadius), stem \(format(unhinted.stemLeft))…\(format(unhinted.stemRight)), top \(format(unhinted.stemTop)), baseline \(format(unhinted.stemBottom)), tip drop \(format(unhinted.tipDrop))")
print("icon fit \(String(format: "%.5f", iconPlacement.pixelsPerGlyphUnit)), translate \(format(iconPlacement.offsetX)) \(format(iconPlacement.offsetY))")
for pixelSize in [16, 32] {
    let placement = placeGlyphInIcon(outputPixelSize: pixelSize, usesSmallMaster: true, snapsToPixels: true)
    let scale = placement.pixelsPerGlyphUnit
    print("\(pixelSize) px hinted: stem \(format((placement.geometry.stemRight - placement.geometry.stemLeft) * scale)) px, overlap \(format((bowlRadius - placement.geometry.stemLeft) * scale)) px, tip drop \(format(placement.geometry.tipDrop * scale)) px, height \(format((placement.geometry.boundingBox.height) * scale)) px")
}
print("wrote PNGs to \(pngDirectory.path) and SVGs to \(svgDirectory.path)")
