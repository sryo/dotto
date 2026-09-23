import Foundation

private let finderScopeRootPath = "/Users/me/Desktop/Shots"
private let finderTestScope = DirectRouteScope(roots: [DirectRouteScopeRoot(canonicalPath: finderScopeRootPath, source: .finderWindowUnderSummonPoint)])

private func makeFinderScriptPlan(_ source: String, scope: DirectRouteScope? = finderTestScope, modifiesData: Bool = true) -> ScriptPlan {
    var scriptPlan = makeScriptPlan(source: source, bundleIdentifier: "com.apple.finder", applicationName: "Finder", modifiesData: modifiesData)
    scriptPlan.fileScope = scope
    return scriptPlan
}

/// The places the inspector names. Since the owner's 2026-09-23 decision they no longer ask on their own (the user
/// read the script and clicked Run), so the gate allows the script unless a verb that asks is present.
private func finderFileReferenceReason(_ scriptPlan: ScriptPlan) throws -> String {
    let reason = try unwrapOrFail(ScriptFileReferenceInspector.confirmationReason(for: scriptPlan, homeDirectoryPath: "/Users/me"))
    try expectEqual(SafetyGate.evaluateScriptPlan(scriptPlan, homeDirectoryPath: "/Users/me"), .allow)
    return reason
}

let scriptFileReferenceInspectorTestSuite = CoreTestSuite(name: "ScriptFileReferenceInspector", testCases: [
    CoreTestCase(name: "POSIX, home-relative and HFS paths outside the scope are named (without asking)") {
        let reason = try finderFileReferenceReason(makeFinderScriptPlan("""
        tell application "Finder"
            duplicate (POSIX file "/Users/me/.ssh/id_ed25519" as alias) to (POSIX file "/Users/me/Desktop/Shots" as alias)
            move file "Macintosh HD:Users:me:Documents:taxes.pdf" to folder "Shots" of desktop
            open (POSIX file "~/Library/Keychains" as alias)
        end tell
        """))
        try expectTrue(reason.contains("“/Users/me/.ssh/id_ed25519”"), reason)
        try expectTrue(reason.contains("“Macintosh HD:Users:me:Documents:taxes.pdf”"), reason)
        try expectTrue(reason.contains("“~/Library/Keychains”"), reason)
        try expectTrue(reason.contains("“of desktop”"), reason)
        try expectTrue(!reason.contains("“/Users/me/Desktop/Shots”"), reason)
    },
    CoreTestCase(name: "a Finder script that stays inside the scope names no places and runs like any data-changing script") {
        let inScopeScript = makeFinderScriptPlan("""
        tell application "Finder"
            set shotsFolder to POSIX file "/Users/me/Desktop/Shots/2026-09" as alias
            make new folder at shotsFolder with properties {name:"Old"}
        end tell
        """)
        try expectEqual(ScriptFileReferenceInspector.confirmationReason(for: inScopeScript, homeDirectoryPath: "/Users/me"), nil)
        try expectEqual(SafetyGate.evaluateScriptPlan(inScopeScript, homeDirectoryPath: "/Users/me"), .allow)

        let readOnlyScript = makeFinderScriptPlan("tell application \"Finder\" to return (count of Finder windows) as text", modifiesData: false)
        try expectEqual(SafetyGate.evaluateScriptPlan(readOnlyScript, homeDirectoryPath: "/Users/me"), .allow)
    },
    CoreTestCase(name: "file verbs without naming a place in the scope are named, with no scope or on Finder's selection") {
        let selectionScript = "tell application \"Finder\" to duplicate (get selection)"
        let noScopeReason = try finderFileReferenceReason(makeFinderScriptPlan(selectionScript, scope: nil, modifiesData: false))
        try expectTrue(noScopeReason.contains("“duplicate”") && noScopeReason.contains("without naming a folder you gave Dotto"), noScopeReason)
        let selectionReason = try finderFileReferenceReason(makeFinderScriptPlan(selectionScript, modifiesData: false))
        try expectTrue(selectionReason.contains("selected"), selectionReason)
    },
    CoreTestCase(name: "path to and JXA special folders count as places; a delete's question names them") {
        let pathToReason = try finderFileReferenceReason(makeFinderScriptPlan(
            "tell application \"Finder\" to set x to (path to documents folder)\nreturn \"ok\"", modifiesData: false))
        try expectTrue(pathToReason.contains("“path to documents folder”"), pathToReason)

        var jxaPlan = makeFinderScriptPlan("var finder = Application(\"Finder\"); finder.home.folders.name();", modifiesData: false)
        jxaPlan.language = .javaScript
        let jxaReason = try finderFileReferenceReason(jxaPlan)
        try expectTrue(jxaReason.contains("“.home”"), jxaReason)

        guard case .requireUserConfirmation(let riskyReason, let riskyCategory) = SafetyGate.evaluateScriptPlan(makeFinderScriptPlan(
            "tell application \"Finder\" to delete (POSIX file \"/Users/me/Documents/a.txt\" as alias)"), homeDirectoryPath: "/Users/me") else {
            throw CoreTestFailure(description: "expected a confirmation")
        }
        try expectEqual(riskyCategory, .deleting)
        try expectTrue(riskyReason.contains("“/Users/me/Documents/a.txt”"), riskyReason)
    },
    CoreTestCase(name: "text that isn't a path is not a place, and other apps' scripts are not checked here") {
        try expectEqual(ScriptFileReferenceInspector.absolutePath(ofWrittenPath: "Note: done", homeDirectoryPath: "/Users/me"), nil)
        try expectEqual(ScriptFileReferenceInspector.absolutePath(ofWrittenPath: "10:30", homeDirectoryPath: "/Users/me"), nil)
        try expectEqual(ScriptFileReferenceInspector.absolutePath(ofWrittenPath: "https://example.com/a", homeDirectoryPath: "/Users/me"), nil)
        try expectEqual(ScriptFileReferenceInspector.absolutePath(ofWrittenPath: "Backup:Photos:", homeDirectoryPath: "/Users/me"),
                        "/Volumes/Backup/Photos")
        let mailScript = makeScriptPlan(source: "tell application \"Mail\" to count (messages of mailbox \"/Users/me/.ssh\")")
        try expectEqual(ScriptFileReferenceInspector.confirmationReason(for: mailScript, homeDirectoryPath: "/Users/me"), nil)
    },
])
