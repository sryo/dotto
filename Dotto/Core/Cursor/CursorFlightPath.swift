import Foundation
import CoreGraphics

/// The cursor's arc to its next target, from the owner-approved prototype: a quadratic bezier whose control point
/// sits off the chord's midpoint, always toward the top of the screen, eased in and out. Points are in a top-left
/// coordinate space (y grows downward), like the overlay's window-relative points.
struct CursorFlightPath: Equatable, Sendable {
    let startPoint: CGPoint
    let endPoint: CGPoint
    let bezierControlPoint: CGPoint
    /// clamp(distance / 1400, 0.3, 0.8) seconds divided by the motion speed; 0 when the distance is ≤ 1 point.
    let durationSeconds: Double

    init(startPoint: CGPoint, endPoint: CGPoint, motionSpeed: Double = 1) {
        self.startPoint = startPoint
        self.endPoint = endPoint
        let deltaX = endPoint.x - startPoint.x
        let deltaY = endPoint.y - startPoint.y
        let distance = hypot(deltaX, deltaY)
        durationSeconds = distance <= 1 ? 0 : min(max(distance / 1400, 0.3), 0.8) / max(motionSpeed, 0.01)
        guard distance > 0 else {
            bezierControlPoint = startPoint
            return
        }
        // The unit normal of the chord, flipped when needed so it points toward the top of the screen (negative y).
        var normalX = -deltaY / distance
        var normalY = deltaX / distance
        if normalY > 0 {
            normalX = -normalX
            normalY = -normalY
        }
        let arcHeight = min(distance * 0.22, 70)
        bezierControlPoint = CGPoint(x: (startPoint.x + endPoint.x) / 2 + normalX * arcHeight,
                                     y: (startPoint.y + endPoint.y) / 2 + normalY * arcHeight)
    }

    func point(atLinearProgress linearProgress: Double) -> CGPoint {
        let easedProgress = Self.easedProgress(linearProgress)
        let remainingProgress = 1 - easedProgress
        // Quadratic bezier: B(p) = (1−p)²·P0 + 2(1−p)p·P1 + p²·P2
        return CGPoint(
            x: remainingProgress * remainingProgress * startPoint.x + 2 * remainingProgress * easedProgress * bezierControlPoint.x
                + easedProgress * easedProgress * endPoint.x,
            y: remainingProgress * remainingProgress * startPoint.y + 2 * remainingProgress * easedProgress * bezierControlPoint.y
                + easedProgress * easedProgress * endPoint.y)
    }

    /// Ease-in-out cubic: 4p³ for the first half, 1 − (−2p + 2)³ / 2 for the second.
    private static func easedProgress(_ linearProgress: Double) -> CGFloat {
        let progress = min(max(linearProgress, 0), 1)
        return CGFloat(progress < 0.5 ? 4 * progress * progress * progress : 1 - pow(-2 * progress + 2, 3) / 2)
    }
}
