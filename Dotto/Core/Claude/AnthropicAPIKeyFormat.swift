import Foundation

enum AnthropicAPIKeyValidationError: Error, Equatable, LocalizedError {
    case empty
    case missingRequiredPrefix
    case containsWhitespace

    // None of these repeat what was typed: the text may be a real key with a typo in it.
    var errorDescription: String? {
        switch self {
        case .empty: return "Paste your Anthropic API key first."
        case .missingRequiredPrefix: return "That doesn't look like an Anthropic API key. Keys start with “\(AnthropicAPIKeyFormat.requiredPrefix)”."
        case .containsWhitespace: return "The key has a space or line break in it. Copy it again from the Claude Console."
        }
    }
}

/// What Dotto checks before saving a pasted key, and the only form in which a key is ever shown: the fixed prefix and
/// the last four characters (`sk-ant-…a1b2`), which is enough to tell two keys apart and useless to anyone else.
enum AnthropicAPIKeyFormat {
    static let requiredPrefix = "sk-ant-"
    static let visibleSuffixCharacterCount = 4
    /// A real key is about a hundred characters long. Below this, even the last four characters would reveal too much
    /// of it, so only the prefix is shown.
    static let minimumLengthForVisibleSuffix = 24

    static func validatedAPIKey(fromEnteredText enteredText: String) throws -> String {
        let trimmedAPIKey = enteredText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAPIKey.isEmpty else { throw AnthropicAPIKeyValidationError.empty }
        guard trimmedAPIKey.hasPrefix(requiredPrefix) else { throw AnthropicAPIKeyValidationError.missingRequiredPrefix }
        guard trimmedAPIKey.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw AnthropicAPIKeyValidationError.containsWhitespace
        }
        return trimmedAPIKey
    }

    static func maskedForDisplay(_ apiKey: String) -> String {
        let visiblePrefix = apiKey.hasPrefix(requiredPrefix) ? requiredPrefix : ""
        guard apiKey.count >= minimumLengthForVisibleSuffix else { return visiblePrefix + "…" }
        return visiblePrefix + "…" + String(apiKey.suffix(visibleSuffixCharacterCount))
    }
}
