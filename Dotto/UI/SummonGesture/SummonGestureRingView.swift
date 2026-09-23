import Combine
import SwiftUI

/// What the ring shows while the user circles the pointer.
@MainActor
final class SummonGestureRingViewModel: ObservableObject {
    /// 0…1 of the loops needed.
    @Published var progress: Double = 0
    @Published var glyphVisible = false
    @Published var ringOpacity: Double = 1
    /// The fire pulse: the full ring grows to 1.45× and fades out.
    @Published var isFiring = false
    @Published var taskColor: Color = .orange
}

/// The cursor lab's gesture ring: a 26 pt circle in a 60 pt box (30 pt radius to the outer edge of the stroke), a
/// 3.5 pt task-color track at 22% opacity, the progress arc from 12 o'clock clockwise with round caps, and "↻" at the
/// top right once the loop is nearly done.
struct SummonGestureRingView: View {
    @ObservedObject var viewModel: SummonGestureRingViewModel

    static let boxSideLength: CGFloat = 60
    private static let circleRadius: CGFloat = 26
    private static let strokeWidth: CGFloat = 3.5
    static let firePulseScale: CGFloat = 1.45
    static let firePulseDuration: Double = 0.42

    var body: some View {
        ZStack {
            Circle()
                .stroke(viewModel.taskColor.opacity(0.22), lineWidth: Self.strokeWidth)
                .frame(width: Self.circleRadius * 2, height: Self.circleRadius * 2)
            Circle()
                .trim(from: 0, to: CGFloat(min(1, max(0, viewModel.progress))))
                .stroke(viewModel.taskColor, style: StrokeStyle(lineWidth: Self.strokeWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: Self.circleRadius * 2, height: Self.circleRadius * 2)
                .animation(.linear(duration: 0.06), value: viewModel.progress)
            Text("↻")
                .font(.system(size: 13, weight: .heavy))
                .foregroundColor(viewModel.taskColor)
                .opacity(viewModel.glyphVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: viewModel.glyphVisible)
                // The lab pins the glyph 4 pt past the box's right edge and 6 pt above its top.
                .frame(width: Self.boxSideLength, height: Self.boxSideLength, alignment: .topTrailing)
                .offset(x: 4, y: -6)
        }
        .frame(width: Self.boxSideLength, height: Self.boxSideLength)
        .scaleEffect(viewModel.isFiring ? Self.firePulseScale : 1)
        .opacity(viewModel.isFiring ? 0 : viewModel.ringOpacity)
        .animation(.linear(duration: 0.06), value: viewModel.ringOpacity)
        .accessibilityHidden(true)
    }
}
