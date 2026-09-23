import Foundation
import CoreGraphics

private func decode(toolName: String, inputJSONText: String) throws -> Result<AgentToolCall, AgentToolInputError> {
    AgentToolCallDecoder.decodeToolCall(ClaudeToolUseBlock(toolUseIdentifier: "toolu_test", toolName: toolName,
                                                          input: try JSONValue(parsingJSONText: inputJSONText)))
}

private func decodeSuccessfully(toolName: String, inputJSONText: String) throws -> AgentToolCall {
    switch try decode(toolName: toolName, inputJSONText: inputJSONText) {
    case .success(let toolCall): return toolCall
    case .failure(let inputError): throw CoreTestFailure(description: "\(toolName) failed to decode: \(inputError.messageForModel)")
    }
}

private func decodeFailureMessage(toolName: String, inputJSONText: String) throws -> String {
    switch try decode(toolName: toolName, inputJSONText: inputJSONText) {
    case .success(let toolCall): throw CoreTestFailure(description: "\(toolName) unexpectedly decoded to \(toolCall)")
    case .failure(let inputError): return inputError.messageForModel
    }
}

/// Strict tool use requires every object schema to forbid extra properties and to list all properties as required.
private func validateStrictObjectSchemas(_ schema: JSONValue, path: String) throws {
    guard let schemaObject = schema.objectValue else { return }
    if schemaObject["type"]?.stringValue == "object" {
        try expectEqual(schemaObject["additionalProperties"], .bool(false), "\(path) additionalProperties")
        let propertyNames = Set(schemaObject["properties"]?.objectValue?.keys.map { $0 } ?? [])
        let requiredNames = Set((schemaObject["required"]?.arrayValue ?? []).compactMap(\.stringValue))
        try expectEqual(requiredNames, propertyNames, "\(path) required must list every property")
    }
    for (childKey, childSchema) in schemaObject {
        if let childArray = childSchema.arrayValue {
            for (childOffset, arrayElement) in childArray.enumerated() {
                try validateStrictObjectSchemas(arrayElement, path: "\(path).\(childKey)[\(childOffset)]")
            }
        } else {
            try validateStrictObjectSchemas(childSchema, path: "\(path).\(childKey)")
        }
    }
}

let agentToolCallDecoderTestSuite = CoreTestSuite(name: "AgentToolCallDecoder", testCases: [
    CoreTestCase(name: "catalog tool lists have the specified names and order") {
        try expectEqual(AgentToolCatalog.plannerTools.map(\.name),
                        ["read_ui", "screenshot", "ask_user", "submit_plan", "list_folder", "read_file_metadata", "list_shortcuts",
                         "submit_file_operations_plan", "submit_script_plan", "submit_shortcut_plan"])
        try expectEqual(AgentToolCatalog.executorTools.map(\.name),
                        ["read_ui", "screenshot", "click", "type_text", "press_key", "scroll", "click_point", "upload_files", "wait_for",
                         "finish_item"])
        try expectEqual(AgentToolCatalog.routineCompilerTools.map(\.name), ["submit_routine"])
        let allCatalogNames = Set((AgentToolCatalog.plannerTools + AgentToolCatalog.executorTools
                                   + AgentToolCatalog.routineCompilerTools).map(\.name))
        try expectEqual(allCatalogNames, Set(AgentToolName.allCases.map(\.rawValue)))
    },
    CoreTestCase(name: "every tool schema is strict-valid (object root, no extra properties, all properties required); only direct-route tools are sent non-strict") {
        let nonStrictToolNames = Set(AgentToolCatalog.directRoutePlannerTools.map(\.name))
        for toolDefinition in AgentToolCatalog.plannerTools + AgentToolCatalog.executorTools + AgentToolCatalog.routineCompilerTools {
            try expectEqual(toolDefinition.isStrict, !nonStrictToolNames.contains(toolDefinition.name), toolDefinition.name)
            try expectTrue(!toolDefinition.description.isEmpty, "\(toolDefinition.name) needs a description")
            try expectEqual(toolDefinition.inputSchema["type"], .string("object"), toolDefinition.name)
            try validateStrictObjectSchemas(toolDefinition.inputSchema, path: toolDefinition.name)
        }
    },
    CoreTestCase(name: "shared tools are identical between planner and executor lists (stable cache prefix)") {
        try expectEqual(AgentToolCatalog.plannerTools[0], AgentToolCatalog.executorTools[0])
        try expectEqual(AgentToolCatalog.plannerTools[1], AgentToolCatalog.executorTools[1])
    },
    CoreTestCase(name: "ask_user decodes a question with its choices and free-text flag") {
        let askUserInput = #"{"question":"Which folder?","choices":[{"label":"Desktop","detail":null},{"label":"Downloads","detail":"12 files"}],"allow_free_text":false}"#
        try expectEqual(try decodeSuccessfully(toolName: "ask_user", inputJSONText: askUserInput), .askUser(PlannerQuestion(
            text: "Which folder?",
            choices: [PlannerQuestionChoice(label: "Desktop", detail: nil), PlannerQuestionChoice(label: "Downloads", detail: "12 files")],
            allowsFreeText: false)))
    },
    CoreTestCase(name: "ask_user caps choices and lengths, strips markdown, and allows free text when no choice is left") {
        let longLabel = String(repeating: "a", count: 40)
        let longDetail = String(repeating: "b", count: 90)
        let askUserInput = #"{"question":"**Which** folder?","choices":[{"label":"\#(longLabel)","detail":"\#(longDetail)"},{"label":"`Two`","detail":""},{"label":"two","detail":null},{"label":"Three","detail":null},{"label":"Four","detail":null},{"label":"Five","detail":null}],"allow_free_text":false}"#
        guard case .askUser(let plannerQuestion) = try decodeSuccessfully(toolName: "ask_user", inputJSONText: askUserInput) else {
            throw CoreTestFailure(description: "expected ask_user")
        }
        try expectEqual(plannerQuestion.text, "Which folder?")
        try expectEqual(plannerQuestion.choices.map(\.label), [String(repeating: "a", count: 31) + "…", "Two", "Three", "Four"])
        try expectEqual(plannerQuestion.choices[0].detail?.count, PlannerQuestionChoice.maximumDetailLength)
        try expectEqual(plannerQuestion.choices[1].detail, nil)
        try expectEqual(plannerQuestion.allowsFreeText, false)

        let noChoicesInput = #"{"question":"Which folder?","choices":[{"label":"  ","detail":null}],"allow_free_text":false}"#
        guard case .askUser(let openQuestion) = try decodeSuccessfully(toolName: "ask_user", inputJSONText: noChoicesInput) else {
            throw CoreTestFailure(description: "expected ask_user")
        }
        try expectEqual(openQuestion.choices, [])
        try expectEqual(openQuestion.allowsFreeText, true)
        try expectEqual(openQuestion.acceptsReply, true)
    },
    CoreTestCase(name: "ask_user rejects an empty question and malformed choices") {
        try expectTrue(try decodeFailureMessage(toolName: "ask_user",
            inputJSONText: #"{"question":" ** ","choices":[],"allow_free_text":true}"#).contains("question"))
        try expectTrue(try decodeFailureMessage(toolName: "ask_user",
            inputJSONText: #"{"question":"Which?","choices":["Desktop"],"allow_free_text":true}"#).contains("choices"))
    },
    CoreTestCase(name: "read_ui decodes scope and treats empty strings as null") {
        try expectEqual(try decodeSuccessfully(toolName: "read_ui", inputJSONText: #"{"scope":"menu_bar","application_name":"","query":"Rename"}"#),
                        .readUserInterface(ReadUserInterfaceRequest(scope: .menuBar, applicationName: nil, query: "Rename")))
        try expectEqual(try decodeSuccessfully(toolName: "read_ui", inputJSONText: #"{"scope":"all_windows","application_name":"Mail","query":null}"#),
                        .readUserInterface(ReadUserInterfaceRequest(scope: .allWindows, applicationName: "Mail", query: nil)))
    },
    CoreTestCase(name: "click, type_text, press_key decode into actions") {
        try expectEqual(try decodeSuccessfully(toolName: "click", inputJSONText: #"{"element_id":"e12","click_type":"double"}"#),
                        .action(.clickElement(elementIdentifier: "e12", clickType: .double)))
        try expectEqual(try decodeSuccessfully(toolName: "type_text",
                                               inputJSONText: #"{"element_id":"","text":"shot-01","replace_existing_text":true,"press_return_after":false}"#),
                        .action(.typeText(elementIdentifier: nil, text: "shot-01", replaceExistingText: true, pressReturnAfter: false)))
        try expectEqual(try decodeSuccessfully(toolName: "press_key", inputJSONText: #"{"key":" Return ","modifiers":["command","shift"]}"#),
                        .action(.pressKey(keyName: "return", modifiers: [.command, .shift])))
    },
    CoreTestCase(name: "numeric ranges are clamped: scroll pages 1-10, wait_for 1-15 s") {
        try expectEqual(try decodeSuccessfully(toolName: "scroll", inputJSONText: #"{"element_id":null,"direction":"down","pages":50}"#),
                        .action(.scroll(elementIdentifier: nil, direction: .down, pages: 10)))
        try expectEqual(try decodeSuccessfully(toolName: "scroll", inputJSONText: #"{"element_id":"e3","direction":"up","pages":0}"#),
                        .action(.scroll(elementIdentifier: "e3", direction: .up, pages: 1)))
        try expectEqual(try decodeSuccessfully(toolName: "wait_for", inputJSONText: #"{"text":"Saved","timeout_seconds":100}"#),
                        .waitFor(text: "Saved", timeoutSeconds: 15))
        try expectEqual(try decodeSuccessfully(toolName: "wait_for", inputJSONText: #"{"text":"Saved","timeout_seconds":-4}"#),
                        .waitFor(text: "Saved", timeoutSeconds: 1))
    },
    CoreTestCase(name: "click_point, screenshot and finish_item decode") {
        try expectEqual(try decodeSuccessfully(toolName: "click_point", inputJSONText: #"{"x":640,"y":360,"click_type":"right"}"#),
                        .action(.clickScreenshotPoint(screenshotPixelPoint: CGPoint(x: 640, y: 360), clickType: .right)))
        try expectEqual(try decodeSuccessfully(toolName: "screenshot", inputJSONText: "{}"), .screenshot)
        try expectEqual(try decodeSuccessfully(toolName: "finish_item", inputJSONText: #"{"outcome":"needs_user","summary":"Login required."}"#),
                        .finishItem(outcome: .needsUser, summary: "Login required."))
    },
    CoreTestCase(name: "submit_plan decodes items, parameters and a null message") {
        let submitPlanInput = #"{"task_title":"Rename shots","message_to_user":null,"items":[{"label":"Rename A","action_summary":"Rename row A.","parameters":[{"name":"newName","value":"shot-01"}],"is_irreversible":false},{"label":"Send B","action_summary":"Send it.","parameters":[],"is_irreversible":true}]}"#
        try expectEqual(try decodeSuccessfully(toolName: "submit_plan", inputJSONText: submitPlanInput), .submitPlan(SubmittedChecklistDraft(
            taskTitle: "Rename shots", messageToUser: nil, items: [
                SubmittedChecklistDraftItem(label: "Rename A", actionSummary: "Rename row A.",
                                            parameters: [ChecklistItemParameter(name: "newName", value: "shot-01")], isIrreversible: false),
                SubmittedChecklistDraftItem(label: "Send B", actionSummary: "Send it.", parameters: [], isIrreversible: true),
            ])))
    },
    CoreTestCase(name: "invalid inputs produce messages for the model instead of crashing") {
        try expectEqual(try decodeFailureMessage(toolName: "drag", inputJSONText: "{}"), #"Unknown tool "drag"."#)
        try expectTrue(try decodeFailureMessage(toolName: "click", inputJSONText: #"{"element_id":"e1","click_type":"triple"}"#).contains("click_type"))
        try expectTrue(try decodeFailureMessage(toolName: "click", inputJSONText: #"{"element_id":"","click_type":"single"}"#).contains("element_id"))
        try expectTrue(try decodeFailureMessage(toolName: "type_text", inputJSONText: #"{"element_id":null,"text":"x"}"#).contains("replace_existing_text"))
        try expectTrue(try decodeFailureMessage(toolName: "press_key", inputJSONText: #"{"key":"a","modifiers":["hyper"]}"#).contains("modifiers"))
        try expectTrue(try decodeFailureMessage(toolName: "scroll", inputJSONText: #"{"element_id":null,"direction":"down","pages":"two"}"#).contains("pages"))
        try expectTrue(try decodeFailureMessage(toolName: "submit_plan", inputJSONText: #"{"task_title":"t","message_to_user":null,"items":[{"label":"x"}]}"#).contains("parameters"))
    },
    CoreTestCase(name: "golden: expect is required on the five action tools, evidence on finish_item") {
        let requiredFieldsByToolName = Dictionary(uniqueKeysWithValues: AgentToolCatalog.executorTools.map { toolDefinition in
            (toolDefinition.name, Set((toolDefinition.inputSchema["required"]?.arrayValue ?? []).compactMap(\.stringValue)))
        })
        for actionToolName in ["click", "type_text", "press_key", "scroll", "click_point"] {
            try expectTrue(requiredFieldsByToolName[actionToolName]?.contains("expect") == true, actionToolName)
        }
        try expectTrue(requiredFieldsByToolName["finish_item"]?.contains("evidence") == true)
        try expectTrue(requiredFieldsByToolName["read_ui"]?.contains("expect") == false)
    },
    CoreTestCase(name: "action tools still decode with expect present") {
        try expectEqual(try decodeSuccessfully(toolName: "click", inputJSONText: #"{"element_id":"e2","click_type":"single","expect":{"kind":"text_appears","text":"Saved"}}"#),
                        .action(.clickElement(elementIdentifier: "e2", clickType: .single)))
        try expectEqual(try decodeSuccessfully(toolName: "finish_item", inputJSONText: #"{"outcome":"completed","summary":"Done.","evidence":{"kind":"none","text":""}}"#),
                        .finishItem(outcome: .completed, summary: "Done."))
    },
    CoreTestCase(name: "decodeStepExpectation: null, object, bad kind, empty text, none") {
        func expectation(_ inputJSONText: String, fieldName: String = "expect") throws -> StepExpectation? {
            AgentToolCallDecoder.decodeStepExpectation(fromToolInput: try JSONValue(parsingJSONText: inputJSONText), fieldName: fieldName)
        }
        try expectEqual(try expectation(#"{"expect":null}"#), nil)
        try expectEqual(try expectation(#"{}"#), nil)
        try expectEqual(try expectation(#"{"expect":{"kind":"field_value_equals","text":"shot-01"}}"#),
                        StepExpectation(kind: .fieldValueEquals, text: "shot-01"))
        try expectEqual(try expectation(#"{"expect":{"kind":"looks_done","text":"x"}}"#), nil)
        try expectEqual(try expectation(#"{"expect":{"kind":"text_appears","text":"  "}}"#), nil)
        try expectEqual(try expectation(#"{"expect":"text_appears"}"#), nil)
        try expectEqual(try expectation(#"{"evidence":{"kind":"none","text":"x"}}"#, fieldName: "evidence"), nil)
        try expectEqual(try expectation(#"{"evidence":{"kind":"document_contains","text":"beach"}}"#, fieldName: "evidence"),
                        StepExpectation(kind: .documentContains, text: "beach"))
    },
    CoreTestCase(name: "submit_routine decodes a draft and is refused by decodeToolCall") {
        let draftInput = #"{"routine_name":"Rename","item_label_template":"Rename {{old_name}}","steps":[{"event_index":0,"text_template":null,"target_text_template":"{{old_name}}","expect":null,"description":"Click the file"},{"event_index":1,"text_template":"{{new_name}}","target_text_template":null,"expect":{"kind":"text_appears","text":"{{new_name}}"},"description":"Type"}],"completion_evidence":{"kind":"text_appears","text":"{{new_name}}"}}"#
        let toolUse = ClaudeToolUseBlock(toolUseIdentifier: "toolu_r", toolName: "submit_routine", input: try JSONValue(parsingJSONText: draftInput))
        guard case .success(let draft) = AgentToolCallDecoder.decodeSubmittedRoutineDraft(toolUse) else {
            throw CoreTestFailure(description: "submit_routine draft failed to decode")
        }
        try expectEqual(draft, SubmittedRoutineDraft(routineName: "Rename", itemLabelTemplate: "Rename {{old_name}}", steps: [
            SubmittedRoutineDraftStep(eventIndex: 0, textTemplate: nil, targetTextTemplate: "{{old_name}}", expectation: nil, stepDescription: "Click the file"),
            SubmittedRoutineDraftStep(eventIndex: 1, textTemplate: "{{new_name}}", targetTextTemplate: nil,
                                      expectation: StepExpectation(kind: .textAppears, text: "{{new_name}}"), stepDescription: "Type"),
        ], completionEvidence: StepExpectation(kind: .textAppears, text: "{{new_name}}")))
        try expectEqual(try decodeFailureMessage(toolName: "submit_routine", inputJSONText: draftInput),
                        "submit_routine is only available when compiling a routine.")
        let malformedToolUse = ClaudeToolUseBlock(toolUseIdentifier: "toolu_m", toolName: "submit_routine",
                                                  input: try JSONValue(parsingJSONText: #"{"routine_name":"R","item_label_template":"L","steps":[{"event_index":"zero"}],"completion_evidence":null}"#))
        guard case .failure(let inputError) = AgentToolCallDecoder.decodeSubmittedRoutineDraft(malformedToolUse) else {
            throw CoreTestFailure(description: "malformed draft should fail")
        }
        try expectTrue(inputError.messageForModel.contains("event_index"))
    },
    CoreTestCase(name: "upload_files decodes 1-20 non-empty paths with an element and rejects the rest") {
        try expectEqual(try decodeSuccessfully(toolName: "upload_files",
                                               inputJSONText: #"{"element_id":"e5","file_paths":["/Users/me/a.pdf","~/b.png"],"expect":null}"#),
                        .action(.uploadFiles(elementIdentifier: "e5", filePaths: ["/Users/me/a.pdf", "~/b.png"])))
        let twentyOnePaths = (1...21).map { "\"/Users/me/f\($0).pdf\"" }.joined(separator: ",")
        let failureInputs = [
            #"{"element_id":"e5","file_paths":[\#(twentyOnePaths)],"expect":null}"#,
            #"{"element_id":"e5","file_paths":[],"expect":null}"#,
            #"{"element_id":"e5","file_paths":["/Users/me/a.pdf","  "],"expect":null}"#,
            #"{"element_id":"e5","file_paths":["/Users/me/a.pdf",7],"expect":null}"#,
        ]
        for failureInput in failureInputs {
            try expectEqual(try decodeFailureMessage(toolName: "upload_files", inputJSONText: failureInput),
                            "Invalid input for upload_files: `file_paths` must list 1-20 absolute paths.", failureInput)
        }
        try expectEqual(try decodeFailureMessage(toolName: "upload_files", inputJSONText: #"{"element_id":null,"file_paths":["/a.pdf"],"expect":null}"#),
                        "Invalid input for upload_files: `element_id` must be an id like e42.")
    },
])
