import AppKit
import ApplicationServices

/// Which folder the Finder window the user summoned Dotto over shows, and which items are selected in it, so "sort
/// these" has a scope root without the user typing a path. Read-only. The result is raw paths; the caller
/// canonicalizes the folder and runs it through `FileOperationScopePolicy`, which refuses Recents, smart folders, the
/// iCloud Drive root under ~/Library and anything else that isn't an ordinary folder.
enum FinderWindowFolderResolver {
    static let finderBundleIdentifier = "com.apple.finder"
    private static let accessibilityMessagingTimeoutSeconds: Float = 1

    /// AX first: the Finder window whose frame contains the summon point (else the focused window), and its
    /// AXDocument (a file URL). Finder leaves AXDocument unset on its windows, so the folder normally comes from a
    /// fixed, read-only AppleScript over Finder windows' bounds and targets, choosing the frontmost window whose bounds
    /// contain the point. With `mayPromptForAutomation`, macOS may ask the user once to let Dotto control Finder: the
    /// user has just summoned Dotto over this window, and without its folder a file chore can't take a direct route.
    static func windowContents(forFinderProcessIdentifier processIdentifier: Int32,
                               summonOriginInTopLeftGlobalPoints: CGPoint?,
                               mayPromptForAutomation: Bool) async -> FinderWindowContents? {
        let accessibilityFolderPath = await Task.detached(priority: .userInitiated) {
            folderPathThroughAccessibility(finderProcessIdentifier: processIdentifier,
                                           summonOriginInTopLeftGlobalPoints: summonOriginInTopLeftGlobalPoints)
        }.value

        var finderAutomationState = await AutomationPermissionProbe.permissionState(
            forBundleIdentifier: finderBundleIdentifier, mayPromptUser: false)
        if finderAutomationState == .notYetAsked && mayPromptForAutomation {
            finderAutomationState = await AutomationPermissionProbe.permissionState(
                forBundleIdentifier: finderBundleIdentifier, mayPromptUser: true)
        }
        guard finderAutomationState == .granted else {
            return accessibilityFolderPath.map { FinderWindowContents(folderPath: $0, selectedItemPaths: []) }
        }
        return await windowContentsThroughAppleScript(summonOriginInTopLeftGlobalPoints: summonOriginInTopLeftGlobalPoints,
                                                      accessibilityFolderPath: accessibilityFolderPath)
    }

    // MARK: - Accessibility

    private static func folderPathThroughAccessibility(finderProcessIdentifier: Int32,
                                                       summonOriginInTopLeftGlobalPoints: CGPoint?) -> String? {
        let finderApplicationElement = AXUIElementCreateApplication(finderProcessIdentifier)
        AXUIElementSetMessagingTimeout(finderApplicationElement, accessibilityMessagingTimeoutSeconds)
        // Finder lists its windows front to back, so the first one containing the point is the one the user sees there.
        let finderWindows = AccessibilityElementReader.elementArrayAttribute(kAXWindowsAttribute, of: finderApplicationElement)
        var chosenWindow: AXUIElement?
        if let summonOriginInTopLeftGlobalPoints {
            chosenWindow = finderWindows.first { finderWindow in
                AccessibilityElementReader.frameInTopLeftGlobalPoints(of: finderWindow)?.contains(summonOriginInTopLeftGlobalPoints) == true
            }
        }
        if chosenWindow == nil {
            chosenWindow = AccessibilityElementReader.elementAttribute(kAXFocusedWindowAttribute, of: finderApplicationElement)
        }
        guard let chosenWindow,
              let documentURLText = AccessibilityElementReader.stringAttribute(kAXDocumentAttribute, of: chosenWindow) else { return nil }
        return folderPath(fromFileURLText: documentURLText)
    }

    static func folderPath(fromFileURLText fileURLText: String) -> String? {
        guard let documentURL = URL(string: fileURLText), documentURL.isFileURL else { return nil }
        let documentPath = documentURL.path
        return documentPath.hasPrefix("/") ? documentPath : nil
    }

    // MARK: - AppleScript

    /// Fixed source, no model or user text. Each window line is "W<tab>left,top,right,bottom<tab>POSIX path"; windows
    /// whose target isn't a real folder (Recents, smart folders, AirDrop) fail the `as alias` coercion and are skipped.
    /// Then one "S<tab>POSIX path" line per item selected in the front Finder window. The loop goes by index:
    /// `repeat with … in (every Finder window)` came back empty in a live probe.
    private static let finderWindowTargetsScriptSource = """
    with timeout of 3 seconds
        tell application id "com.apple.finder"
            set outputLines to ""
            repeat with windowIndex from 1 to (count of Finder windows)
                try
                    set finderWindow to Finder window windowIndex
                    set windowBounds to bounds of finderWindow
                    set targetPath to POSIX path of ((target of finderWindow) as alias)
                    set outputLines to outputLines & "W" & tab & (item 1 of windowBounds) & "," & (item 2 of windowBounds) & "," & (item 3 of windowBounds) & "," & (item 4 of windowBounds) & tab & targetPath & linefeed
                end try
            end repeat
            try
                set selectedItems to selection
                repeat with itemIndex from 1 to (count of selectedItems)
                    try
                        set outputLines to outputLines & "S" & tab & (POSIX path of ((item itemIndex of selectedItems) as alias)) & linefeed
                    end try
                end repeat
            end try
            return outputLines
        end tell
    end timeout
    """

    @MainActor
    private static func windowContentsThroughAppleScript(summonOriginInTopLeftGlobalPoints: CGPoint?,
                                                         accessibilityFolderPath: String?) -> FinderWindowContents? {
        guard let finderWindowTargetsScript = NSAppleScript(source: finderWindowTargetsScriptSource) else {
            return accessibilityFolderPath.map { FinderWindowContents(folderPath: $0, selectedItemPaths: []) }
        }
        var scriptErrorInfo: NSDictionary?
        guard let outputText = finderWindowTargetsScript.executeAndReturnError(&scriptErrorInfo).stringValue else {
            return accessibilityFolderPath.map { FinderWindowContents(folderPath: $0, selectedItemPaths: []) }
        }
        return FinderWindowScriptOutput.chosenWindowContents(fromScriptOutputText: outputText,
                                                             summonOriginInTopLeftGlobalPoints: summonOriginInTopLeftGlobalPoints,
                                                             accessibilityFolderPath: accessibilityFolderPath)
    }
}
