import SwiftUI

/// Every step of a routine and every piece of text it will type, with the per-item {{parameter}} slots highlighted
/// and literals that look like a secret flagged. Shared by the review cards and the saved-routine details.
struct RoutineStepListView: View {
    let routine: Routine
    var maximumVisibleStepCount: Int = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(routine.steps.prefix(maximumVisibleStepCount).enumerated()), id: \.offset) { stepOffset, routineStep in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(stepOffset + 1).")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                    VStack(alignment: .leading, spacing: 1) {
                        Self.highlightingParameterSlots(in: routineStep.stepDescription)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                        if let actionDetail = Self.actionDetail(of: routineStep.action) {
                            Self.highlightingParameterSlots(in: actionDetail)
                                .font(.system(size: 11, design: .monospaced))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        if RoutineLiteralInspector.typedLiteralLooksLikeSecret(in: routineStep.action) {
                            RoutineSecretLiteralBadge()
                        }
                    }
                    if routineStep.requiresConfirmationEachItem, routineStep.confirmationRiskCategory?.asksUser ?? true {
                        Text("asks each item")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DesignSystem.Colors.warningText)
                    }
                }
            }
            if routine.steps.count > maximumVisibleStepCount {
                Text("+ \(routine.steps.count - maximumVisibleStepCount) more steps")
                    .font(.system(size: 11))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
            }
        }
    }

    static func actionDetail(of routineStepAction: RoutineStepAction) -> String? {
        switch routineStepAction {
        case .click:
            return nil
        case .typeText(let textTemplate, _, let pressReturnAfter):
            return "types “\(textTemplate)”" + (pressReturnAfter ? " then Return" : "")
        case .pressKey(let keyName, let modifiers):
            return "presses " + (modifiers.map(\.rawValue) + [keyName]).joined(separator: "+")
        case .waitForText(let textTemplate, let timeoutSeconds):
            return "waits up to \(timeoutSeconds) s for “\(textTemplate)”"
        case .uploadFiles(let filePathTemplates):
            return "attaches " + filePathTemplates.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        }
    }

    static func highlightingParameterSlots(in template: String) -> Text {
        var highlightedText = Text("")
        var remainingTemplate = Substring(template)
        while let slotRange = remainingTemplate.range(of: RoutineLiteralInspector.parameterSlotPattern, options: .regularExpression) {
            highlightedText = highlightedText
                + Text(remainingTemplate[..<slotRange.lowerBound]).foregroundColor(DesignSystem.Colors.textPrimary)
                + Text(remainingTemplate[slotRange]).foregroundColor(DesignSystem.Colors.accentText).bold()
            remainingTemplate = remainingTemplate[slotRange.upperBound...]
        }
        return highlightedText + Text(remainingTemplate).foregroundColor(DesignSystem.Colors.textPrimary)
    }
}

/// Informational badge, not a control, so it has no hover state beyond its tooltip.
struct RoutineSecretLiteralBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
            Text("looks like a password or code")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(DesignSystem.Colors.warningText)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(DesignSystem.Colors.warning.opacity(0.15)))
        .nativeTooltip("Dotto types this exact text on every item and it's stored in the routine file. "
                       + "Delete the routine if it holds a secret.")
    }
}
