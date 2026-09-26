import Foundation
import CoreGraphics

/// Decides which elements of a snapshot get a mark on the screenshot of the same window, and where each box and label
/// goes in image pixels. Only elements the outline also calls interactive are marked, so every marked id is one the
/// model could have clicked from the outline.
enum ScreenshotMarkLayoutCalculator {
    /// AX frames and the captured window frame are read a moment apart; a window that moved less than this is the same.
    static let windowFrameTolerancePoints: CGFloat = 2
    /// Containers that are never marked themselves: a click on them hits whatever is inside.
    private static let neverMarkedRoles: Set<String> = AccessibilityRoleTraits.visibleAreaClippingRoles
        .union(["AXApplication", "AXSplitGroup", "AXToolbar", "AXMenuBar", "AXTable", "AXOutline", "AXList", "AXBrowser"])

    private struct MarkCandidate {
        var node: AccessibilityElementNode
        var visibleFrameInTopLeftGlobalPoints: CGRect
        var documentOrderIndex: Int
    }

    static func layOutMarks(for snapshot: AccessibilityTreeSnapshot, capturedWindowFrameInTopLeftGlobalPoints: CGRect,
                            imagePixelSize: CGSize, occludingFramesInTopLeftGlobalPoints: [CGRect],
                            labelMetrics: ScreenshotLabelMetrics, limits: ScreenshotMarkLimits) -> ScreenshotMarkLayout {
        guard capturedWindowFrameInTopLeftGlobalPoints.width > 0, capturedWindowFrameInTopLeftGlobalPoints.height > 0,
              imagePixelSize.width > 0, imagePixelSize.height > 0 else { return .unavailable(.windowChangedDuringCapture) }
        if let outlinedWindowFrame = snapshot.rootNodes.first?.frameInTopLeftGlobalPoints,
           !framesMatch(outlinedWindowFrame, capturedWindowFrameInTopLeftGlobalPoints) {
            return .unavailable(.windowChangedDuringCapture)
        }

        var markableRootNodes = snapshot.rootNodes
        var initialClipFrame = capturedWindowFrameInTopLeftGlobalPoints
        if let sheetNode = firstNode(in: snapshot.rootNodes, where: { AccessibilityRoleTraits.modalContainerRoles.contains($0.role) }) {
            markableRootNodes = [sheetNode]
            if let sheetFrame = sheetNode.frameInTopLeftGlobalPoints { initialClipFrame = initialClipFrame.intersection(sheetFrame) }
        }

        var candidates: [MarkCandidate] = []
        var documentOrderIndex = 0
        for rootNode in markableRootNodes {
            collectCandidates(from: rootNode, clipFrame: initialClipFrame, isInsideCandidateRow: false,
                              occludingFrames: occludingFramesInTopLeftGlobalPoints, limits: limits,
                              documentOrderIndex: &documentOrderIndex, into: &candidates)
        }

        let distinctCandidates = removingDuplicateBoxes(candidates, limits: limits)
        let orderedCandidates = distinctCandidates.sorted(by: comesBefore)
        let markedCandidates = Array(orderedCandidates.prefix(limits.maximumMarkCount))

        var marks: [ScreenshotMark] = []
        var placedLabelRects: [CGRect] = []
        for (markIndex, markedCandidate) in markedCandidates.enumerated() {
            let boxInImagePixels = imagePixelRect(fromTopLeftGlobalRect: markedCandidate.visibleFrameInTopLeftGlobalPoints,
                                                  windowFrameInTopLeftGlobalPoints: capturedWindowFrameInTopLeftGlobalPoints,
                                                  imagePixelSize: imagePixelSize)
            let labelRect = placeLabel(size: labelMetrics.labelSize(for: markedCandidate.node.elementIdentifier),
                                       besideBox: boxInImagePixels, imagePixelSize: imagePixelSize, placedLabelRects: placedLabelRects)
            placedLabelRects.append(labelRect)
            marks.append(ScreenshotMark(elementIdentifier: markedCandidate.node.elementIdentifier, boxInImagePixels: boxInImagePixels,
                                        labelRectInImagePixels: labelRect,
                                        paletteIndex: markIndex % ScreenshotMark.paletteColorCount))
        }
        return ScreenshotMarkLayout(marks: marks, unmarkedCandidateCount: orderedCandidates.count - markedCandidates.count,
                                    unavailableReason: nil)
    }

    /// Rounds outward so a box never cuts into the element, and clamps to the image.
    static func imagePixelRect(fromTopLeftGlobalRect topLeftGlobalRect: CGRect, windowFrameInTopLeftGlobalPoints: CGRect,
                               imagePixelSize: CGSize) -> CGRect {
        let horizontalPixelsPerPoint = imagePixelSize.width / windowFrameInTopLeftGlobalPoints.width
        let verticalPixelsPerPoint = imagePixelSize.height / windowFrameInTopLeftGlobalPoints.height
        let minimumX = ((topLeftGlobalRect.minX - windowFrameInTopLeftGlobalPoints.minX) * horizontalPixelsPerPoint).rounded(.down)
        let minimumY = ((topLeftGlobalRect.minY - windowFrameInTopLeftGlobalPoints.minY) * verticalPixelsPerPoint).rounded(.down)
        let maximumX = ((topLeftGlobalRect.maxX - windowFrameInTopLeftGlobalPoints.minX) * horizontalPixelsPerPoint).rounded(.up)
        let maximumY = ((topLeftGlobalRect.maxY - windowFrameInTopLeftGlobalPoints.minY) * verticalPixelsPerPoint).rounded(.up)
        let unclampedRect = CGRect(x: minimumX, y: minimumY, width: maximumX - minimumX, height: maximumY - minimumY)
        let clampedRect = unclampedRect.intersection(CGRect(origin: .zero, size: imagePixelSize))
        return clampedRect.isNull ? .zero : clampedRect
    }

    // MARK: - Candidates

    private static func collectCandidates(from node: AccessibilityElementNode, clipFrame: CGRect, isInsideCandidateRow: Bool,
                                          occludingFrames: [CGRect], limits: ScreenshotMarkLimits,
                                          documentOrderIndex: inout Int, into candidates: inout [MarkCandidate]) {
        documentOrderIndex += 1
        var childClipFrame = clipFrame
        if AccessibilityRoleTraits.visibleAreaClippingRoles.contains(node.role), let nodeFrame = node.frameInTopLeftGlobalPoints {
            childClipFrame = clipFrame.intersection(nodeFrame)
        }

        var nodeIsCandidate = false
        // A row's mark already covers its cells: marking both would stack two labels on every row.
        let isCellCoveredByItsRow = isInsideCandidateRow && node.role == "AXCell"
        if !neverMarkedRoles.contains(node.role), !isCellCoveredByItsRow, node.isEnabled,
           AccessibilityRoleTraits.isInteractive(node), let nodeFrame = node.frameInTopLeftGlobalPoints,
           nodeFrame.width >= 1, nodeFrame.height >= 1 {
            let visibleFrame = nodeFrame.intersection(clipFrame)
            if isVisibleEnough(visibleFrame, of: nodeFrame, occludingFrames: occludingFrames, limits: limits) {
                candidates.append(MarkCandidate(node: node, visibleFrameInTopLeftGlobalPoints: visibleFrame,
                                                documentOrderIndex: documentOrderIndex))
                nodeIsCandidate = true
            }
        }

        guard !childClipFrame.isNull, !childClipFrame.isEmpty else { return }
        let childrenAreInsideCandidateRow = isInsideCandidateRow || (nodeIsCandidate && node.role == "AXRow")
        for childNode in node.children {
            collectCandidates(from: childNode, clipFrame: childClipFrame, isInsideCandidateRow: childrenAreInsideCandidateRow,
                              occludingFrames: occludingFrames, limits: limits,
                              documentOrderIndex: &documentOrderIndex, into: &candidates)
        }
    }

    private static func isVisibleEnough(_ visibleFrame: CGRect, of nodeFrame: CGRect, occludingFrames: [CGRect],
                                        limits: ScreenshotMarkLimits) -> Bool {
        guard !visibleFrame.isNull, visibleFrame.width >= limits.minimumVisibleSideInPoints,
              visibleFrame.height >= limits.minimumVisibleSideInPoints else { return false }
        let visibleFraction = (visibleFrame.width * visibleFrame.height) / (nodeFrame.width * nodeFrame.height)
        guard visibleFraction >= limits.minimumVisibleFraction else { return false }
        let visibleCenter = CGPoint(x: visibleFrame.midX, y: visibleFrame.midY)
        return !occludingFrames.contains { $0.contains(visibleCenter) }
    }

    /// Greedy in priority order, so of two boxes on the same spot the control the user would aim at keeps its mark,
    /// and on a tie the ancestor (earlier in document order) does.
    private static func removingDuplicateBoxes(_ candidates: [MarkCandidate], limits: ScreenshotMarkLimits) -> [MarkCandidate] {
        let candidatesByPriority = candidates.sorted { firstCandidate, secondCandidate in
            let firstRank = AccessibilityRoleTraits.markPriorityRank(of: firstCandidate.node)
            let secondRank = AccessibilityRoleTraits.markPriorityRank(of: secondCandidate.node)
            if firstRank != secondRank { return firstRank < secondRank }
            return firstCandidate.documentOrderIndex < secondCandidate.documentOrderIndex
        }
        var keptCandidates: [MarkCandidate] = []
        for candidate in candidatesByPriority {
            let duplicatesAKeptBox = keptCandidates.contains { keptCandidate in
                intersectionOverUnion(candidate.visibleFrameInTopLeftGlobalPoints,
                                      keptCandidate.visibleFrameInTopLeftGlobalPoints) >= limits.duplicateBoxOverlapRatio
            }
            if !duplicatesAKeptBox { keptCandidates.append(candidate) }
        }
        return keptCandidates
    }

    /// The focused element first (it is where typing goes), then by priority, then in reading order.
    private static func comesBefore(_ firstCandidate: MarkCandidate, _ secondCandidate: MarkCandidate) -> Bool {
        if firstCandidate.node.isFocused != secondCandidate.node.isFocused { return firstCandidate.node.isFocused }
        let firstRank = AccessibilityRoleTraits.markPriorityRank(of: firstCandidate.node)
        let secondRank = AccessibilityRoleTraits.markPriorityRank(of: secondCandidate.node)
        if firstRank != secondRank { return firstRank < secondRank }
        let firstFrame = firstCandidate.visibleFrameInTopLeftGlobalPoints
        let secondFrame = secondCandidate.visibleFrameInTopLeftGlobalPoints
        if firstFrame.minY != secondFrame.minY { return firstFrame.minY < secondFrame.minY }
        if firstFrame.minX != secondFrame.minX { return firstFrame.minX < secondFrame.minX }
        return firstCandidate.documentOrderIndex < secondCandidate.documentOrderIndex
    }

    // MARK: - Labels

    /// Tries above the box, inside its top-left corner, below it, then inside its top-right corner, and takes the first
    /// spot that stays in the image and clear of labels already placed. Crowded spots fall back to inside top-left.
    private static func placeLabel(size labelSize: CGSize, besideBox boxInImagePixels: CGRect, imagePixelSize: CGSize,
                                   placedLabelRects: [CGRect]) -> CGRect {
        let imageRect = CGRect(origin: .zero, size: imagePixelSize)
        let candidateOrigins = [
            CGPoint(x: boxInImagePixels.minX, y: boxInImagePixels.minY - labelSize.height),
            CGPoint(x: boxInImagePixels.minX, y: boxInImagePixels.minY),
            CGPoint(x: boxInImagePixels.minX, y: boxInImagePixels.maxY),
            CGPoint(x: boxInImagePixels.maxX - labelSize.width, y: boxInImagePixels.minY),
        ]
        for candidateOrigin in candidateOrigins {
            let candidateRect = CGRect(origin: candidateOrigin, size: labelSize)
            if imageRect.contains(candidateRect), !placedLabelRects.contains(where: { $0.intersects(candidateRect) }) {
                return candidateRect
            }
        }
        let clampedX = min(max(0, boxInImagePixels.minX), max(0, imagePixelSize.width - labelSize.width))
        let clampedY = min(max(0, boxInImagePixels.minY), max(0, imagePixelSize.height - labelSize.height))
        return CGRect(origin: CGPoint(x: clampedX, y: clampedY), size: labelSize)
    }

    // MARK: - Geometry

    private static func framesMatch(_ firstFrame: CGRect, _ secondFrame: CGRect) -> Bool {
        abs(firstFrame.minX - secondFrame.minX) <= windowFrameTolerancePoints
            && abs(firstFrame.minY - secondFrame.minY) <= windowFrameTolerancePoints
            && abs(firstFrame.width - secondFrame.width) <= windowFrameTolerancePoints
            && abs(firstFrame.height - secondFrame.height) <= windowFrameTolerancePoints
    }

    private static func intersectionOverUnion(_ firstRect: CGRect, _ secondRect: CGRect) -> CGFloat {
        let intersection = firstRect.intersection(secondRect)
        guard !intersection.isNull else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = firstRect.width * firstRect.height + secondRect.width * secondRect.height - intersectionArea
        return unionArea > 0 ? intersectionArea / unionArea : 0
    }

    private static func firstNode(in nodes: [AccessibilityElementNode],
                                  where predicate: (AccessibilityElementNode) -> Bool) -> AccessibilityElementNode? {
        for node in nodes {
            if predicate(node) { return node }
            if let matchingDescendant = firstNode(in: node.children, where: predicate) { return matchingDescendant }
        }
        return nil
    }
}
