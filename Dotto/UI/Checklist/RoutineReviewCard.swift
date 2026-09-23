import SwiftUI

/// Shown before a taught or learned routine is saved: every step, and every piece of text it will type, with the
/// per-item {{parameter}} slots highlighted so any literal copied from the run or demonstration is visible.
struct RoutineReviewCard: View {
    let routine: Routine
    let closingExplanation: String
    let onDiscard: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review “\(routine.name)”")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DesignSystem.Colors.textPrimary)
            (Text("Dotto repeats these steps for every other item, filling in ").foregroundColor(DesignSystem.Colors.textSecondary)
                + RoutineStepListView.highlightingParameterSlots(in: routine.parameterNames.map { "{{\($0)}}" }.joined(separator: ", "))
                + Text(" from each item. Everything else is typed exactly as shown.").foregroundColor(DesignSystem.Colors.textSecondary))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)

            RoutineStepListView(routine: routine)

            WrappingText(closingExplanation, size: 11, color: DesignSystem.Colors.textTertiary)

            HStack(spacing: 8) {
                Button("Discard", action: onDiscard)
                    .dsSecondaryButtonStyle()
                Button("Save routine", action: onSave)
                    .dsPrimaryButtonStyle()
            }
        }
        .modifier(ChecklistCardBackground(borderColor: DesignSystem.Colors.accent))
    }
}
