import SwiftUI

/// The small pointer on the edge of a card that belongs to the cursor (the checklist popover), aimed at the cursor.
/// It overlaps the card by a point so the card's border doesn't show across its base.
struct AttachedPanelTailView: View {
    let pointsUp: Bool

    private static let overlapIntoCard: CGFloat = 1

    var body: some View {
        ZStack {
            AttachedPanelTailShape(pointsUp: pointsUp, closesBase: true)
                .fill(DesignSystem.Colors.background)
            AttachedPanelTailShape(pointsUp: pointsUp, closesBase: false)
                .stroke(DesignSystem.Colors.borderSubtle, style: StrokeStyle(lineWidth: 1, lineJoin: .round))
        }
        .frame(width: AttachedPanelPlacementCalculator.tailWidth,
               height: AttachedPanelPlacementCalculator.tailLength + Self.overlapIntoCard)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A triangle whose tip is at the top (or bottom) middle of its rect. Without `closesBase` it is only the two slanted
/// sides, for the outline.
private struct AttachedPanelTailShape: Shape {
    let pointsUp: Bool
    let closesBase: Bool

    func path(in rect: CGRect) -> Path {
        let tipY = pointsUp ? rect.minY : rect.maxY
        let baseY = pointsUp ? rect.maxY : rect.minY
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: baseY))
        path.addLine(to: CGPoint(x: rect.midX, y: tipY))
        path.addLine(to: CGPoint(x: rect.maxX, y: baseY))
        if closesBase { path.closeSubpath() }
        return path
    }
}
