import Foundation

/// Finds the fixed text (outside {{parameter}} slots) a routine types on every item and flags text that looks
/// like a secret the user typed or pasted while teaching.
enum RoutineLiteralInspector {
    static let parameterSlotPattern = #"\{\{[^}]*\}\}"#
    private static let minimumHighEntropyTokenLength = 20
    private static let minimumTwoClassTokenLength = 32
    /// Random base64/hex tokens sit around 4–6 bits per character; words and file names stay well below 3.5.
    private static let minimumHighEntropyBitsPerCharacter = 3.5

    static func typedLiteralLooksLikeSecret(in routineStepAction: RoutineStepAction) -> Bool {
        guard case .typeText(let textTemplate, _, _) = routineStepAction else { return false }
        return literalLooksLikeSecret(textTemplate)
    }

    static func routineHasSecretLookingLiteral(_ routine: Routine) -> Bool {
        routine.steps.contains { typedLiteralLooksLikeSecret(in: $0.action) }
    }

    static func literalLooksLikeSecret(_ textTemplate: String) -> Bool {
        let literalText = textTemplate.replacingOccurrences(of: parameterSlotPattern, with: " ", options: .regularExpression)
        let literalTokens = literalText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return literalTokens.contains { literalToken in
            isOneTimeCode(literalToken) || isHighEntropyToken(literalToken)
        }
    }

    private static func isOneTimeCode(_ literalToken: String) -> Bool {
        literalToken.range(of: #"\A\d{6}\z"#, options: .regularExpression) != nil
    }

    private static func isHighEntropyToken(_ literalToken: String) -> Bool {
        guard literalToken.count >= minimumHighEntropyTokenLength,
              literalToken.contains(where: \.isNumber), literalToken.contains(where: \.isLetter) else { return false }
        // URLs, paths, file names and email addresses are long and varied but are what routines legitimately type.
        if literalToken.contains("://") || literalToken.hasPrefix("/") || literalToken.hasPrefix("~")
            || literalToken.range(of: #"\.[A-Za-z][A-Za-z0-9]{0,4}\z"#, options: .regularExpression) != nil {
            return false
        }
        let characterClassCount = [
            literalToken.contains(where: \.isLowercase), literalToken.contains(where: \.isUppercase),
            literalToken.contains(where: \.isNumber),
            literalToken.contains(where: { !$0.isLetter && !$0.isNumber }),
        ].filter { $0 }.count
        // Hex keys use only two classes (lowercase and digits), so they qualify once they are key-length.
        guard characterClassCount >= 3 || (characterClassCount == 2 && literalToken.count >= minimumTwoClassTokenLength) else {
            return false
        }
        var characterCounts: [Character: Int] = [:]
        for tokenCharacter in literalToken { characterCounts[tokenCharacter, default: 0] += 1 }
        let tokenLength = Double(literalToken.count)
        let shannonEntropyBitsPerCharacter = characterCounts.values.reduce(0.0) { entropySoFar, characterCount in
            let characterProbability = Double(characterCount) / tokenLength
            return entropySoFar - characterProbability * log2(characterProbability)
        }
        return shannonEntropyBitsPerCharacter >= minimumHighEntropyBitsPerCharacter
    }
}
