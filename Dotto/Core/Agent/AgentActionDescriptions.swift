import Foundation

/// How an AgentAction is named in the cursor caption and the audit log, and which element it targets.
enum AgentActionDescriptions {
    static func targetElementIdentifier(of agentAction: AgentAction) -> String? {
        switch agentAction {
        case .clickElement(let elementIdentifier, _): return elementIdentifier
        case .typeText(let elementIdentifier, _, _, _): return elementIdentifier
        case .scroll(let elementIdentifier, _, _): return elementIdentifier
        case .uploadFiles(let elementIdentifier, _): return elementIdentifier
        case .pressKey, .clickScreenshotPoint: return nil
        }
    }

    static func progressDescription(of agentAction: AgentAction, targetNode: AccessibilityElementNode?) -> String {
        let targetName = [targetNode?.title, targetNode?.elementDescription, targetNode?.placeholder]
            .compactMap { $0 }.first { !$0.isEmpty }
        switch agentAction {
        case .clickElement(let elementIdentifier, _):
            return "Clicking “\(targetName ?? elementIdentifier)”"
        case .typeText(_, let text, _, _):
            return "Typing “\(text.prefix(40))”"
        case .pressKey(let keyName, let modifiers):
            return "Pressing " + (modifiers.map(\.rawValue) + [keyName]).joined(separator: "+")
        case .scroll(_, let direction, _):
            return "Scrolling \(direction.rawValue)"
        case .clickScreenshotPoint(let screenshotPixelPoint, _):
            return "Clicking at (\(Int(screenshotPixelPoint.x)), \(Int(screenshotPixelPoint.y)))"
        case .uploadFiles(_, let filePaths):
            return "Attaching \(fileCountText(filePaths.count))"
        }
    }

    /// Completes "Dotto's … didn't reach <App>" in the bring-forward card, and names the action in the audit log.
    /// Never contains typed text or paths.
    static func foregroundAssistActionDescription(of agentAction: AgentAction) -> String {
        switch agentAction {
        case .clickElement(_, let clickType), .clickScreenshotPoint(_, let clickType):
            return clickType == .single ? "click" : "\(clickType.rawValue) click"
        case .typeText: return "typing"
        case .pressKey(let keyName, let modifiers):
            return "key press " + SafetyGate.displayName(of: SafetyGate.KeyChord(canonicalKeyName: SafetyGate.canonicalKeyName(keyName),
                                                                                 modifiers: Set(modifiers)))
        case .scroll: return "scroll"
        case .uploadFiles(_, let filePaths): return "upload of \(fileCountText(filePaths.count))"
        }
    }

    static func fileCountText(_ fileCount: Int) -> String { fileCount == 1 ? "1 file" : "\(fileCount) files" }

    static let maximumAuditedToolTextLength = 200

    /// Typed text never reaches the log: type_text's "text" is replaced by its fingerprint (hash prefix + length).
    /// upload_files keeps only the file names, because the folders above them can be personal.
    static func auditSummary(ofToolInput toolInput: JSONValue, toolName: String) -> String {
        var auditedInput = toolInput
        if toolName == AgentToolName.typeText.rawValue, case .object(var inputFields) = toolInput,
           let typedText = inputFields["text"]?.stringValue {
            inputFields["text"] = .string(AuditLogRedaction.fingerprint(of: typedText))
            auditedInput = .object(inputFields)
        }
        if toolName == AgentToolName.uploadFiles.rawValue, case .object(var inputFields) = toolInput,
           let requestedFilePaths = inputFields["file_paths"]?.arrayValue {
            inputFields["file_paths"] = .array(requestedFilePaths.map { .string(($0.stringValue.map { ($0 as NSString).lastPathComponent }) ?? "") })
            inputFields["file_count"] = .number(Double(requestedFilePaths.count))
            auditedInput = .object(inputFields)
        }
        guard let inputText = CanonicalJSONEncoding.encodedText(auditedInput) else { return "" }
        return String(inputText.prefix(maximumAuditedToolTextLength))
    }

    /// Only the status is logged: the first line, plus for a successful action the backend's one-line report
    /// (e.g. "ok: … pressed e12"). Outlines that follow can echo field values, including text Dotto just typed.
    static func auditSummary(ofToolResultText toolResultText: String) -> String {
        let openingTrustTag = "<\(PromptLibrary.untrustedUserInterfaceTagName)>"
        let meaningfulLines = Array(toolResultText.split(separator: "\n").lazy.filter { $0 != openingTrustTag }.prefix(2).map(String.init))
        guard let firstMeaningfulLine = meaningfulLines.first else { return "" }
        var summary = firstMeaningfulLine
        if firstMeaningfulLine == ChecklistItemAgentLoop.actionSucceededText, meaningfulLines.count > 1 {
            summary += " " + meaningfulLines[1]
        }
        return String(summary.prefix(maximumAuditedToolTextLength))
    }
}
