import Foundation

enum SafetyGate {
    /// The user approved the checklist, items and all, so an item's own wording never asks: the actions it leads to
    /// are checked one by one. A taught routine's steps whose category asks (`asksUser`) still ask up front.
    static func evaluateChecklistItem(_ item: ChecklistItem) -> SafetyVerdict {
        if let routineStepRiskCategory = item.confirmationRiskCategoriesFromRoutine.first(where: \.asksUser) {
            return .requireUserConfirmation(
                reason: "This item's routine includes a step that needs your OK (\(routineStepRiskCategory.userFacingScopeDescription)).",
                riskCategory: routineStepRiskCategory)
        }
        return .allow
    }

    /// Only categories that ask (`SafetyRiskCategory.asksUser`) reach the user; the rest run.
    static func applyingAskPolicy(_ verdict: SafetyVerdict) -> SafetyVerdict {
        if case .requireUserConfirmation(_, let riskCategory) = verdict, !riskCategory.asksUser { return .allow }
        return verdict
    }

    /// Every action is classified into a risk category, failing closed: anything Dotto can't identify as harmless
    /// gets one. Only categories that ask reach the user (`applyingAskPolicy`). A confirmation only ever covers its
    /// own risk category: the category the user confirmed this item under, or one they allowed for the rest of the
    /// task. Password-field typing is denied regardless of any confirmation.
    static func evaluateAction(_ action: AgentAction, targetNode: AccessibilityElementNode?,
                               riskCategoryConfirmedForThisItem: SafetyRiskCategory?,
                               riskCategoriesAllowedForRestOfTask: Set<SafetyRiskCategory> = [],
                               focusedNode: AccessibilityElementNode? = nil,
                               targetApplicationBundleIdentifier: String? = nil,
                               uploadFileAllowlist: UploadFileAllowlist = .empty) -> SafetyVerdict {
        if actionWritesText(action), (targetNode ?? focusedNode)?.isSecureTextField == true {
            return .deny(reasonForModel: "Typing into password fields is not allowed.")
        }
        guard case .requireUserConfirmation(let reason, let riskCategory) = applyingAskPolicy(unconfirmedActionVerdict(
                  action, targetNode: targetNode, focusedNode: focusedNode,
                  targetApplicationBundleIdentifier: targetApplicationBundleIdentifier, uploadFileAllowlist: uploadFileAllowlist)),
              riskCategory != riskCategoryConfirmedForThisItem,
              !riskCategoriesAllowedForRestOfTask.contains(riskCategory) else {
            return .allow
        }
        return .requireUserConfirmation(reason: reason, riskCategory: riskCategory)
    }

    /// True when the action falls in any risk category, asked or not. Such actions (sends, deletes, submit keys,
    /// unidentifiable clicks) make an item unsafe to retry automatically: a second submit could act twice.
    static func actionIsRiskyWithoutAnyGrant(_ action: AgentAction, targetNode: AccessibilityElementNode?,
                                             focusedNode: AccessibilityElementNode? = nil,
                                             targetApplicationBundleIdentifier: String? = nil) -> Bool {
        if actionWritesText(action), (targetNode ?? focusedNode)?.isSecureTextField == true { return true }
        return unconfirmedActionVerdict(action, targetNode: targetNode, focusedNode: focusedNode,
                                        targetApplicationBundleIdentifier: targetApplicationBundleIdentifier) != .allow
    }

    private static func actionWritesText(_ action: AgentAction) -> Bool {
        switch action {
        case .typeText, .replaceText: return true
        case .clickElement, .pressKey, .scroll, .clickScreenshotPoint, .uploadFiles: return false
        }
    }

    private static func unconfirmedActionVerdict(_ action: AgentAction, targetNode: AccessibilityElementNode?,
                                                 focusedNode: AccessibilityElementNode?,
                                                 targetApplicationBundleIdentifier: String?,
                                                 uploadFileAllowlist: UploadFileAllowlist = .empty) -> SafetyVerdict {
        switch action {
        case .typeText(_, let text, _, let pressReturnAfter):
            if pressReturnAfter || text.contains(where: \.isNewline) {
                if applicationSendsOnPlainReturn(targetApplicationBundleIdentifier) {
                    return .requireUserConfirmation(reason: "This step will type a message and press Return, which sends it in this app.",
                                                    riskCategory: .sendingOrPublishing)
                }
                return returnVerdict(reason: "This step will type text and press Return, which often sends or submits.",
                                     targetApplicationBundleIdentifier: targetApplicationBundleIdentifier)
            }
            return .allow

        case .replaceText(_, _, let replacementText, _, _):
            // A line break set into a field can submit it just like a typed Return, so it is classified the same way.
            if replacementText.contains(where: \.isNewline) {
                if applicationSendsOnPlainReturn(targetApplicationBundleIdentifier) {
                    return .requireUserConfirmation(reason: "This step will put a line break into a message, which sends it in this app.",
                                                    riskCategory: .sendingOrPublishing)
                }
                return returnVerdict(reason: "This step will put a line break into the text, which often sends or submits.",
                                     targetApplicationBundleIdentifier: targetApplicationBundleIdentifier)
            }
            return .allow

        case .pressKey(let keyName, let modifiers):
            if isClipboardPasteShortcut(keyName: keyName, modifiers: modifiers) {
                return .requireUserConfirmation(
                    reason: "This step will paste: whatever is on your clipboard right now will be inserted into the app.",
                    riskCategory: .pastingClipboard)
            }
            return pressKeyVerdict(canonicalKeyName: canonicalKeyName(keyName), modifiers: Set(modifiers),
                                   focusedNode: focusedNode, targetApplicationBundleIdentifier: targetApplicationBundleIdentifier)

        case .clickElement:
            return clickVerdict(targetNode: targetNode)

        case .clickScreenshotPoint:
            return .requireUserConfirmation(reason: "This step clicks a screen position, so Dotto can't tell what it will hit.",
                                            riskCategory: .unverifiableClick)

        case .scroll:
            return .allow

        case .uploadFiles(_, let filePaths):
            let fileNames = filePaths.map { "“\(($0 as NSString).lastPathComponent)”" }
            // A rest-of-task grant covers every upload in the task, so the card says what that can reach.
            return .requireUserConfirmation(
                reason: "This step opens the file dialog and attaches \(namedListDescription(fileNames, maximumNamedCount: 5)). "
                    + "Dotto brings the app forward for a few seconds to do it, then puts your windows back. "
                    + "Allowing uploads for the rest of this task covers only what you attached: \(uploadFileAllowlist.userFacingCoverageDescription).",
                riskCategory: .uploadingFiles)
        }
    }

    /// Asked when background input didn't take effect. Only a `.bringingAppForward` confirmation or grant covers it:
    /// an upload grant, or an item confirmed for any other reason, never brings an app forward.
    static func evaluateForegroundAssist(failedActionDescription: String, targetApplicationName: String,
                                         riskCategoryConfirmedForThisItem: SafetyRiskCategory?,
                                         riskCategoriesAllowedForRestOfTask: Set<SafetyRiskCategory>) -> SafetyVerdict {
        if riskCategoryConfirmedForThisItem == .bringingAppForward || riskCategoriesAllowedForRestOfTask.contains(.bringingAppForward) {
            return .allow
        }
        return .requireUserConfirmation(
            reason: "Dotto's \(failedActionDescription) didn't reach \(targetApplicationName) while it stayed in the background. "
                + "Bring \(targetApplicationName) forward for a moment to retry it? Dotto switches back to where you were right after.",
            riskCategory: .bringingAppForward)
    }

    /// "a, b and c", or the first `maximumNamedCount` names followed by "and N more".
    static func namedListDescription(_ names: [String], maximumNamedCount: Int) -> String {
        if names.count > maximumNamedCount {
            return names.prefix(maximumNamedCount).joined(separator: ", ") + " and \(names.count - maximumNamedCount) more"
        }
        guard names.count > 1, let lastName = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + lastName
    }

    /// ⌘V with any extra modifiers (⇧⌘V, ⌥⇧⌘V "paste and match style") still inserts the clipboard, which may hold a
    /// password or private text the user copied earlier. ⌃ isn't a clipboard modifier on macOS, so a chord with ⌃ is
    /// left to the other rules.
    static func isClipboardPasteShortcut(keyName: String, modifiers: [AgentKeyModifier]) -> Bool {
        let modifierSet = Set(modifiers)
        return modifierSet.contains(.command) && !modifierSet.contains(.control) && canonicalKeyName(keyName) == "v"
    }

    private static func clickVerdict(targetNode: AccessibilityElementNode?) -> SafetyVerdict {
        guard let targetNode else {
            return .requireUserConfirmation(reason: "This step clicks an element Dotto can't identify.",
                                            riskCategory: .unverifiableClick)
        }
        let labelTexts = clickTargetLabelTexts(targetNode)
        guard let displayedName = labelTexts.first else {
            return .requireUserConfirmation(reason: "This step clicks an unlabeled element, so Dotto can't tell what it does.",
                                            riskCategory: .unverifiableClick)
        }
        if let riskMatch = SafetyRiskVocabulary.mostSevereRiskMatch(among: labelTexts.flatMap { SafetyRiskVocabulary.riskMatches(in: $0) }) {
            return .requireUserConfirmation(reason: "This step will click “\(displayedName)”.", riskCategory: riskMatch.riskCategory)
        }
        return .allow
    }

    /// Space and Return activate the focused control the same way a click does.
    private static let keyboardActivatableRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXLink", "AXMenuItem", "AXDisclosureTriangle",
    ]

    /// Control-M and Control-J type a carriage return and a line feed in Cocoa text views, and Control-O inserts a
    /// line break, so each can submit a field just like Return.
    private static let returnEquivalentControlKeyNames: Set<String> = ["m", "j", "o"]

    struct KeyChord: Hashable, Sendable {
        var canonicalKeyName: String
        var modifiers: Set<AgentKeyModifier>
    }

    /// Apps whose send shortcut isn't caught by the generic rules below (or would be filed under "pressing Return"),
    /// keyed by lowercased bundle identifier. Web mail such as Gmail is handled by the browser backend.
    static let sendShortcutsByLowercasedBundleIdentifier: [String: Set<KeyChord>] = [
        "com.apple.mail": [KeyChord(canonicalKeyName: "d", modifiers: [.command, .shift])],
        "com.apple.mobilesms": [KeyChord(canonicalKeyName: "return", modifiers: [])],
        "com.tinyspeck.slackmacgap": [KeyChord(canonicalKeyName: "return", modifiers: [])],
        "com.hnc.discord": [KeyChord(canonicalKeyName: "return", modifiers: [])],
        "com.microsoft.outlook": [KeyChord(canonicalKeyName: "return", modifiers: [.command])],
    ]

    private static func applicationSendsOnPlainReturn(_ targetApplicationBundleIdentifier: String?) -> Bool {
        guard let lowercasedBundleIdentifier = targetApplicationBundleIdentifier?.lowercased() else { return false }
        return sendShortcutsByLowercasedBundleIdentifier[lowercasedBundleIdentifier]?
            .contains(KeyChord(canonicalKeyName: "return", modifiers: [])) == true
    }

    /// Chat apps without a listed send shortcut: Return sends a message there too.
    static let chatApplicationLowercasedBundleIdentifiers: Set<String> = [
        "net.whatsapp.whatsapp", "desktop.whatsapp", "ru.keepcoder.telegram", "org.telegram.desktop",
        "org.whispersystems.signal-desktop", "com.facebook.archon", "com.microsoft.teams", "com.microsoft.teams2",
    ]

    /// Where Return sends a message or submits a web form, so it asks as a send, while Return elsewhere (a new line
    /// in a document, a rename) runs without asking.
    static func applicationTreatsReturnAsSend(_ targetApplicationBundleIdentifier: String?) -> Bool {
        guard let lowercasedBundleIdentifier = targetApplicationBundleIdentifier?.lowercased() else { return false }
        return applicationSendsOnPlainReturn(lowercasedBundleIdentifier)
            || chatApplicationLowercasedBundleIdentifiers.contains(lowercasedBundleIdentifier)
            || TargetApplicationKindClassifier.webKitBrowserBundleIdentifiers.contains(lowercasedBundleIdentifier)
            || TargetApplicationKindClassifier.chromiumBrowserBundleIdentifiers.contains(lowercasedBundleIdentifier)
    }

    private static func returnVerdict(reason: String, targetApplicationBundleIdentifier: String?) -> SafetyVerdict {
        if applicationTreatsReturnAsSend(targetApplicationBundleIdentifier) {
            return .requireUserConfirmation(
                reason: reason.replacingOccurrences(of: "which often sends or submits", with: "which sends or submits in this app"),
                riskCategory: .sendingOrPublishing)
        }
        return .requireUserConfirmation(reason: reason, riskCategory: .pressingReturn)
    }

    private static func pressKeyVerdict(canonicalKeyName: String, modifiers: Set<AgentKeyModifier>,
                                        focusedNode: AccessibilityElementNode?, targetApplicationBundleIdentifier: String?) -> SafetyVerdict {
        let pressedChord = KeyChord(canonicalKeyName: canonicalKeyName, modifiers: modifiers)
        if let lowercasedBundleIdentifier = targetApplicationBundleIdentifier?.lowercased(),
           sendShortcutsByLowercasedBundleIdentifier[lowercasedBundleIdentifier]?.contains(pressedChord) == true {
            return .requireUserConfirmation(reason: "This step will press \(displayName(of: pressedChord)), which sends in this app.",
                                            riskCategory: .sendingOrPublishing)
        }
        let isCommandShortcut = modifiers.contains(.command)
        if (canonicalKeyName == "return" || canonicalKeyName == "space") && !isCommandShortcut,
           let focusedNode, keyboardActivatableRoles.contains(focusedNode.role),
           case .requireUserConfirmation(let reason, let riskCategory) = clickVerdict(targetNode: focusedNode),
           // Where Return sends, a focused control whose category doesn't ask ("Submit", unlabeled) still asks as a send below.
           riskCategory.asksUser || canonicalKeyName != "return" || !applicationTreatsReturnAsSend(targetApplicationBundleIdentifier) {
            return .requireUserConfirmation(reason: "Pressing \(displayName(of: pressedChord)) activates the focused control. \(reason)",
                                            riskCategory: riskCategory)
        }
        if canonicalKeyName == "return" {
            return returnVerdict(reason: "This step will press \(isCommandShortcut ? "⌘" : "")Return, which often sends or submits.",
                                 targetApplicationBundleIdentifier: targetApplicationBundleIdentifier)
        }
        if modifiers.contains(.control) && !isCommandShortcut && returnEquivalentControlKeyNames.contains(canonicalKeyName) {
            return returnVerdict(reason: "This step will press \(displayName(of: pressedChord)), which acts like Return in text fields.",
                                 targetApplicationBundleIdentifier: targetApplicationBundleIdentifier)
        }
        if isCommandShortcut && (canonicalKeyName == "delete" || canonicalKeyName == "forward_delete") {
            return .requireUserConfirmation(reason: "This step will press a ⌘Delete shortcut, which usually deletes something.",
                                            riskCategory: .deleting)
        }
        if isCommandShortcut && (canonicalKeyName == "q" || canonicalKeyName == "w") {
            return .requireUserConfirmation(reason: "This step will press ⌘\(canonicalKeyName.uppercased()), which quits the app or closes a window.",
                                            riskCategory: .quittingOrClosing)
        }
        return .allow
    }

    /// e.g. "⌃⇧⌘D", "Return", "Space".
    static func displayName(of keyChord: KeyChord) -> String {
        let modifierSymbols = [(AgentKeyModifier.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { keyChord.modifiers.contains($0.0) }.map(\.1).joined()
        let keyDisplayName = keyChord.canonicalKeyName.count == 1 ? keyChord.canonicalKeyName.uppercased()
            : keyChord.canonicalKeyName.replacingOccurrences(of: "_", with: " ").capitalized
        return modifierSymbols + keyDisplayName
    }

    /// Maps the aliases a model might use onto one name per physical key, so a rule for "return" can't be
    /// sidestepped with "enter" or "kp_enter".
    static func canonicalKeyName(_ rawKeyName: String) -> String {
        // Checked before trimming, which would turn a literal space into an empty name.
        if rawKeyName == " " || rawKeyName == "\u{00A0}" { return "space" }
        let normalizedKeyName = rawKeyName.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        switch normalizedKeyName {
        case "return", "enter", "kp_enter", "keypad_enter", "numpad_enter", "num_enter", "kpenter", "carriage_return",
             "cr", "newline", "linefeed", "\n", "\r", "↩", "↵", "⏎", "⌤":
            return "return"
        case "delete", "backspace", "back_space", "bksp", "del", "⌫":
            return "delete"
        case "forward_delete", "forwarddelete", "fwd_delete", "delete_forward", "⌦":
            return "forward_delete"
        case "esc", "escape", "⎋":
            return "escape"
        case "space", "spacebar", "space_bar", "␣":
            return "space"
        default:
            return normalizedKeyName
        }
    }

    /// The button's own texts plus those of its first two levels of children, since many buttons carry
    /// their visible title in a child static text.
    private static func clickTargetLabelTexts(_ targetNode: AccessibilityElementNode) -> [String] {
        func ownTexts(of node: AccessibilityElementNode) -> [String] {
            [node.title, node.elementDescription, node.value, node.helpText, node.placeholder]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        var labelTexts = ownTexts(of: targetNode)
        for childNode in targetNode.children {
            labelTexts += ownTexts(of: childNode)
            for grandchildNode in childNode.children { labelTexts += ownTexts(of: grandchildNode) }
        }
        return labelTexts
    }
}
