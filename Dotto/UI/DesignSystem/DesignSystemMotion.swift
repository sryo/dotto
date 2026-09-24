import SwiftUI
import QuartzCore

extension DesignSystem {
    /// Dotto's one motion language for its pills, cursor and popovers. Shapes arrive and change size with a liquid,
    /// visible bounce (springy, then settled); one element turns into the next
    /// instead of one fading out and another popping in. Opacity-only changes are short ease-outs. Under Reduce
    /// Motion nothing scales or moves: changes are instant or a short fade (`animation(_:reducesMotion:)`,
    /// `appearOrFade(reducesMotion:)`).
    enum Motion {
        // ── Springs: shapes that move, grow or change into each other ──

        /// A pill arriving: it pops from `appearScale` at the corner nearest what it belongs to, with a visible bounce.
        static let appearSpring = Spring(response: 0.3, dampingRatio: 0.62)
        static let appear = SwiftUI.Animation.spring(appearSpring)
        static let appearScale: CGFloat = 0.6
        /// A larger panel (the checklist popover) grows from closer to full size: at 0.6 its jump would be too big.
        static let panelAppearScale: CGFloat = 0.9
        /// A second part of the same arrival (the hint under the command pill) follows the first by this much.
        static let appearFollowerDelaySeconds: Double = 0.06

        /// One shape turning into another: the command pill's capsule becoming the cursor's status pill.
        static let morphSpring = Spring(response: 0.36, dampingRatio: 0.66)
        static let morph = SwiftUI.Animation.spring(morphSpring)

        /// A pill changing size in place as its text or buttons change (Reading → Planning → Review).
        static let resizeSpring = Spring(response: 0.3, dampingRatio: 0.7)
        static let resize = SwiftUI.Animation.spring(resizeSpring)

        // ── Opacity only ──

        /// Something leaving.
        static let disappearDurationSeconds: Double = 0.14
        static let disappear = SwiftUI.Animation.easeOut(duration: disappearDurationSeconds)

        /// Text or buttons swapping inside a shape that morphs; the stages come from `CommandPillMorphTimeline`.
        static func contentFade(durationSeconds: Double) -> SwiftUI.Animation {
            .easeOut(duration: durationSeconds)
        }

        /// A window fading in on its own (the parked cursor, the checklist popover's window).
        static let windowFadeInDurationSeconds: Double = 0.18
        /// Every window fade (`NSAnimationContext`) uses the same ease-out as the SwiftUI fades.
        static var windowFadeTimingFunction: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeOut) }

        /// What an arrival becomes under Reduce Motion: a short fade in place.
        static let reducedMotionFadeDurationSeconds: Double = 0.12
        static let reducedMotionFade = SwiftUI.Animation.easeOut(duration: reducedMotionFadeDurationSeconds)

        /// nil (an instant change) under Reduce Motion.
        static func animation(_ animation: SwiftUI.Animation, reducesMotion: Bool) -> SwiftUI.Animation? {
            reducesMotion ? nil : animation
        }

        /// The arrival spring, or under Reduce Motion a short fade (the caller then leaves the scale at 1).
        static func appearOrFade(reducesMotion: Bool) -> SwiftUI.Animation {
            reducesMotion ? reducedMotionFade : appear
        }
    }
}
