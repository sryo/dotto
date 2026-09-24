import Foundation
import CoreGraphics

/// Turns tool_use blocks into typed calls. Kept apart from AgentToolCatalog's schemas because the two change for
/// different reasons: a new tool adds a schema there and a decode rule here.
enum AgentToolCallDecoder {
    /// Set by ClaudeServerSentEventAccumulator when streamed tool input is not valid JSON.
    static let invalidJSONSentinelKey = "__invalid_json__"

    /// Validates types and enums even though strict schemas guarantee them: the invalid-JSON sentinel path and
    /// numeric ranges (which strict schemas can't express) still need checking.
    static func decodeToolCall(_ toolUse: ClaudeToolUseBlock) -> Result<AgentToolCall, AgentToolInputError> {
        decodeToolInput(toolUse) { toolName, inputReader in try decodeToolCall(toolName: toolName, inputReader: inputReader) }
    }

    static func decodeSubmittedRoutineDraft(_ toolUse: ClaudeToolUseBlock) -> Result<SubmittedRoutineDraft, AgentToolInputError> {
        decodeToolInput(toolUse) { toolName, inputReader in
            guard toolName == .submitRoutine else {
                throw AgentToolInputError(messageForModel: "Only submit_routine is available here.")
            }
            return try decodeSubmittedRoutineDraft(inputReader: inputReader)
        }
    }

    private static func decodeToolInput<DecodedInput>(_ toolUse: ClaudeToolUseBlock,
                                                      _ decodeFields: (AgentToolName, ToolInputReader) throws -> DecodedInput)
        -> Result<DecodedInput, AgentToolInputError> {
        guard let inputObject = toolUse.input.objectValue else {
            return .failure(AgentToolInputError(messageForModel: "Tool input for \(toolUse.toolName) must be a JSON object."))
        }
        if let rawInvalidJSON = inputObject[invalidJSONSentinelKey]?.stringValue {
            return .failure(AgentToolInputError(messageForModel: invalidJSONMessage(rawInvalidJSON: rawInvalidJSON)))
        }
        guard let toolName = AgentToolName(rawValue: toolUse.toolName) else {
            return .failure(AgentToolInputError(messageForModel: "Unknown tool \"\(toolUse.toolName)\"."))
        }
        do {
            return .success(try decodeFields(toolName, ToolInputReader(toolName: toolName, inputObject: inputObject)))
        } catch let toolInputError as AgentToolInputError {
            return .failure(toolInputError)
        } catch {
            return .failure(AgentToolInputError(messageForModel: "Invalid input for \(toolName.rawValue)."))
        }
    }

    private static func invalidJSONMessage(rawInvalidJSON: String) -> String {
        CanonicalJSONEncoding.encodedText(["INVALID_JSON": rawInvalidJSON]) ?? "INVALID_JSON"
    }

    private static func decodeToolCall(toolName: AgentToolName, inputReader: ToolInputReader) throws -> AgentToolCall {
        switch toolName {
        case .readUserInterface:
            return .readUserInterface(ReadUserInterfaceRequest(
                scope: try inputReader.requiredEnum("scope"),
                applicationName: try inputReader.optionalNonEmptyString("application_name"),
                query: try inputReader.optionalNonEmptyString("query")))
        case .screenshot:
            return .screenshot
        case .click:
            guard let elementIdentifier = try inputReader.optionalNonEmptyString("element_id") else {
                throw AgentToolInputError(messageForModel: "Invalid input for click: `element_id` must be an id like e42.")
            }
            return .action(.clickElement(elementIdentifier: elementIdentifier, clickType: try inputReader.requiredEnum("click_type")))
        case .typeText:
            return .action(.typeText(elementIdentifier: try inputReader.optionalNonEmptyString("element_id"),
                                     text: try inputReader.requiredString("text"),
                                     replaceExistingText: try inputReader.requiredBool("replace_existing_text"),
                                     pressReturnAfter: try inputReader.requiredBool("press_return_after")))
        case .replaceText:
            return .action(try decodeReplaceTextAction(inputReader: inputReader))
        case .pressKey:
            let keyName = try inputReader.requiredString("key").trimmingCharacters(in: .whitespaces).lowercased()
            guard !keyName.isEmpty else {
                throw AgentToolInputError(messageForModel: "Invalid input for press_key: `key` must not be empty.")
            }
            return .action(.pressKey(keyName: keyName, modifiers: try inputReader.requiredEnumArray("modifiers")))
        case .scroll:
            return .action(.scroll(elementIdentifier: try inputReader.optionalNonEmptyString("element_id"),
                                   direction: try inputReader.requiredEnum("direction"),
                                   pages: try inputReader.requiredInteger("pages", clampedTo: 1...10)))
        case .clickPoint:
            let pixelX = try inputReader.requiredInteger("x", clampedTo: Int.min...Int.max)
            let pixelY = try inputReader.requiredInteger("y", clampedTo: Int.min...Int.max)
            return .action(.clickScreenshotPoint(screenshotPixelPoint: CGPoint(x: pixelX, y: pixelY),
                                                 clickType: try inputReader.requiredEnum("click_type")))
        case .uploadFiles:
            guard let elementIdentifier = try inputReader.optionalNonEmptyString("element_id") else {
                throw AgentToolInputError(messageForModel: "Invalid input for upload_files: `element_id` must be an id like e42.")
            }
            let filePathValues = inputReader.inputObject["file_paths"]?.arrayValue ?? []
            let filePaths = filePathValues.compactMap(\.stringValue)
            guard (1...UploadFileAllowlist.maximumFilesPerUpload).contains(filePaths.count), filePaths.count == filePathValues.count,
                  !filePaths.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
                throw AgentToolInputError(messageForModel:
                    "Invalid input for upload_files: `file_paths` must list 1-\(UploadFileAllowlist.maximumFilesPerUpload) absolute paths.")
            }
            return .action(.uploadFiles(elementIdentifier: elementIdentifier, filePaths: filePaths))
        case .waitFor:
            return .waitFor(text: try inputReader.requiredString("text"),
                            timeoutSeconds: try inputReader.requiredInteger("timeout_seconds", clampedTo: 1...15))
        case .finishItem:
            return .finishItem(outcome: try inputReader.requiredEnum("outcome"), summary: try inputReader.requiredString("summary"))
        case .askUser:
            return .askUser(try decodePlannerQuestion(inputReader: inputReader))
        case .submitPlan:
            return .submitPlan(try decodeSubmittedChecklistDraft(inputReader: inputReader))
        case .submitRoutine:
            throw AgentToolInputError(messageForModel: "submit_routine is only available when compiling a routine.")
        case .listFolder, .readFileMetadata, .listShortcuts, .submitFileOperationsPlan, .submitScriptPlan, .submitShortcutPlan:
            return try decodeDirectRouteToolCall(toolName: toolName, inputReader: inputReader)
        }
    }

    /// replace_text is sent without a strict schema, so every field and the combinations between them are checked here.
    private static func decodeReplaceTextAction(inputReader: ToolInputReader) throws -> AgentAction {
        guard let elementIdentifier = try inputReader.optionalNonEmptyString("element_id") else {
            throw AgentToolInputError(messageForModel: "Invalid input for replace_text: `element_id` must be an id like e42.")
        }
        let findText = try inputReader.requiredString("find")
        let replacementText = try inputReader.requiredString("replace_with")
        let occurrence: TextReplacementOccurrence = try inputReader.requiredEnum("occurrence")
        let insertionPosition: TextInsertionPosition = try inputReader.requiredEnum("position")
        if findText.isEmpty {
            guard insertionPosition != .atFind else {
                throw AgentToolInputError(messageForModel:
                    "Invalid input for replace_text: with an empty `find`, `position` must be start or end.")
            }
            guard !replacementText.isEmpty else {
                throw AgentToolInputError(messageForModel:
                    "Invalid input for replace_text: `find` and `replace_with` are both empty, so there is nothing to change.")
            }
        } else {
            guard insertionPosition == .atFind else {
                throw AgentToolInputError(messageForModel:
                    "Invalid input for replace_text: `position` must be at_find when `find` is not empty.")
            }
            guard findText != replacementText else {
                throw AgentToolInputError(messageForModel:
                    "Invalid input for replace_text: `replace_with` equals `find`, so nothing would change.")
            }
        }
        return .replaceText(elementIdentifier: elementIdentifier, findText: findText, replacementText: replacementText,
                            occurrence: occurrence, insertionPosition: insertionPosition)
    }

    /// nil for an absent or null field, kind none, empty text, or a malformed object: the action itself still runs.
    static func decodeStepExpectation(fromToolInput toolInput: JSONValue, fieldName: String) -> StepExpectation? {
        guard let expectationObject = toolInput[fieldName]?.objectValue,
              let kind = expectationObject["kind"]?.stringValue.flatMap(StepExpectationKind.init(rawValue:)), kind != .none,
              let text = expectationObject["text"]?.stringValue,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return StepExpectation(kind: kind, text: text)
    }

    private static func decodeSubmittedRoutineDraft(inputReader: ToolInputReader) throws -> SubmittedRoutineDraft {
        guard let stepJSONValues = inputReader.inputObject["steps"]?.arrayValue else {
            throw inputReader.typeError(fieldName: "steps", expectedDescription: "an array")
        }
        let draftSteps = try stepJSONValues.map { stepJSONValue -> SubmittedRoutineDraftStep in
            guard let stepObject = stepJSONValue.objectValue else {
                throw inputReader.typeError(fieldName: "steps", expectedDescription: "an array of objects")
            }
            let stepReader = ToolInputReader(toolName: .submitRoutine, inputObject: stepObject)
            return SubmittedRoutineDraftStep(eventIndex: try stepReader.requiredInteger("event_index", clampedTo: Int.min...Int.max),
                                             textTemplate: try stepReader.optionalNonEmptyString("text_template"),
                                             targetTextTemplate: try stepReader.optionalNonEmptyString("target_text_template"),
                                             expectation: decodeStepExpectation(fromToolInput: stepJSONValue, fieldName: "expect"),
                                             stepDescription: try stepReader.requiredString("description"))
        }
        return SubmittedRoutineDraft(routineName: try inputReader.requiredString("routine_name"),
                                     itemLabelTemplate: try inputReader.requiredString("item_label_template"), steps: draftSteps,
                                     completionEvidence: decodeStepExpectation(fromToolInput: .object(inputReader.inputObject),
                                                                               fieldName: "completion_evidence"))
    }

    /// Lengths and counts are capped rather than rejected: a question that is a little long is still worth showing,
    /// and bouncing it back would cost a model turn.
    private static func decodePlannerQuestion(inputReader: ToolInputReader) throws -> PlannerQuestion {
        guard let choiceJSONValues = inputReader.inputObject["choices"]?.arrayValue else {
            throw inputReader.typeError(fieldName: "choices", expectedDescription: "an array")
        }
        let rawChoices = try choiceJSONValues.map { choiceJSONValue -> PlannerQuestionChoice in
            guard let choiceObject = choiceJSONValue.objectValue else {
                throw inputReader.typeError(fieldName: "choices", expectedDescription: "an array of {label, detail} objects")
            }
            let choiceReader = ToolInputReader(toolName: .askUser, inputObject: choiceObject)
            return PlannerQuestionChoice(label: try choiceReader.requiredString("label"),
                                         detail: try choiceReader.optionalNonEmptyString("detail"))
        }
        let plannerQuestion = PlannerQuestion.sanitized(text: try inputReader.requiredString("question"), choices: rawChoices,
                                                        allowsFreeText: try inputReader.requiredBool("allow_free_text"))
        guard !plannerQuestion.text.isEmpty else {
            throw AgentToolInputError(messageForModel: "Invalid input for ask_user: `question` must not be empty.")
        }
        return plannerQuestion
    }

    private static func decodeSubmittedChecklistDraft(inputReader: ToolInputReader) throws -> SubmittedChecklistDraft {
        guard let itemJSONValues = inputReader.inputObject["items"]?.arrayValue else {
            throw inputReader.typeError(fieldName: "items", expectedDescription: "an array")
        }
        let submittedItems = try itemJSONValues.map { itemJSONValue -> SubmittedChecklistDraftItem in
            guard let itemObject = itemJSONValue.objectValue else { throw inputReader.typeError(fieldName: "items", expectedDescription: "an array of objects") }
            let itemReader = ToolInputReader(toolName: .submitPlan, inputObject: itemObject)
            guard let parameterJSONValues = itemObject["parameters"]?.arrayValue else {
                throw itemReader.typeError(fieldName: "parameters", expectedDescription: "an array")
            }
            let parameters = try parameterJSONValues.map { parameterJSONValue -> ChecklistItemParameter in
                guard let parameterName = parameterJSONValue["name"]?.stringValue,
                      let parameterValue = parameterJSONValue["value"]?.stringValue else {
                    throw itemReader.typeError(fieldName: "parameters", expectedDescription: "an array of {name, value} strings")
                }
                return ChecklistItemParameter(name: parameterName, value: parameterValue)
            }
            return SubmittedChecklistDraftItem(label: try itemReader.requiredString("label"),
                                               actionSummary: try itemReader.requiredString("action_summary"),
                                               parameters: parameters,
                                               isIrreversible: try itemReader.requiredBool("is_irreversible"))
        }
        // Over-long summaries and labels are shortened later (Checklist.fromPlannerSubmission, after the risk check
        // has read the full text); labels written as instructions go back to the planner.
        let labelViolations = submittedItems.enumerated().compactMap { itemOffset, submittedItem in
            ChecklistItemTextRules.labelViolation(submittedItem.label).map { (itemNumber: itemOffset + 1, violation: $0) }
        }
        if !labelViolations.isEmpty {
            throw AgentToolInputError(messageForModel: ChecklistItemTextRules.rejectionMessageForModel(labelViolations: labelViolations))
        }
        return SubmittedChecklistDraft(taskTitle: try inputReader.requiredString("task_title"),
                                       messageToUser: try inputReader.optionalNonEmptyString("message_to_user"),
                                       items: submittedItems)
    }

}

struct ToolInputReader {
    let toolName: AgentToolName
    let inputObject: [String: JSONValue]

    func typeError(fieldName: String, expectedDescription: String) -> AgentToolInputError {
        AgentToolInputError(messageForModel: "Invalid input for \(toolName.rawValue): `\(fieldName)` must be \(expectedDescription).")
    }

    func requiredString(_ fieldName: String) throws -> String {
        guard let stringValue = inputObject[fieldName]?.stringValue else { throw typeError(fieldName: fieldName, expectedDescription: "a string") }
        return stringValue
    }

    /// Empty strings count as null: models sometimes send "" where the schema allows null.
    func optionalNonEmptyString(_ fieldName: String) throws -> String? {
        switch inputObject[fieldName] {
        case nil, .null?: return nil
        case .string(let stringValue)?: return stringValue.isEmpty ? nil : stringValue
        default: throw typeError(fieldName: fieldName, expectedDescription: "a string or null")
        }
    }

    func requiredBool(_ fieldName: String) throws -> Bool {
        guard let boolValue = inputObject[fieldName]?.boolValue else { throw typeError(fieldName: fieldName, expectedDescription: "a boolean") }
        return boolValue
    }

    func requiredInteger(_ fieldName: String, clampedTo allowedRange: ClosedRange<Int>) throws -> Int {
        guard let numberValue = inputObject[fieldName]?.numberValue, numberValue.isFinite,
              abs(numberValue) < 1_000_000_000 else {
            throw typeError(fieldName: fieldName, expectedDescription: "an integer")
        }
        return min(max(Int(numberValue.rounded()), allowedRange.lowerBound), allowedRange.upperBound)
    }

    func requiredEnum<EnumType: RawRepresentable>(_ fieldName: String) throws -> EnumType where EnumType.RawValue == String {
        guard let rawValue = inputObject[fieldName]?.stringValue, let enumValue = EnumType(rawValue: rawValue) else {
            throw typeError(fieldName: fieldName, expectedDescription: "one of the values listed in the schema")
        }
        return enumValue
    }

    func requiredEnumArray<EnumType: RawRepresentable>(_ fieldName: String) throws -> [EnumType] where EnumType.RawValue == String {
        guard let arrayValue = inputObject[fieldName]?.arrayValue else { throw typeError(fieldName: fieldName, expectedDescription: "an array") }
        return try arrayValue.map { elementValue in
            guard let rawValue = elementValue.stringValue, let enumValue = EnumType(rawValue: rawValue) else {
                throw typeError(fieldName: fieldName, expectedDescription: "an array of values listed in the schema")
            }
            return enumValue
        }
    }
}
