import SwiftUI

/// One saved routine in the menu bar panel, with its steps and its run-on-a-list and run-on-a-folder entry points.
struct SavedRoutineRow: View {
    let routine: Routine
    @ObservedObject var taskSessionController: TaskSessionController
    @State private var isConfirmingDelete = false
    @State private var isShowingListEditor = false
    @State private var isShowingStepDetails = false
    @State private var pastedListText = ""
    @State private var listPreparationErrorMessage: String?

    private var isEnabled: Bool { taskSessionController.anotherTaskCanStart }
    private var routineHasSecretLookingLiteral: Bool { RoutineLiteralInspector.routineHasSecretLookingLiteral(routine) }

    private var listPlaceholderText: String {
        "One item per line — values for: " + routine.parameterNames.joined(separator: ", ")
            + (routine.parameterNames.count > 1 ? " (tab-separated)" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(routine.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(DesignSystem.Colors.textSecondary)
                            .lineLimit(1)
                        if routineHasSecretLookingLiteral {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(DesignSystem.Colors.warningText)
                                .nativeTooltip("This routine types text that looks like a password or code. Open Steps to check it.")
                        }
                    }
                    Text("\(routine.targetApplicationName) · \(routine.steps.count) steps · \(routine.source == .userDemonstration ? "taught" : "learned")")
                        .font(.system(size: 10))
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                        .lineLimit(1)
                }
                // The buttons dim themselves while Dotto is busy; the name and details dim to match.
                .opacity(isEnabled ? 1 : 0.5)
                Spacer(minLength: 4)
                if isConfirmingDelete {
                    Text("Delete?")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.destructiveText)
                    Button("Yes") { taskSessionController.deleteSavedRoutine(routineIdentifier: routine.routineIdentifier) }
                        .dsTextButtonStyle()
                    Button("No") { isConfirmingDelete = false }
                        .dsTextButtonStyle()
                } else {
                    Button(isShowingStepDetails ? "Hide steps" : "Steps") { isShowingStepDetails.toggle() }
                        .dsTextButtonStyle()
                        .nativeTooltip("Every step and the exact text Dotto types")
                    Button("Run on list…") {
                        isShowingListEditor.toggle()
                        listPreparationErrorMessage = nil
                    }
                    .dsTextButtonStyle()
                    Button(action: { isConfirmingDelete = true }) {
                        Image(systemName: "trash")
                    }
                    .dsDestructiveIconButtonStyle(size: 22)
                    .nativeTooltip("Delete routine")
                }
            }
            if isShowingStepDetails {
                RoutineStepListView(routine: routine, maximumVisibleStepCount: 30)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.medium, style: .continuous).fill(DesignSystem.Colors.surface2))
            }
            if isShowingListEditor {
                listEditor
            }
        }
        .padding(.vertical, 6)
        .disabled(!isEnabled)
    }

    private var listEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $pastedListText)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(height: 80)
                if pastedListText.isEmpty {
                    Text(listPlaceholderText)
                        .font(.system(size: 11))
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                        .padding(.horizontal, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.medium, style: .continuous).fill(DesignSystem.Colors.surface2))

            if let listPreparationErrorMessage {
                WrappingText(listPreparationErrorMessage, size: 11, color: DesignSystem.Colors.destructiveText)
            }
            Button("Prepare checklist") {
                handlePreparationResult(taskSessionController.prepareRoutineRun(
                    routineIdentifier: routine.routineIdentifier, pastedListText: pastedListText))
            }
            .dsPrimaryButtonStyle()
            HStack(spacing: 8) {
                Button("Pick folder…") {
                    handlePreparationResult(taskSessionController.prepareRoutineRunFromFolder(routineIdentifier: routine.routineIdentifier))
                }
                .dsSecondaryButtonStyle()
                Button("Cancel") { isShowingListEditor = false }
                    .dsSecondaryButtonStyle()
            }
        }
    }

    private func handlePreparationResult(_ preparationErrorMessage: String?) {
        listPreparationErrorMessage = preparationErrorMessage
        // nil also means a cancelled folder picker; only a prepared checklist closes the editor and the panel.
        guard preparationErrorMessage == nil, case .awaitingApproval = taskSessionController.sessionState else { return }
        isShowingListEditor = false
        pastedListText = ""
        NotificationCenter.default.post(name: .dismissMenuBarPanel, object: nil)
    }
}
