import SwiftUI

/// One task Dotto holds, in the menu bar panel: its color, its app and what it is doing, with Show (its checklist)
/// and Stop while it is going or Close once it has finished.
struct MenuBarTaskRow: View {
    @ObservedObject var sessionScope: TaskSessionScope

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(sessionScope.taskStyleConfiguration.taskAccentColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(sessionScope.targetApplication?.applicationName ?? "Task")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
                Text(sessionScope.statusLine)
                    .font(.system(size: 10))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Button("Show") {
                NotificationCenter.default.post(name: .dismissMenuBarPanel, object: nil)
                sessionScope.showChecklist()
            }
            .dsSecondaryButtonStyle()
            if sessionScope.sessionState.isBusy {
                Button("Stop") { sessionScope.stopTask() }
                    .dsDestructiveButtonStyle()
            } else {
                Button("Close") { sessionScope.dismissFinishedTask() }
                    .dsSecondaryButtonStyle()
            }
        }
    }
}
