import Foundation

/// Reads a script Claude wrote before the user sees it and before it runs. It works on the whole source, strings and
/// comments included, lowercased and with whitespace collapsed (and, for the compact checks, removed), so it fails
/// closed: `run script "do shell script …"` and `app.doShellScript(…)` are caught alike.
enum ScriptSourceInspector {
    /// Any hit makes the script unrunnable. Each phrase is also matched with its spaces removed, which catches the JXA
    /// spelling ("doShellScript", `Application("System Events")`).
    static let deniedPhrases: [String] = [
        "do shell script", "run script", "load script", "store script", "use framework", "use script",
        "current application", "system events", "com.apple.systemevents", "keystroke", "key code", "click at",
        "do javascript", "execute javascript", "do script", "open location", "mount volume", "administrator privileges",
        "empty trash", "restart", "shut down", "log out", "system attribute",
        // Standard Additions' file writing runs inside osascript itself, outside any app the user can see named.
        "open for access",
    ]

    /// Matched against the source with all whitespace removed and lowercased (JXA constructs).
    static let deniedCompactFragments: [String] = [
        "objc.", "$.", "$(", "eval(", "newfunction", "require(", "library(", "globalthis", "constructor",
    ]

    /// AppleScript raw event codes («event …», «class …») can say anything the dictionary words would, unseen.
    static let rawEventCodeMarker = "«"
    static let dynamicTargetConstruct = "an application named by something other than a quoted literal"

    static func inspect(source: String, language: ScriptLanguage) -> ScriptSourceInspection {
        let collapsedSource = source.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let lowercasedCollapsedSource = collapsedSource.lowercased()
        let compactSource = source.filter { !$0.isWhitespace }
        let lowercasedCompactSource = compactSource.lowercased()

        var deniedConstructs: [String] = []
        func deny(_ construct: String) {
            if !deniedConstructs.contains(construct) { deniedConstructs.append(construct) }
        }
        for deniedPhrase in deniedPhrases {
            let compactPhrase = deniedPhrase.replacingOccurrences(of: " ", with: "")
            if lowercasedCollapsedSource.contains(deniedPhrase) || lowercasedCompactSource.contains(compactPhrase) {
                deny(deniedPhrase)
            }
        }
        for deniedFragment in deniedCompactFragments where lowercasedCompactSource.contains(deniedFragment) {
            deny(deniedFragment)
        }
        // JavaScript is case-sensitive: only the capitalized Function( is the constructor; function( declares a function.
        if compactSource.contains("Function(") { deny("Function(") }
        if source.contains(rawEventCodeMarker) { deny("«raw event codes»") }

        switch language {
        case .appleScript:
            if hasAppleScriptDynamicTarget(lowercasedCollapsedSource: lowercasedCollapsedSource) { deny(dynamicTargetConstruct) }
        case .javaScript:
            if hasJavaScriptDynamicTarget(compactSource: compactSource) { deny(dynamicTargetConstruct) }
        }

        return ScriptSourceInspection(referencedApplicationSpecifiers: referencedApplicationSpecifiers(in: collapsedSource, language: language),
                                      deniedConstructs: deniedConstructs,
                                      riskMatch: riskMatch(inSource: source))
    }

    // MARK: - Targets

    /// Every literal after `application "…"`, `application id "…"`, `app "…"` and `Application('…'|"…")`, as written.
    static func referencedApplicationSpecifiers(in collapsedSource: String, language: ScriptLanguage) -> [String] {
        let specifierPattern: String
        switch language {
        case .appleScript: specifierPattern = #"\b(?:application|app)\s+(?:id\s+)?"([^"]*)""#
        case .javaScript: specifierPattern = #"\bApplication\s*\(\s*(?:"([^"]*)"|'([^']*)')\s*\)"#
        }
        guard let specifierExpression = try? NSRegularExpression(pattern: specifierPattern,
                                                                 options: language == .appleScript ? [.caseInsensitive] : []) else { return [] }
        let fullRange = NSRange(collapsedSource.startIndex..., in: collapsedSource)
        var specifiers: [String] = []
        for match in specifierExpression.matches(in: collapsedSource, range: fullRange) {
            for captureGroupIndex in 1..<match.numberOfRanges {
                guard let captureRange = Range(match.range(at: captureGroupIndex), in: collapsedSource) else { continue }
                let specifier = String(collapsedSource[captureRange])
                if !specifiers.contains(specifier) { specifiers.append(specifier) }
            }
        }
        return specifiers
    }

    /// `application` or `app` as a word must be followed by `"…"` or `id "…"`; `tell application appName` could reach
    /// any app. Words inside strings count too (fail closed).
    private static func hasAppleScriptDynamicTarget(lowercasedCollapsedSource: String) -> Bool {
        guard let wordExpression = try? NSRegularExpression(pattern: #"\b(?:application|app)\b(?! ?"| id ")"#) else { return true }
        let fullRange = NSRange(lowercasedCollapsedSource.startIndex..., in: lowercasedCollapsedSource)
        return wordExpression.firstMatch(in: lowercasedCollapsedSource, range: fullRange) != nil
    }

    /// Every `Application` must be called with a quoted literal: `Application(name)`, `Application[…]` and
    /// `Application.currentApplication()` are refused.
    private static func hasJavaScriptDynamicTarget(compactSource: String) -> Bool {
        guard let identifierExpression = try? NSRegularExpression(pattern: #"\bApplication\b(?!\((?:"|'))"#) else { return true }
        let fullRange = NSRange(compactSource.startIndex..., in: compactSource)
        return identifierExpression.firstMatch(in: compactSource, range: fullRange) != nil
    }

    // MARK: - Risk

    /// Verbs a script may use on the app's own data that the item vocabulary doesn't cover as scripts write them.
    private static let scriptVerbRiskPatterns: [(pattern: String, riskCategory: SafetyRiskCategory)] = [
        (#"\bmove\b.{0,200}?\bto\s+(?:the\s+)?trash\b"#, .deleting),
        (#"\bdelete\b"#, .deleting), (#"\bpurge\b"#, .deleting),
        (#"\bsend\b"#, .sendingOrPublishing), (#"\breply\b"#, .sendingOrPublishing), (#"\bforward\b"#, .sendingOrPublishing),
        (#"\bredirect\b"#, .sendingOrPublishing), (#"\bpublish\b"#, .sendingOrPublishing), (#"\bshare\b"#, .sendingOrPublishing),
        (#"\bpay\b"#, .payingOrBuying), (#"\bpurchase\b"#, .payingOrBuying), (#"\bbuy\b"#, .payingOrBuying),
    ]

    /// The first risky verb whose category asks, or else the first risky verb: SafetyRiskVocabulary first, then the
    /// script verb table.
    static func riskMatch(inSource source: String) -> SafetyRiskMatch? {
        var riskMatches = SafetyRiskVocabulary.riskMatches(in: source)
        let lowercasedSource = source.lowercased()
        let fullRange = NSRange(lowercasedSource.startIndex..., in: lowercasedSource)
        for scriptVerbRiskPattern in scriptVerbRiskPatterns {
            guard let verbExpression = try? NSRegularExpression(pattern: scriptVerbRiskPattern.pattern, options: [.dotMatchesLineSeparators]),
                  let verbMatch = verbExpression.firstMatch(in: lowercasedSource, range: fullRange),
                  let matchedRange = Range(verbMatch.range, in: lowercasedSource) else { continue }
            riskMatches.append(SafetyRiskMatch(matchedText: String(lowercasedSource[matchedRange].prefix(40)),
                                               riskCategory: scriptVerbRiskPattern.riskCategory))
        }
        return SafetyRiskVocabulary.mostSevereRiskMatch(among: riskMatches)
    }
}
