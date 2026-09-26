import Combine
import SwiftUI

/// How the command pill arrives: it grows from the corner nearest the pointer on the appear spring, and the hint under
/// it follows a moment later. The controller starts it once the pill is placed (the corner depends on which way the
/// pill flipped) and on screen.
@MainActor
final class CommandPillEntrance: ObservableObject {
    @Published var growthAnchor: UnitPoint = .topLeading
    @Published private(set) var capsuleHasEntered = false
    @Published private(set) var hintHasEntered = false

    /// Under Reduce Motion the pill only fades in, in place.
    func enter(reducesMotion: Bool) {
        withAnimation(DesignSystem.Motion.appearOrFade(reducesMotion: reducesMotion)) {
            capsuleHasEntered = true
        }
        withAnimation(DesignSystem.Motion.appearOrFade(reducesMotion: reducesMotion)
            .delay(reducesMotion ? 0 : DesignSystem.Motion.appearFollowerDelaySeconds)) {
            hintHasEntered = true
        }
    }
}

/// The command field at the pointer, however Dotto was summoned: a task-color capsule with Dotto's arrow and a white
/// text field with a paperclip, and a small hint under it (with the attached files, once there are any). Files can also
/// be dropped on it. Submitting goes through `TaskSessionController.submitCommand`. The capsule draws the cursor pill's own shadow, in room the view
/// keeps around itself, so the morph into the status pill carries one continuous shadow.
struct CommandPillView: View {
    @ObservedObject var taskSessionController: TaskSessionController
    @ObservedObject var commandFieldFocusRequest: CommandFieldFocusRequest
    @ObservedObject var entrance: CommandPillEntrance
    let reducesMotion: Bool
    let onDismiss: () -> Void

    @State private var commandText: String
    @FocusState private var isCommandFieldFocused: Bool
    @State private var isFileDropTargeted = false

    init(taskSessionController: TaskSessionController, commandFieldFocusRequest: CommandFieldFocusRequest,
         entrance: CommandPillEntrance, reducesMotion: Bool, initialCommandText: String = "", onDismiss: @escaping () -> Void) {
        self.taskSessionController = taskSessionController
        self.commandFieldFocusRequest = commandFieldFocusRequest
        self.entrance = entrance
        self.reducesMotion = reducesMotion
        self.onDismiss = onDismiss
        _commandText = State(initialValue: initialCommandText)
    }

    static let pillWidth: CGFloat = 320
    /// Fixed, so the pill can be placed (and the status pill lined up with it) before it is laid out.
    static let capsuleHeight: CGFloat = 40
    /// Between the capsule and the hint under it.
    static let hintSpacing: CGFloat = 6
    static let hintLeadingInset: CGFloat = 12
    /// Transparent room around the capsule and hint for their shadows; the panel is this much larger on every side.
    static let shadowPadding: CGFloat = 24
    private static let placeholderColor = Color(red: 0x8A / 255, green: 0x87 / 255, blue: 0x9A / 255)

    private var targetApplicationName: String {
        taskSessionController.targetApplication?.applicationName ?? "this app"
    }

    private var taskColor: Color {
        taskSessionController.taskStyleConfiguration.taskAccentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.hintSpacing) {
            commandCapsule
            HStack(spacing: 6) {
                CommandPillHintChip()
                if !taskSessionController.attachedUploadGrants.isEmpty {
                    CommandPillAttachedFilesChip(attachedUploadGrants: taskSessionController.attachedUploadGrants,
                                                 onClear: { taskSessionController.clearAttachedFiles() })
                }
            }
            .padding(.leading, Self.hintLeadingInset)
            .opacity(entrance.hintHasEntered ? 1 : 0)
        }
        .dropDestination(for: URL.self) { droppedURLs, _ in
            taskSessionController.attachFilesForNextTask(urls: droppedURLs)
            return !droppedURLs.isEmpty
        } isTargeted: { isTargeted in
            isFileDropTargeted = isTargeted
        }
        .scaleEffect(entrance.capsuleHasEntered || reducesMotion ? 1 : DesignSystem.Motion.appearScale,
                     anchor: entrance.growthAnchor)
        .opacity(entrance.capsuleHasEntered ? 1 : 0)
        .padding(Self.shadowPadding)
        .onChange(of: commandFieldFocusRequest.requestCount) {
            isCommandFieldFocused = true
        }
        .onAppear {
            isCommandFieldFocused = true
        }
    }

    private var commandCapsule: some View {
        CommandPillCapsuleContent {
            HStack(spacing: 6) {
                TextField("", text: $commandText,
                          prompt: Text("What should Dotto do in \(targetApplicationName)?").foregroundColor(Self.placeholderColor))
                    .textFieldStyle(.plain)
                    .focused($isCommandFieldFocused)
                    .onSubmit(submitCommand)
                    .onExitCommand(perform: onDismiss)
                    .accessibilityLabel("Task for Dotto")
                attachFilesButton
            }
        }
        .background(CommandPillCapsuleShape().fill(taskColor).commandPillCapsuleShadow())
        .overlay(CommandPillCapsuleShape().stroke(Color.white, lineWidth: isFileDropTargeted ? 2 : 0))
    }

    private var attachFilesButton: some View {
        HoverAwarePlainButton(action: {
            taskSessionController.chooseFilesToAttach()
            isCommandFieldFocused = true
        }) { isHovered in
            Image(systemName: "paperclip")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isHovered ? CommandPillCapsuleContent<EmptyView>.fieldTextColor : Self.placeholderColor)
        }
        .accessibilityLabel("Attach files…")
        .nativeTooltip("Pick or drop the files Dotto may attach in this task. Nothing else can be uploaded.")
    }

    private func submitCommand() {
        guard !commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        taskSessionController.submitCommand(commandText)
    }
}

/// The files attached to the next task, beside the pill's hint, with Clear.
struct CommandPillAttachedFilesChip: View {
    let attachedUploadGrants: [UploadFileGrant]
    let onClear: () -> Void

    var body: some View {
        let attachedNames = attachedUploadGrants.map { ($0.canonicalPath as NSString).lastPathComponent }
        let attachmentSummary = attachedUploadGrants.count == 1
            ? "\(attachedNames[0]) attached"
            : "\(attachedUploadGrants.count) \(attachedUploadGrants.contains(where: \.isDirectory) ? "items" : "files") attached"
        HStack(spacing: 4) {
            Image(systemName: "paperclip")
            Text(attachmentSummary)
                .lineLimit(1)
                .truncationMode(.middle)
                .nativeTooltip(attachedNames.joined(separator: "\n"))
            Button("Clear", action: onClear)
                .dsTextButtonStyle()
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(DesignSystem.Colors.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(DesignSystem.Colors.surface2)
                .shadow(color: CursorPalette.pillShadowColor.opacity(0.18), radius: 6, x: 0, y: 3)
        )
    }
}

/// What the command pill's capsule holds, without its task-color fill: Dotto's arrow and the white field. Shared by the
/// live pill (a text field) and its morph into the status pill (the submitted text), so both draw the same capsule.
struct CommandPillCapsuleContent<Field: View>: View {
    @ViewBuilder let field: () -> Field

    static var fieldTextColor: Color { Color(red: 0x1D / 255, green: 0x1C / 255, blue: 0x25 / 255) }

    var body: some View {
        HStack(spacing: 8) {
            CursorArrowShape()
                .fill(Color.white)
                .frame(width: 13, height: 13)

            field()
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Self.fieldTextColor)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Capsule(style: .continuous).fill(Color.white))
        }
        .padding(.leading, 11)
        .padding([.trailing, .vertical], 5)
        .frame(width: CommandPillView.pillWidth, height: CommandPillView.capsuleHeight)
    }
}

/// The command pill's capsule outline: a rounded rectangle whose corners are half its height, the same shape the morph
/// animates (its corner radius shrinking to the status pill's), so the morph's first frame is the pill as it was.
struct CommandPillCapsuleShape: Shape {
    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: CommandPillView.capsuleHeight / 2, style: .continuous).path(in: rect)
    }
}

extension View {
    /// The cursor pill's shadow at the size the command pill is drawn (it has no cursor scale); the morph carries it
    /// on to the status pill's without fading.
    func commandPillCapsuleShadow() -> some View {
        shadow(color: CursorPillChrome.shadowColor, radius: CursorPillChrome.shadowRadius, x: 0, y: CursorPillChrome.shadowOffsetY)
    }
}

/// The small hint under the command pill's capsule.
struct CommandPillHintChip: View {
    var body: some View {
        (Text("Return").fontWeight(.semibold).foregroundColor(DesignSystem.Colors.textPrimary)
            + Text(" to plan it · ")
            + Text("Esc").fontWeight(.semibold).foregroundColor(DesignSystem.Colors.textPrimary)
            + Text(" to close"))
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(DesignSystem.Colors.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(DesignSystem.Colors.surface2)
                    .shadow(color: CursorPalette.pillShadowColor.opacity(0.18), radius: 6, x: 0, y: 3)
            )
    }
}
