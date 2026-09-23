import Foundation

private func deniedConstructs(_ source: String, language: ScriptLanguage = .appleScript) -> [String] {
    ScriptSourceInspector.inspect(source: source, language: language).deniedConstructs
}

let cleanFinderScript = """
tell application "Finder"
    set newFolder to make new folder at desktop with properties {name:"Receipts"}
    return "Created Receipts"
end tell
"""

let scriptSourceInspectorTestSuite = CoreTestSuite(name: "ScriptSourceInspector", testCases: [
    CoreTestCase(name: "a clean Finder script passes and names its one app") {
        let inspection = ScriptSourceInspector.inspect(source: cleanFinderScript, language: .appleScript)
        try expectEqual(inspection.deniedConstructs, [])
        try expectEqual(inspection.referencedApplicationSpecifiers, ["Finder"])
        try expectEqual(inspection.riskMatch, nil)
    },
    CoreTestCase(name: "every denied AppleScript construct is caught, in strings and comments, any case and spacing") {
        for deniedPhrase in ScriptSourceInspector.deniedPhrases {
            let spacedPhrase = deniedPhrase.uppercased().replacingOccurrences(of: " ", with: "  \n ")
            let scriptWithPhraseInComment = "tell application \"Finder\"\n-- \(spacedPhrase)\nend tell"
            try expectTrue(deniedConstructs(scriptWithPhraseInComment).contains(deniedPhrase), deniedPhrase)
        }
        try expectTrue(deniedConstructs("tell application \"Finder\" to run script \"do shell script \\\"rm -rf ~\\\"\"").contains("do shell script"))
        try expectTrue(deniedConstructs("tell application \"Mail\" to «event aevtodoc»").contains("«raw event codes»"))
    },
    CoreTestCase(name: "JXA bridges, shell calls and dynamic code are caught") {
        let deniedJavaScriptSources = [
            "var app = Application.currentApplication(); app.includeStandardAdditions = true; app.doShellScript('ls')",
            "ObjC.import('Foundation')",
            "$.NSTask.alloc.init",
            "eval('1')",
            "Function('return 1')()",
            "var systemEvents = Application('System Events')",
            "Application('Mail'); require('fs')",
        ]
        for deniedJavaScriptSource in deniedJavaScriptSources {
            try expectTrue(!deniedConstructs(deniedJavaScriptSource, language: .javaScript).isEmpty, deniedJavaScriptSource)
        }
        let cleanJavaScript = "const mail = Application('Mail'); mail.mailboxes.push(mail.Mailbox({name: 'Receipts'})); function run() { return 'ok' }"
        try expectEqual(deniedConstructs(cleanJavaScript, language: .javaScript), [])
        try expectEqual(ScriptSourceInspector.inspect(source: cleanJavaScript, language: .javaScript).referencedApplicationSpecifiers, ["Mail"])
    },
    CoreTestCase(name: "targets that aren't quoted literals are refused") {
        try expectTrue(deniedConstructs("set appName to \"Mail\"\ntell application appName to activate")
            .contains(ScriptSourceInspector.dynamicTargetConstruct))
        try expectTrue(deniedConstructs("tell application (\"Ma\" & \"il\") to activate").contains(ScriptSourceInspector.dynamicTargetConstruct))
        try expectTrue(deniedConstructs("const name = 'Mail'; Application(name).activate()", language: .javaScript)
            .contains(ScriptSourceInspector.dynamicTargetConstruct))
        try expectTrue(deniedConstructs("Application['currentApplication']()", language: .javaScript)
            .contains(ScriptSourceInspector.dynamicTargetConstruct))
    },
    CoreTestCase(name: "application id literals and several apps are all reported") {
        let inspection = ScriptSourceInspector.inspect(
            source: "tell application id \"com.apple.mail\" to count mailboxes\ntell app \"Notes\" to count notes", language: .appleScript)
        try expectEqual(inspection.referencedApplicationSpecifiers, ["com.apple.mail", "Notes"])
        try expectEqual(inspection.deniedConstructs, [])
    },
    CoreTestCase(name: "risky verbs map to their categories") {
        func riskCategory(_ source: String) -> SafetyRiskCategory? {
            ScriptSourceInspector.inspect(source: source, language: .appleScript).riskMatch?.riskCategory
        }
        try expectEqual(riskCategory("tell application \"Mail\" to delete (every message of mailbox \"Old\")"), .deleting)
        try expectEqual(riskCategory("tell application \"Mail\" to send newMessage"), .sendingOrPublishing)
        try expectEqual(riskCategory("tell application \"Mail\" to forward theMessage"), .sendingOrPublishing)
        try expectEqual(riskCategory("tell application \"Finder\" to move theFile to the trash"), .deleting)
        try expectEqual(riskCategory(cleanFinderScript), nil)
    },
])

let scriptTargetPolicyTestSuite = CoreTestSuite(name: "ScriptTargetPolicy", testCases: [
    CoreTestCase(name: "terminals, System Events, Shortcuts, password managers and Dotto are blocked; Finder and Mail are not") {
        for blockedBundleIdentifier in ["com.apple.Terminal", "com.apple.systemevents", "com.apple.shortcuts", "com.1password.1password",
                                        "com.sryo.dotto", "com.apple.RemoteDesktop.agent", "com.apple.ScriptEditor2", ""] {
            try expectTrue(ScriptTargetPolicy.isBlockedScriptTarget(bundleIdentifier: blockedBundleIdentifier), blockedBundleIdentifier)
        }
        try expectTrue(!ScriptTargetPolicy.isBlockedScriptTarget(bundleIdentifier: "com.apple.finder"))
        try expectTrue(!ScriptTargetPolicy.isBlockedScriptTarget(bundleIdentifier: "com.apple.mail"))
    },
    CoreTestCase(name: "a script must name only its declared app, by name or bundle id") {
        try expectEqual(ScriptTargetPolicy.evaluate(makeScriptPlan(source: cleanFinderScript, bundleIdentifier: "com.apple.finder",
                                                                   applicationName: "Finder")), .allow)
        try expectEqual(ScriptTargetPolicy.evaluate(makeScriptPlan(source: "tell application id \"com.apple.finder\" to count windows",
                                                                   bundleIdentifier: "com.apple.finder", applicationName: "Finder")), .allow)
        guard case .deny(let otherAppReason) = ScriptTargetPolicy.evaluate(makeScriptPlan(
            source: "tell application \"Finder\" to count windows\ntell application \"Notes\" to count notes",
            bundleIdentifier: "com.apple.finder", applicationName: "Finder")) else { throw CoreTestFailure(description: "expected a denial") }
        try expectTrue(otherAppReason.contains("Notes"), otherAppReason)
        guard case .deny = ScriptTargetPolicy.evaluate(makeScriptPlan(source: "return 1", bundleIdentifier: "com.apple.finder",
                                                                      applicationName: "Finder")) else { throw CoreTestFailure(description: "expected a denial") }
    },
])

func makeScriptPlan(source: String, bundleIdentifier: String = "com.apple.mail", applicationName: String = "Mail",
                    modifiesData: Bool = false, timeoutSeconds: Int = 30) -> ScriptPlan {
    ScriptPlan(targetBundleIdentifier: bundleIdentifier, targetApplicationName: applicationName, language: .appleScript, source: source,
               oneSentenceSummary: "Does a thing.", expectedEffects: ["A thing"], modifiesData: modifiesData, timeoutSeconds: timeoutSeconds,
               inspection: ScriptSourceInspector.inspect(source: source, language: .appleScript))
}

let shortcutNameRulesTestSuite = CoreTestSuite(name: "ShortcutNameRules", testCases: [
    CoreTestCase(name: "names that look like options, carry controls or are empty are refused") {
        try expectTrue(ShortcutNameRules.validate("Resize for web") == nil)
        for refusedName in ["", "-h", "--input-path", "Bad\nName", "Tab\tName"] {
            try expectTrue(ShortcutNameRules.validate(refusedName) != nil, refusedName)
        }
    },
    CoreTestCase(name: "only an exact listed name matches") {
        let listedNames = ["Resize for web", "Make GIF"]
        try expectTrue(ShortcutNameRules.isListed("Resize for web", inListedNames: listedNames))
        try expectTrue(!ShortcutNameRules.isListed("resize for web", inListedNames: listedNames))
        try expectTrue(!ShortcutNameRules.isListed("Resize for web ", inListedNames: listedNames))
        try expectTrue(!ShortcutNameRules.isListed("Resize", inListedNames: listedNames))
    },
])
