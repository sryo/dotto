import Foundation

struct RoutineTemplateError: Error, Equatable { var message: String }

enum RoutineTemplating {
    private static let placeholderExpression = try! NSRegularExpression(pattern: #"\{\{([^{}]+)\}\}"#)
    private static let minimumTemplatizedValueLength = 2

    /// Single pass, so a parameter value that itself contains "{{…}}" is inserted literally, never expanded.
    static func render(_ template: String, parameters: [ChecklistItemParameter]) throws -> String {
        var renderedText = ""
        var unconsumedStartIndex = template.startIndex
        for placeholderMatch in placeholderExpression.matches(in: template, range: NSRange(template.startIndex..., in: template)) {
            guard let fullRange = Range(placeholderMatch.range, in: template),
                  let nameRange = Range(placeholderMatch.range(at: 1), in: template) else { continue }
            let parameterName = template[nameRange].trimmingCharacters(in: .whitespaces)
            guard let parameter = parameters.first(where: { $0.name == parameterName }) else {
                throw RoutineTemplateError(message: "Unknown parameter “\(parameterName)”. Known parameters: \(parameters.map(\.name).joined(separator: ", ")).")
            }
            renderedText += template[unconsumedStartIndex..<fullRange.lowerBound] + parameter.value
            unconsumedStartIndex = fullRange.upperBound
        }
        return renderedText + template[unconsumedStartIndex...]
    }

    /// Replaces parameter values with {{name}}, trying the longest value first at each position, so a value that
    /// contains another is replaced whole. Values shorter than 2 characters are ignored so "1" doesn't templatize
    /// every digit.
    static func templatize(_ literalText: String, parameters: [ChecklistItemParameter]) -> String {
        let parametersLongestValueFirst = parameters
            .filter { $0.value.count >= minimumTemplatizedValueLength }
            .sorted { $0.value.count > $1.value.count }
        var templatizedText = ""
        var scanIndex = literalText.startIndex
        scanning: while scanIndex < literalText.endIndex {
            for parameter in parametersLongestValueFirst where literalText[scanIndex...].hasPrefix(parameter.value) {
                templatizedText += "{{\(parameter.name)}}"
                scanIndex = literalText.index(scanIndex, offsetBy: parameter.value.count)
                continue scanning
            }
            templatizedText.append(literalText[scanIndex])
            scanIndex = literalText.index(after: scanIndex)
        }
        return templatizedText
    }

    /// For element texts in locators. A whole-text match is always templatized; with `allowsWholeTokenMatches`, so
    /// is a value that stands as whole whitespace-delimited words inside the text ("Invoice March" in
    /// "Re: Invoice March"), but never a fragment of a word ("New" in "Newsletter").
    static func templatizeLocatorText(_ literalText: String, parameters: [ChecklistItemParameter], allowsWholeTokenMatches: Bool) -> String {
        let trimmedText = literalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let wholeTextParameter = parameters.first(where: { $0.value.count >= minimumTemplatizedValueLength && $0.value == trimmedText }) {
            return "{{\(wholeTextParameter.name)}}"
        }
        guard allowsWholeTokenMatches else { return literalText }
        let parametersLongestValueFirst = parameters
            .filter { $0.value.count >= minimumTemplatizedValueLength }
            .sorted { $0.value.count > $1.value.count }
        var templatizedText = ""
        var scanIndex = literalText.startIndex
        scanning: while scanIndex < literalText.endIndex {
            let startsAtWordBoundary = scanIndex == literalText.startIndex || literalText[literalText.index(before: scanIndex)].isWhitespace
            if startsAtWordBoundary {
                for parameter in parametersLongestValueFirst where literalText[scanIndex...].hasPrefix(parameter.value) {
                    let matchEndIndex = literalText.index(scanIndex, offsetBy: parameter.value.count)
                    guard matchEndIndex == literalText.endIndex || literalText[matchEndIndex].isWhitespace else { continue }
                    templatizedText += "{{\(parameter.name)}}"
                    scanIndex = matchEndIndex
                    continue scanning
                }
            }
            templatizedText.append(literalText[scanIndex])
            scanIndex = literalText.index(after: scanIndex)
        }
        return templatizedText
    }

    /// Unique names in order of first appearance.
    static func placeholderNames(in template: String) -> [String] {
        var names: [String] = []
        for placeholderMatch in placeholderExpression.matches(in: template, range: NSRange(template.startIndex..., in: template)) {
            guard let nameRange = Range(placeholderMatch.range(at: 1), in: template) else { continue }
            let parameterName = template[nameRange].trimmingCharacters(in: .whitespaces)
            if !names.contains(parameterName) { names.append(parameterName) }
        }
        return names
    }

    static func containsPlaceholder(_ template: String?) -> Bool {
        template?.contains("{{") == true
    }
}
