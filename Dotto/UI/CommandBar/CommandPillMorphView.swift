import SwiftUI

/// The command pill turning into the cursor's status pill after Return, drawn in a click-through panel that never
/// takes the keyboard. One capsule changes shape the whole time, on the morph spring: its size, its corners and its
/// fill go from the command pill's to the status pill's around the edge that faces the cursor's tip, and it casts the
/// status pill's own shadow throughout. Inside it the submitted text and the hint leave first, then the status text and
/// buttons arrive (`CommandPillMorphTimeline`), so the two texts are never both readable. Its last frame is drawn
/// exactly as the real status pill is, which then takes its place. The buttons here are a picture; they can't be
/// clicked.
struct CommandPillMorphView: View {
    let canvasSize: CGSize
    let capsuleFrameInCanvas: CGRect
    /// The capsule, and the sides of the tip it hung on, in the canvas's points.
    let commandPillHandoffInCanvas: CommandPillHandoff
    /// Where the real status pill waits to take over, in the canvas's points; the morph ends on it.
    let heldStatusPillFrameInCanvas: CGRect
    let submittedCommandText: String
    let taskColor: Color
    @ObservedObject var cursorViewModel: CursorViewModel
    let onMorphFinished: () -> Void

    static let timeline = CommandPillMorphTimeline.standard

    @State private var outgoingContentIsVisible = true
    @State private var capsuleHasMorphed = false
    @State private var incomingContentIsVisible = false
    @State private var capsuleHasSettled = false
    @State private var incomingContentHasArrived = false
    @State private var hasFinished = false
    /// The status pill's size on screen; it follows the pill if its text changes during the morph.
    @State private var statusPillSize: CGSize?

    private var cursorScale: CGFloat { CGFloat(cursorViewModel.styleConfiguration.cursorScale) }

    private var statusPillFrameInCanvas: CGRect {
        commandPillHandoffInCanvas.statusPillFrame(forStatusPillSize: statusPillSize ?? heldStatusPillFrameInCanvas.size,
                                                   heldStatusPillFrame: heldStatusPillFrameInCanvas)
    }

    var body: some View {
        let statusPillFrame = statusPillFrameInCanvas
        let morphingCapsuleFrame = capsuleHasMorphed ? statusPillFrame : capsuleFrameInCanvas
        let morphingCornerRadius = capsuleHasMorphed ? CursorPillChrome.cornerRadius * cursorScale : CommandPillView.capsuleHeight / 2
        let morphingShadowScale = capsuleHasMorphed ? cursorScale : 1
        let morphingCapsuleShape = RoundedRectangle(cornerRadius: morphingCornerRadius, style: .continuous)
        ZStack(alignment: .topLeading) {
            Color.clear

            morphingCapsuleShape
                .fill(capsuleHasMorphed
                      ? cursorViewModel.styleConfiguration.stateColor(for: cursorViewModel.appearance.activity)
                      : taskColor)
                .shadow(color: CursorPillChrome.shadowColor, radius: CursorPillChrome.shadowRadius * morphingShadowScale,
                        x: 0, y: CursorPillChrome.shadowOffsetY * morphingShadowScale)
                .frame(width: morphingCapsuleFrame.width, height: morphingCapsuleFrame.height)
                .offset(x: morphingCapsuleFrame.minX, y: morphingCapsuleFrame.minY)

            CommandPillCapsuleContent {
                Text(submittedCommandText)
                    .lineLimit(1)
                    // A field scrolled to its end shows the end of a long command.
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .offset(x: capsuleFrameInCanvas.minX, y: capsuleFrameInCanvas.minY)
            .opacity(outgoingContentIsVisible ? 1 : 0)
            .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
            .mask(alignment: .topLeading) {
                morphingCapsuleShape
                    .frame(width: morphingCapsuleFrame.width, height: morphingCapsuleFrame.height)
                    .offset(x: morphingCapsuleFrame.minX, y: morphingCapsuleFrame.minY)
            }

            CommandPillHintChip()
                .offset(x: capsuleFrameInCanvas.minX + CommandPillView.hintLeadingInset,
                        y: capsuleFrameInCanvas.maxY + CommandPillView.hintSpacing)
                .opacity(outgoingContentIsVisible ? 1 : 0)

            DecisionPill(viewModel: cursorViewModel, onDecisionOptionChosen: { _, _ in }, onToggleChecklist: {},
                         drawsPillBackground: false)
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { geometryProxy in geometryProxy.size } action: { unscaledPillSize in
                    followStatusPillSize(CGSize(width: unscaledPillSize.width * cursorScale,
                                                height: unscaledPillSize.height * cursorScale))
                }
                .allowsHitTesting(false)
                .offset(x: statusPillFrame.minX, y: statusPillFrame.minY)
                .opacity(incomingContentIsVisible ? 1 : 0)
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
        .onAppear(perform: startMorph)
    }

    private func startMorph() {
        let timeline = Self.timeline
        withAnimation(DesignSystem.Motion.contentFade(durationSeconds: timeline.outgoingContentFadeDurationSeconds)
            .delay(timeline.outgoingContentFadeStartSeconds)) {
            outgoingContentIsVisible = false
        }
        withAnimation(DesignSystem.Motion.morph.delay(timeline.capsuleMorphStartSeconds)) {
            capsuleHasMorphed = true
        } completion: {
            capsuleHasSettled = true
            finishWhenEveryStageIsDone()
        }
        withAnimation(DesignSystem.Motion.contentFade(durationSeconds: timeline.incomingContentFadeDurationSeconds)
            .delay(timeline.incomingContentFadeStartSeconds)) {
            incomingContentIsVisible = true
        } completion: {
            incomingContentHasArrived = true
            finishWhenEveryStageIsDone()
        }
    }

    /// The status text changed while the morph runs: the capsule follows the new size on the resize spring.
    private func followStatusPillSize(_ measuredStatusPillSize: CGSize) {
        guard !measuredStatusPillSize.isNearlyEqual(to: statusPillSize ?? heldStatusPillFrameInCanvas.size) else { return }
        withAnimation(DesignSystem.Motion.resize) {
            statusPillSize = measuredStatusPillSize
        }
    }

    /// The one place the handoff is triggered: once the capsule has come to rest and the status text has arrived.
    private func finishWhenEveryStageIsDone() {
        guard capsuleHasSettled, incomingContentHasArrived, !hasFinished else { return }
        hasFinished = true
        onMorphFinished()
    }
}
