import Foundation

private let exampleAnthropicAPIKey = "sk-ant-api03-" + String(repeating: "x", count: 80) + "a1b2"

let anthropicAPIKeyFormatTestSuite = CoreTestSuite(name: "AnthropicAPIKeyFormat", testCases: [
    CoreTestCase(name: "a pasted key is trimmed of surrounding whitespace and newlines") {
        try expectEqual(try AnthropicAPIKeyFormat.validatedAPIKey(fromEnteredText: "  \n" + exampleAnthropicAPIKey + "\n "),
                        exampleAnthropicAPIKey)
    },
    CoreTestCase(name: "empty, wrongly prefixed and split keys are refused") {
        let emptyError = try expectThrowsError { _ = try AnthropicAPIKeyFormat.validatedAPIKey(fromEnteredText: "   \n") }
        try expectEqual(emptyError as? AnthropicAPIKeyValidationError, .empty)
        let prefixError = try expectThrowsError { _ = try AnthropicAPIKeyFormat.validatedAPIKey(fromEnteredText: "sk-proj-abc") }
        try expectEqual(prefixError as? AnthropicAPIKeyValidationError, .missingRequiredPrefix)
        let whitespaceError = try expectThrowsError { _ = try AnthropicAPIKeyFormat.validatedAPIKey(fromEnteredText: "sk-ant-abc def") }
        try expectEqual(whitespaceError as? AnthropicAPIKeyValidationError, .containsWhitespace)
    },
    CoreTestCase(name: "validation messages never repeat the entered text") {
        let enteredText = "sk-ant-secret value"
        let thrownError = try expectThrowsError { _ = try AnthropicAPIKeyFormat.validatedAPIKey(fromEnteredText: enteredText) }
        try expectTrue(!(thrownError.localizedDescription.contains("secret")))
    },
    CoreTestCase(name: "the masked form shows the prefix and the last four characters only") {
        try expectEqual(AnthropicAPIKeyFormat.maskedForDisplay(exampleAnthropicAPIKey), "sk-ant-…a1b2")
    },
    CoreTestCase(name: "a short key shows no suffix, and a key without the prefix shows no prefix") {
        try expectEqual(AnthropicAPIKeyFormat.maskedForDisplay("sk-ant-short1234"), "sk-ant-…")
        try expectEqual(AnthropicAPIKeyFormat.maskedForDisplay(String(repeating: "z", count: 40) + "9876"), "…9876")
    },
])
