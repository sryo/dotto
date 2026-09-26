import SwiftUI

/// The command text field and its hints, hosted by CommandBarPanelController.
struct CommandBarView: View {
    @ObservedObject var taskSessionController: TaskSessionController
    @ObservedObject var commandFieldFocusRequest: CommandFieldFocusRequest
    let onDismiss: () -> Void

    @State private var commandText: String
    @FocusState private var isCommandFieldFocused: Bool
    @State private var isFileDropTargeted = false

    init(taskSessionController: TaskSessionController, commandFieldFocusRequest: CommandFieldFocusRequest,
         initialCommandText: String, onDismiss: @escaping () -> Void) {
        self.taskSessionController = taskSessionController
        self.commandFieldFocusRequest = commandFieldFocusRequest
        self.onDismiss = onDismiss
        _commandText = State(initialValue: initialCommandText)
    }

    private var targetApplicationName: String {
        taskSessionController.targetApplication?.applicationName ?? "this app"
    }

    private var canSubmit: Bool {
        !commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                CursorArrowShape()
                    .fill(taskSessionController.taskStyleConfiguration.taskAccentColor)
                    .frame(width: 16, height: 16)

                TextField("What should I do in \(targetApplicationName)?", text: $commandText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .foregroundColor(DesignSystem.Colors.textPrimary)
                    .focused($isCommandFieldFocused)
                    .onSubmit(submitCommand)
                    .onExitCommand(perform: onDismiss)

                HoverAwarePlainButton(action: submitCommand) { isHovered in
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(canSubmit
                            ? (isHovered ? DesignSystem.Colors.accentHover : DesignSystem.Colors.accent)
                            : DesignSystem.Colors.textTertiary)
                }
                .disabled(!canSubmit)
            }

            HStack(spacing: 8) {
                attachFilesButton
                if taskSessionController.attachedUploadGrants.isEmpty {
                    Text("Working in \(targetApplicationName)")
                        .lineLimit(1)
                } else {
                    attachedFilesChip
                }
                Spacer()
                Text("Return to plan · Esc to close")
            }
            .font(.system(size: 11))
            .foregroundColor(DesignSystem.Colors.textTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 560)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.extraLarge, style: .continuous)
                .fill(DesignSystem.Colors.background)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.extraLarge, style: .continuous)
                        .stroke(isFileDropTargeted ? DesignSystem.Colors.accent : DesignSystem.Colors.borderSubtle,
                                lineWidth: isFileDropTargeted ? 2 : 1)
                )
        )
        .dropDestination(for: URL.self) { droppedURLs, _ in
            taskSessionController.attachFilesForNextTask(urls: droppedURLs)
            return !droppedURLs.isEmpty
        } isTargeted: { isTargeted in
            isFileDropTargeted = isTargeted
        }
        .onAppear {
            isCommandFieldFocused = true
        }
        .onChange(of: commandFieldFocusRequest.requestCount) {
            isCommandFieldFocused = true
        }
    }

    // MARK: - Attached files

    private var attachFilesButton: some View {
        HoverAwarePlainButton(action: {
            taskSessionController.chooseFilesToAttach()
            isCommandFieldFocused = true
        }) { isHovered in
            HStack(spacing: 3) {
                Image(systemName: "paperclip")
                Text("Attach files…")
            }
            .foregroundColor(isHovered ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(isHovered ? DesignSystem.Colors.surface3 : DesignSystem.Colors.surface2))
        }
        .nativeTooltip("Pick or drop the files Dotto may attach in this task. Nothing else can be uploaded.")
    }

    private var attachedFilesChip: some View {
        let attachedUploadGrants = taskSessionController.attachedUploadGrants
        let attachedNames = attachedUploadGrants.map { ($0.canonicalPath as NSString).lastPathComponent }
        let attachmentSummary = attachedUploadGrants.count == 1
            ? "\(attachedNames[0]) attached"
            : "\(attachedUploadGrants.count) \(attachedUploadGrants.contains(where: \.isDirectory) ? "items" : "files") attached"
        return HStack(spacing: 4) {
            Text(attachmentSummary)
                .foregroundColor(DesignSystem.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .nativeTooltip(attachedNames.joined(separator: "\n"))
            Text("·")
            Button("Clear") { taskSessionController.clearAttachedFiles() }
                .dsTextButtonStyle()
        }
    }

    private func submitCommand() {
        guard canSubmit else { return }
        taskSessionController.submitCommand(commandText)
    }
}
