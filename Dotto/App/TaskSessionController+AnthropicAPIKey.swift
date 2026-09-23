import AppKit

/// The user's own Anthropic API key: saving, replacing and removing it from the menu bar panel, and sending the user
/// there when a command needs a key that isn't saved yet. Only the masked form is ever published to the UI.
extension TaskSessionController {
    static let claudeConsoleAPIKeysPageURL = URL(string: "https://platform.claude.com/settings/keys")!

    var hasAnthropicAPIKey: Bool { maskedAnthropicAPIKey != nil }

    func refreshAnthropicAPIKeyState() {
        do {
            maskedAnthropicAPIKey = try anthropicAPIKeyStore.readAPIKey().map(AnthropicAPIKeyFormat.maskedForDisplay)
            anthropicAPIKeyStoreProblem = nil
        } catch {
            maskedAnthropicAPIKey = nil
            anthropicAPIKeyStoreProblem = error.localizedDescription
        }
    }

    /// Returns why the entered text wasn't saved, or nil once it is in the Keychain.
    func saveAnthropicAPIKey(enteredText: String) -> String? {
        do {
            let validatedAPIKey = try AnthropicAPIKeyFormat.validatedAPIKey(fromEnteredText: enteredText)
            try anthropicAPIKeyStore.saveAPIKey(validatedAPIKey)
            maskedAnthropicAPIKey = AnthropicAPIKeyFormat.maskedForDisplay(validatedAPIKey)
            anthropicAPIKeyStoreProblem = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func removeAnthropicAPIKey() {
        do {
            try anthropicAPIKeyStore.deleteAPIKey()
            maskedAnthropicAPIKey = nil
            anthropicAPIKeyStoreProblem = nil
        } catch {
            anthropicAPIKeyStoreProblem = error.localizedDescription
        }
    }

    func openClaudeConsoleAPIKeysPage() {
        NSWorkspace.shared.open(Self.claudeConsoleAPIKeysPageURL)
    }

    /// Opens the menu bar panel, whose API key card is the first thing shown while no key is saved.
    func showAnthropicAPIKeySetup() {
        NotificationCenter.default.post(name: .showMenuBarPanel, object: nil)
    }
}
