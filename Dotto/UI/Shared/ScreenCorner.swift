import CoreGraphics
import SwiftUI

/// A corner of the screen, or of any rectangle in AppKit's coordinates (y grows upward, so "top" is maxY).
enum ScreenCorner: String, Codable, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    var userFacingName: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }

    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }

    var alignment: Alignment {
        switch self {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }

    func point(of appKitRect: CGRect) -> CGPoint {
        CGPoint(x: isLeft ? appKitRect.minX : appKitRect.maxX, y: isTop ? appKitRect.maxY : appKitRect.minY)
    }

    /// The frame of this size whose corner sits at `cornerPoint`, so a panel that grows or shrinks keeps this
    /// corner where it was.
    func frame(ofSize size: CGSize, keepingCornerAt cornerPoint: CGPoint) -> CGRect {
        CGRect(x: isLeft ? cornerPoint.x : cornerPoint.x - size.width,
               y: isTop ? cornerPoint.y - size.height : cornerPoint.y,
               width: size.width, height: size.height)
    }
}
