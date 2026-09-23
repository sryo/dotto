import SwiftUI

/// The command bar in its summoned-at-the-pointer form, opened by the circle gesture: a task-color capsule with
/// Dotto's arrow and a white text field, and a small hint under it. Submitting goes through the command bar's own
/// path (`TaskSessionController.submitCommand`).
struct CommandPillView: View {
    @ObservedObject var taskSessionController: TaskSessionController
    @ObservedObject var commandFieldFocusRequest: CommandFieldFocusRequest
    let reducesMotion: Bool
    let onDismiss: () -> Void

    @State private var commandText = ""
    @State private var hasAppeared = false
    @FocusState private var isCommandFieldFocused: Bool

    static let pillWidth: CGFloat = 320
    private static let fieldTextColor = Color(red: 0x1D / 255, green: 0x1C / 255, blue: 0x25 / 255)
    private static let placeholderColor = Color(red: 0x8A / 255, green: 0x87 / 255, blue: 0x9A / 255)

    private var targetApplicationName: String {
        taskSessionController.targetApplication?.applicationName ?? "this app"
    }

    private var taskColor: Color {
        taskSessionController.cursorStyleConfiguration.taskAccentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            commandCapsule
            hintChip
                .padding(.leading, 12)
        }
        .scaleEffect(hasAppeared || reducesMotion ? 1 : 0.6, anchor: .topLeading)
        .opacity(hasAppeared || reducesMotion ? 1 : 0)
        .onChange(of: commandFieldFocusRequest.requestCount) {
            isCommandFieldFocused = true
        }
        .onAppear {
            isCommandFieldFocused = true
            // The lab's pill-in: a slightly overshooting pop from the pointer corner.
            withAnimation(reducesMotion ? nil : .spring(response: 0.3, dampingFraction: 0.62)) {
                hasAppeared = true
            }
        }
    }

    private var commandCapsule: some View {
        HStack(spacing: 8) {
            CursorArrowShape()
                .fill(Color.white)
                .frame(width: 13, height: 13)

            TextField("", text: $commandText,
                      prompt: Text("What should Dotto do in \(targetApplicationName)?").foregroundColor(Self.placeholderColor))
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Self.fieldTextColor)
                .focused($isCommandFieldFocused)
                .onSubmit(submitCommand)
                .onExitCommand(perform: onDismiss)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Capsule(style: .continuous).fill(Color.white))
                .accessibilityLabel("Task for Dotto")
        }
        .padding(.leading, 11)
        .padding([.trailing, .vertical], 5)
        .frame(width: Self.pillWidth)
        .background(Capsule(style: .continuous).fill(taskColor))
    }

    private var hintChip: some View {
        (Text("Return").fontWeight(.semibold).foregroundColor(DesignSystem.Colors.textPrimary)
            + Text(" to plan it · ")
            + Text("Esc").fontWeight(.semibold).foregroundColor(DesignSystem.Colors.textPrimary)
            + Text(" to close"))
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(DesignSystem.Colors.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DesignSystem.Colors.surface2))
    }

    private func submitCommand() {
        guard !commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        taskSessionController.submitCommand(commandText)
    }
}
