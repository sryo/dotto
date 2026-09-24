import SwiftUI

/// Dotto's own cursor: a colored arrow that morphs into what Dotto is doing (a reading ring, a thinking ring, an
/// I-beam, a progress ring, a question dot, a check) with a status pill beside the tip. The view's origin is the
/// arrow tip; surfaces place it with an offset and never clip it.
struct CursorView: View {
    let appearance: CursorAppearance
    let configuration: CursorStyleConfiguration
    /// False inside the live view and while the clickable pill panel shows the pill instead. The pill drawn here
    /// never takes clicks, so it carries no answers or Stop that could be clicked.
    let showsPill: Bool
    /// The visible frame of the tip's screen in this view's points (the tip at the origin, before the cursor's scale).
    /// Near its edges the pill flips to the left of or above the tip; nil keeps it below and to the right.
    var pillRoomAroundTip: CGRect? = nil
    /// False while the window drawing this cursor isn't the surface on screen. An ordered-out window keeps rendering
    /// a running per-frame timeline, which kept Dotto at full CPU after a task ended in the waiting or ring states.
    var isOnShownSurface: Bool = true

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var ringRotationAccumulator = CursorRingRotationAccumulator()
    @State private var measuredPillSize: CGSize = .zero
    @State private var animationStartDate = Date()

    private var reducesMotion: Bool { configuration.reducesMotion(systemReduceMotion: systemReduceMotion) }
    private var activity: CursorActivity { appearance.activity }
    private var stateColor: Color { configuration.stateColor(for: activity) }

    private var ringTextIsVisible: Bool {
        configuration.statusStyle == .ring || activity == .reading || activity == .thinking
    }

    private var ringTextDegreesPerSecond: Double {
        guard !reducesMotion else { return 0 }
        let baseDegreesPerSecond: Double
        switch activity {
        case .thinking: baseDegreesPerSecond = 42
        case .reading: baseDegreesPerSecond = 26
        default: baseDegreesPerSecond = configuration.statusStyle == .ring ? 9 : 0
        }
        return baseDegreesPerSecond * configuration.motionSpeed
    }

    private var needsPerFrameUpdates: Bool {
        guard !reducesMotion, isOnShownSurface else { return false }
        return (ringTextIsVisible && ringTextDegreesPerSecond > 0) || activity == .waiting
    }

    private func animation(_ animation: Animation) -> Animation? {
        reducesMotion ? nil : animation.speed(configuration.motionSpeed)
    }

    var body: some View {
        let shakeIsSuppressed = reducesMotion
        return TimelineView(.animation(minimumInterval: nil, paused: !needsPerFrameUpdates)) { timelineContext in
            ZStack(alignment: .topLeading) {
                layerBox(frameDate: timelineContext.date)
                    .offset(x: -CursorLayerBox.tipOffset, y: -CursorLayerBox.tipOffset)
                    .keyframeAnimator(initialValue: CGFloat(0), trigger: appearance.errorShakeCount) { shakenLayerBox, horizontalShake in
                        shakenLayerBox.offset(x: shakeIsSuppressed ? 0 : horizontalShake)
                    } keyframes: { _ in
                        KeyframeTrack {
                            LinearKeyframe(-4, duration: 0.09)
                            LinearKeyframe(4, duration: 0.09)
                            LinearKeyframe(-3, duration: 0.09)
                            LinearKeyframe(2, duration: 0.09)
                            LinearKeyframe(0, duration: 0.09)
                        }
                    }

                if !reducesMotion {
                    CursorClickRipple(color: configuration.taskAccentColor, rippleCount: appearance.clickRippleCount)
                }

                if showsPill {
                    CursorPillView(appearance: appearance, configuration: configuration,
                                        reducesMotion: reducesMotion, onPillDecision: { _ in })
                        .onGeometryChange(for: CGSize.self) { geometryProxy in geometryProxy.size } action: { pillSize in
                            measuredPillSize = pillSize
                        }
                        .offset(pillOffsetFromTip)
                        .opacity(pillIsShown ? 1 : 0)
                        .scaleEffect(pillIsShown || reducesMotion ? 1 : DesignSystem.Motion.appearScale, anchor: .topLeading)
                        .animation(DesignSystem.Motion.appearOrFade(reducesMotion: reducesMotion), value: pillIsShown)
                        .animation(animation(DesignSystem.Motion.resize), value: activity)
                }
            }
            .frame(width: 1, height: 1, alignment: .topLeading)
        }
        .scaleEffect(configuration.cursorScale, anchor: .topLeading)
    }

    private var pillOffsetFromTip: CGSize {
        guard let pillRoomAroundTip, measuredPillSize.width > 0, measuredPillSize.height > 0 else {
            return activity.pillOffsetFromTip
        }
        return PillPlacementCalculator()
            .placement(forPillSize: measuredPillSize, tipPoint: .zero, preferredOffsetFromTip: activity.pillOffsetFromTip,
                       visibleFrame: pillRoomAroundTip)
            .offsetFromTip(.zero)
    }

    private var pillIsShown: Bool {
        !appearance.decisionOptions.isEmpty || appearance.statusStyleShowsTextOnlyPill(configuration.statusStyle)
    }

    // MARK: Morph layers

    private func layerBox(frameDate: Date) -> some View {
        let fadeAnimation = animation(.easeInOut(duration: 0.22))
        return ZStack(alignment: .topLeading) {
            haloLayer(frameDate: frameDate)
                .fadedIn(activity == .waiting, animation: fadeAnimation, value: activity)

            ringLayer
            ringTextLayer(frameDate: frameDate)
                .fadedIn(ringTextIsVisible, animation: fadeAnimation, value: ringTextIsVisible)

            replayProgressLayer
                .fadedIn(activity == .replaying, animation: fadeAnimation, value: activity)

            arrowLayer

            CursorIBeamShape()
                .stroke(stateColor, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                .frame(width: 24, height: 24)
                .position(CursorLayerBox.position(ofCursorPoint: .zero))
                .fadedIn(activity == .typing, animation: fadeAnimation, value: activity)

            Text("?")
                .font(.system(size: 13, weight: .heavy))
                .foregroundColor(.white)
                .position(CursorLayerBox.position(ofCursorPoint: CGPoint(x: 0, y: 0.5)))
                .fadedIn(activity == .waiting, animation: fadeAnimation, value: activity)

            CursorCheckmarkShape()
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                .frame(width: 16, height: 16)
                .position(CursorLayerBox.position(ofCursorPoint: .zero))
                .fadedIn(activity == .done, animation: fadeAnimation, value: activity)
        }
        .frame(width: CursorLayerBox.sideLength, height: CursorLayerBox.sideLength, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private var arrowLayer: some View {
        let arrowScale: CGFloat = activity.showsArrow ? (activity == .clicking ? 0.8 : 1) : 0.35
        // Paused is a hollow arrow: the fill takes the window color and the stroke keeps the task color.
        let arrowFill: Color = activity == .paused ? Color(nsColor: .windowBackgroundColor) : stateColor
        return ZStack {
            CursorArrowShape().fill(arrowFill)
            CursorArrowShape().stroke(stateColor, style: StrokeStyle(lineWidth: 2.4, lineJoin: .round))
        }
        .frame(width: 20, height: 20)
        .scaleEffect(arrowScale, anchor: UnitPoint(x: 0.075, y: 0.075))
        .opacity(activity.showsArrow ? 1 : 0)
        .shadow(color: Color.black.opacity(0.18), radius: 2, x: 0, y: 1)
        .position(x: CursorLayerBox.tipOffset + 10, y: CursorLayerBox.tipOffset + 10)
        .animation(animation(.spring(response: 0.34, dampingFraction: 0.55)), value: activity)
    }

    private var ringLayer: some View {
        let ringRadius = activity.ringRadius
        let ringStrokeStyle = activity == .reading
            ? StrokeStyle(lineWidth: 2, dash: [3, 5])
            : StrokeStyle(lineWidth: 2.6)
        return ZStack {
            Circle().fill(stateColor).opacity(activity.fillsRing ? 1 : 0)
            Circle().stroke(stateColor, style: ringStrokeStyle)
        }
        .frame(width: ringRadius * 2, height: ringRadius * 2)
        .position(CursorLayerBox.position(ofCursorPoint: .zero))
        .opacity(activity.showsRing ? 1 : 0)
        .animation(animation(.spring(response: 0.38, dampingFraction: 0.6)), value: activity)
    }

    private func haloLayer(frameDate: Date) -> some View {
        // A filled disc that grows from 11 to 27 points and fades from 40% to 0 every 1.5 s (ease-out).
        let haloPeriodSeconds = 1.5 / max(configuration.motionSpeed, 0.1)
        let elapsedSeconds = frameDate.timeIntervalSince(animationStartDate)
        let linearPhase = elapsedSeconds.truncatingRemainder(dividingBy: haloPeriodSeconds) / haloPeriodSeconds
        let easedPhase = 1 - (1 - linearPhase) * (1 - linearPhase)
        let haloRadius: CGFloat = reducesMotion ? 20 : 11 + 16 * CGFloat(easedPhase)
        let haloOpacity: Double = reducesMotion ? 0.25 : 0.4 * (1 - easedPhase)
        return Circle()
            .fill(stateColor)
            .frame(width: haloRadius * 2, height: haloRadius * 2)
            .opacity(haloOpacity)
            .position(CursorLayerBox.position(ofCursorPoint: .zero))
    }

    private func ringTextLayer(frameDate: Date) -> some View {
        let ringCenterInCursorPoints: CGPoint
        let minimumRadius: CGFloat
        let label: String
        let usesRingStyle = configuration.statusStyle == .ring
        switch activity {
        case .reading:
            label = usesRingStyle ? appearance.pillText : appearance.readingRingText
            minimumRadius = 31
            ringCenterInCursorPoints = .zero
        case .thinking:
            label = usesRingStyle ? appearance.pillText : "thinking · thinking · thinking"
            minimumRadius = 21
            ringCenterInCursorPoints = .zero
        case .waiting, .done, .error:
            label = appearance.pillText
            minimumRadius = 19
            ringCenterInCursorPoints = .zero
        default:
            label = appearance.pillText
            minimumRadius = 21
            ringCenterInCursorPoints = CGPoint(x: 8, y: 9)
        }
        let ringTextLayout = CursorRingTextLayout.layout(label: label, minimumRadius: minimumRadius)
        let rotationDegrees = ringRotationAccumulator.advance(to: frameDate, degreesPerSecond: ringTextDegreesPerSecond)
        return CursorRingTextView(ringText: ringTextLayout.ringText, radius: ringTextLayout.radius,
                                       color: stateColor, rotationDegrees: rotationDegrees)
            .position(CursorLayerBox.position(ofCursorPoint: ringCenterInCursorPoints))
    }

    private var replayProgressLayer: some View {
        let progressRingCenter = CursorLayerBox.position(ofCursorPoint: CGPoint(x: 8, y: 9))
        return ZStack {
            Circle().stroke(stateColor.opacity(0.22), lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(appearance.replayProgress, 0), 1)))
                .stroke(stateColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(animation(.easeInOut(duration: 0.35)), value: appearance.replayProgress)
        }
        .frame(width: 32, height: 32)
        .position(progressRingCenter)
    }
}

private extension View {
    /// Shows or hides a morph layer with a fade, keeping it in the layout so the cursor never jumps.
    func fadedIn(_ isVisible: Bool, animation: Animation?, value: some Equatable) -> some View {
        opacity(isVisible ? 1 : 0).animation(animation, value: value)
    }
}

// MARK: - Ripple and trail

/// A ring that grows from 0.2× to 1.5× of 40 points and fades out over 0.5 s at the tip after each click.
private struct CursorClickRipple: View {
    let color: Color
    let rippleCount: Int

    var body: some View {
        Circle()
            .stroke(color, lineWidth: 2)
            .frame(width: 40, height: 40)
            .keyframeAnimator(initialValue: 1.0, trigger: rippleCount) { rippleCircle, rippleProgress in
                rippleCircle
                    .scaleEffect(0.2 + 1.3 * rippleProgress)
                    .opacity(rippleProgress >= 1 ? 0 : 0.9 * (1 - rippleProgress))
            } keyframes: { _ in
                KeyframeTrack {
                    MoveKeyframe(0.0)
                    CubicKeyframe(1.0, duration: 0.5)
                }
            }
            .offset(x: -20, y: -20)
            .allowsHitTesting(false)
    }
}

/// One fading arrow of the replay trail, drawn at a past cursor position.
struct CursorGhostArrow: View {
    let color: Color
    let opacity: Double

    var body: some View {
        CursorArrowShape()
            .fill(color)
            .frame(width: 20, height: 20)
            .opacity(opacity)
            .offset(x: -1.5, y: -1.5)
            .allowsHitTesting(false)
    }
}
