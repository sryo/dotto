import SwiftUI

/// The menu bar panel's Anthropic API key. Without a key it is a prominent setup card with a secure field; with one it
/// is a row showing only the masked key, with Replace and Remove. The field is typed into while the panel is key
/// (the menu bar panel is a `KeyablePanel` the user opened), and what is typed never leaves this view except into
/// `saveAnthropicAPIKey`.
struct AnthropicAPIKeySection: View {
    @ObservedObject var taskSessionController: TaskSessionController

    @State private var enteredAPIKeyText = ""
    @State private var saveProblem: String?
    @State private var isReplacingKey = false
    @State private var isConfirmingRemove = false
    @FocusState private var isAPIKeyFieldFocused: Bool

    var body: some View {
        if let maskedAnthropicAPIKey = taskSessionController.maskedAnthropicAPIKey {
            savedKeyRow(maskedAnthropicAPIKey: maskedAnthropicAPIKey)
        } else {
            setupCard
        }
    }

    // MARK: - No key yet

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.accentText)
                Text("Add your Anthropic API key to start")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.textPrimary)
            }
            WrappingText("Dotto plans and works with Claude using your own key. It is kept in your Keychain and only sent to Anthropic.",
                         size: 11, color: DesignSystem.Colors.textSecondary)

            apiKeyEntryField

            Button("Save key", action: saveEnteredAPIKey)
                .dsPrimaryButtonStyle()
                .disabled(enteredAPIKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            consoleLinkButton

            if let storeProblem = taskSessionController.anthropicAPIKeyStoreProblem {
                WrappingText(storeProblem, size: 10, color: DesignSystem.Colors.warningText)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.large, style: .continuous)
                .fill(DesignSystem.Colors.accentSubtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.large, style: .continuous)
                .stroke(DesignSystem.Colors.accent.opacity(0.35), lineWidth: 1)
        )
        .onAppear { isAPIKeyFieldFocused = true }
    }

    // MARK: - Key saved

    private func savedKeyRow(maskedAnthropicAPIKey: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                MenuBarSettingText(title: "Anthropic API key", explanation: "In your Keychain, sent only to Anthropic")
                Spacer(minLength: 4)
                Text(maskedAnthropicAPIKey)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
            }
            HStack(spacing: 10) {
                Spacer()
                if isConfirmingRemove {
                    Text("Remove key?")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.destructiveText)
                    Button("Yes") {
                        isConfirmingRemove = false
                        isReplacingKey = false
                        taskSessionController.removeAnthropicAPIKey()
                    }
                    .dsTextButtonStyle()
                    Button("No") { isConfirmingRemove = false }
                        .dsTextButtonStyle()
                } else {
                    Button(isReplacingKey ? "Cancel" : "Replace") {
                        isReplacingKey.toggle()
                        enteredAPIKeyText = ""
                        saveProblem = nil
                        isAPIKeyFieldFocused = isReplacingKey
                    }
                    .dsTextButtonStyle()
                    Button("Remove") { isConfirmingRemove = true }
                        .dsTextButtonStyle()
                        .disabled(taskSessionController.anySessionIsBusy)
                }
            }
            if isReplacingKey {
                apiKeyEntryField
                HStack(spacing: 10) {
                    consoleLinkButton
                    Spacer()
                    Button("Save new key", action: saveEnteredAPIKey)
                        .dsTextButtonStyle()
                        .disabled(enteredAPIKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let storeProblem = taskSessionController.anthropicAPIKeyStoreProblem {
                WrappingText(storeProblem, size: 10, color: DesignSystem.Colors.warningText)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
    }

    // MARK: - Shared parts

    private var apiKeyEntryField: some View {
        VStack(alignment: .leading, spacing: 4) {
            SecureField("sk-ant-…", text: $enteredAPIKeyText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(DesignSystem.Colors.textPrimary)
                .focused($isAPIKeyFieldFocused)
                .onSubmit(saveEnteredAPIKey)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.medium, style: .continuous)
                        .fill(DesignSystem.Colors.surface2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.medium, style: .continuous)
                        .stroke(isAPIKeyFieldFocused ? DesignSystem.Colors.accent : DesignSystem.Colors.borderSubtle, lineWidth: 1)
                )
                .accessibilityLabel("Anthropic API key")
            if let saveProblem {
                WrappingText(saveProblem, size: 10, color: DesignSystem.Colors.warningText)
            }
        }
    }

    private var consoleLinkButton: some View {
        HoverAwarePlainButton(action: { taskSessionController.openClaudeConsoleAPIKeysPage() }) { isHovered in
            HStack(spacing: 4) {
                Text("Get a key in the Claude Console")
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(isHovered ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.accentText)
            .underline(isHovered)
        }
        .nativeTooltip("Opens platform.claude.com/settings/keys in your browser")
    }

    private func saveEnteredAPIKey() {
        guard !enteredAPIKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        saveProblem = taskSessionController.saveAnthropicAPIKey(enteredText: enteredAPIKeyText)
        if saveProblem == nil {
            enteredAPIKeyText = ""
            isReplacingKey = false
            isAPIKeyFieldFocused = false
        }
    }
}
