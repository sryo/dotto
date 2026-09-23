import Foundation

private func decodeDirectRouteTool(_ toolName: String, _ inputJSONText: String) throws -> Result<AgentToolCall, AgentToolInputError> {
    AgentToolCallDecoder.decodeToolCall(ClaudeToolUseBlock(toolUseIdentifier: "toolu_direct", toolName: toolName,
                                                          input: try JSONValue(parsingJSONText: inputJSONText)))
}

private func decodedDirectRouteTool(_ toolName: String, _ inputJSONText: String) throws -> AgentToolCall {
    switch try decodeDirectRouteTool(toolName, inputJSONText) {
    case .success(let toolCall): return toolCall
    case .failure(let inputError): throw CoreTestFailure(description: "\(toolName) failed to decode: \(inputError.messageForModel)")
    }
}

private func directRouteDecodeFailure(_ toolName: String, _ inputJSONText: String) throws -> String {
    switch try decodeDirectRouteTool(toolName, inputJSONText) {
    case .success(let toolCall): throw CoreTestFailure(description: "\(toolName) unexpectedly decoded to \(toolCall)")
    case .failure(let inputError): return inputError.messageForModel
    }
}

private func fileOperationsInput(operationsJSON: String, rulesJSON: String = "[]", continues: Bool = false,
                                 groupsJSON: String = #"[{"group_id":"g1","title":"Move screenshots"}]"#) -> String {
    #"{"task_title":" Sort screenshots ","message_to_user":null,"groups":\#(groupsJSON),"operations":\#(operationsJSON),"date_folder_rules":\#(rulesJSON),"continues_in_next_call":\#(continues)}"#
}

private func operationJSON(op: String, from: String?, to: String?, tags: String = "null", group: String = "g1",
                           reason: String = "taken 2026-09-03") -> String {
    let fromJSON = from.map { "\"\($0)\"" } ?? "null"
    let toJSON = to.map { "\"\($0)\"" } ?? "null"
    return #"{"op":"\#(op)","from":\#(fromJSON),"to":\#(toJSON),"tags":\#(tags),"reason":"\#(reason)","group_id":"\#(group)"}"#
}

let agentToolCallDecoderDirectRouteTestSuite = CoreTestSuite(name: "AgentToolCallDecoder direct routes", testCases: [
    CoreTestCase(name: "list_folder decodes with depth clamped to 1...2") {
        try expectEqual(try decodedDirectRouteTool("list_folder", #"{"path":" /Users/me/Shots ","depth":7,"include_hidden":false}"#),
                        .readDirectRouteData(.listFolder(path: "/Users/me/Shots", depth: 2, includesHiddenItems: false)))
        try expectEqual(try decodedDirectRouteTool("list_folder", #"{"path":"/a","depth":0,"include_hidden":true}"#),
                        .readDirectRouteData(.listFolder(path: "/a", depth: 1, includesHiddenItems: true)))
    },
    CoreTestCase(name: "read_file_metadata needs 1-200 paths") {
        try expectEqual(try decodedDirectRouteTool("read_file_metadata", #"{"paths":["/a/b.png"," /a/c.png"]}"#),
                        .readDirectRouteData(.readFileMetadata(paths: ["/a/b.png", "/a/c.png"])))
        _ = try directRouteDecodeFailure("read_file_metadata", #"{"paths":[]}"#)
        let tooManyPaths = (0...200).map { "\"/a/\($0).png\"" }.joined(separator: ",")
        try expectTrue(try directRouteDecodeFailure("read_file_metadata", #"{"paths":[\#(tooManyPaths)]}"#).contains("1-200"))
    },
    CoreTestCase(name: "read_file_metadata takes a folder instead of paths, never both") {
        try expectEqual(try decodedDirectRouteTool("read_file_metadata", #"{"folder":" /Users/me/Trip ","paths":null}"#),
                        .readDirectRouteData(.readFolderMetadata(folderPath: "/Users/me/Trip")))
        try expectEqual(try decodedDirectRouteTool("read_file_metadata", #"{"folder":"/Users/me/Trip","paths":[]}"#),
                        .readDirectRouteData(.readFolderMetadata(folderPath: "/Users/me/Trip")))
        try expectEqual(try decodedDirectRouteTool("read_file_metadata", #"{"folder":null,"paths":["/a/b.png"]}"#),
                        .readDirectRouteData(.readFileMetadata(paths: ["/a/b.png"])))
        try expectTrue(try directRouteDecodeFailure("read_file_metadata", #"{"folder":"/a","paths":["/a/b.png"]}"#).contains("either `folder`"))
        try expectTrue(try directRouteDecodeFailure("read_file_metadata", #"{"folder":null,"paths":null}"#).contains("either `folder`"))
        _ = try directRouteDecodeFailure("read_file_metadata", #"{"folder":null,"paths":"/a/b.png"}"#)
    },
    CoreTestCase(name: "list_shortcuts takes an optional query") {
        try expectEqual(try decodedDirectRouteTool("list_shortcuts", #"{"query":null}"#), .readDirectRouteData(.listShortcuts(query: nil)))
        try expectEqual(try decodedDirectRouteTool("list_shortcuts", #"{"query":" resize "}"#), .readDirectRouteData(.listShortcuts(query: "resize")))
    },
    CoreTestCase(name: "submit_file_operations_plan decodes operations and rules, trimming and truncating") {
        let longReason = String(repeating: "r", count: 200)
        let longTitle = String(repeating: "T", count: 90)
        let inputJSON = fileOperationsInput(
            operationsJSON: "[" + operationJSON(op: "create_folder", from: nil, to: "/a/2026-09") + ","
                + operationJSON(op: "move", from: "/a/x.png", to: "/a/2026-09/x.png", reason: longReason) + ","
                + operationJSON(op: "set_tags", from: "/a/y.png", to: "/ignored", tags: #"["Red"," Work "]"#) + "]",
            rulesJSON: #"[{"source_folder":"/a","destination_parent_folder":"/a","name_contains":null,"extensions":[".PNG","jpg"],"type_identifiers":[],"date_source":"capture_date_or_created","folder_name_format":"yyyy-MM MMMM","group_id":"g1"}]"#,
            groupsJSON: #"[{"group_id":"g1","title":"\#(longTitle)"}]"#)
        guard case .submitDirectRoutePlan(.fileOperations(let draft)) = try decodedDirectRouteTool("submit_file_operations_plan", inputJSON) else {
            throw CoreTestFailure(description: "expected a file operations draft")
        }
        try expectEqual(draft.taskTitle, "Sort screenshots")
        try expectEqual(draft.groups[0].title.count, 60)
        try expectEqual(draft.operations.map(\.kind), [.createFolder, .move, .setTags])
        try expectEqual(draft.operations[1].reason.count, 120)
        try expectEqual(draft.operations[2].toPath, nil, "set_tags never carries a destination")
        try expectEqual(draft.operations[2].tags, ["Red", "Work"])
        try expectEqual(draft.dateFolderRules[0].lowercasedExtensions, ["png", "jpg"])
        try expectEqual(draft.dateFolderRules[0].dateSource, .captureDateOrCreated)
        try expectEqual(draft.continuesInNextCall, false)
    },
    CoreTestCase(name: "rename_rules decode with their filters, order and template; absent means none") {
        let renameRulesJSON = #"[{"source_folder":" /a ","name_contains":null,"extensions":[".JPG"],"type_identifiers":["public.image"],"order_by":"capture_date_or_created","descending":false,"date_source":null,"name_template":" photo-{n:3} ","group_id":"g1"}]"#
        let inputJSON = #"{"task_title":"Rename","message_to_user":null,"groups":[{"group_id":"g1","title":"Rename 150 photos"}],"operations":[],"date_folder_rules":[],"rename_rules":\#(renameRulesJSON),"continues_in_next_call":false}"#
        guard case .submitDirectRoutePlan(.fileOperations(let draft)) = try decodedDirectRouteTool("submit_file_operations_plan", inputJSON) else {
            throw CoreTestFailure(description: "expected a file operations draft")
        }
        try expectEqual(draft.renameRules, [SubmittedRenameRule(
            sourceFolderPath: "/a", nameContains: nil, lowercasedExtensions: ["jpg"], typeIdentifiers: ["public.image"],
            order: .captureDateOrCreated, isDescending: false, dateSource: nil, nameTemplate: "photo-{n:3}", groupIdentifier: "g1")])
        guard case .submitDirectRoutePlan(.fileOperations(let draftWithoutRenameRules)) = try decodedDirectRouteTool(
            "submit_file_operations_plan", fileOperationsInput(operationsJSON: "[]")) else {
            throw CoreTestFailure(description: "expected a file operations draft")
        }
        try expectEqual(draftWithoutRenameRules.renameRules, [])
    },
    CoreTestCase(name: "a rename rule with an unknown order, a bad date source or an undeclared group is refused") {
        func renameRuleInput(orderBy: String = "name", dateSource: String = "null", group: String = "g1") -> String {
            let ruleJSON = #"{"source_folder":"/a","name_contains":null,"extensions":[],"type_identifiers":[],"order_by":"\#(orderBy)","descending":true,"date_source":\#(dateSource),"name_template":"{n}","group_id":"\#(group)"}"#
            return #"{"task_title":"Rename","message_to_user":null,"groups":[{"group_id":"g1","title":"Rename"}],"operations":[],"date_folder_rules":[],"rename_rules":[\#(ruleJSON)],"continues_in_next_call":false}"#
        }
        try expectTrue(try directRouteDecodeFailure("submit_file_operations_plan", renameRuleInput(orderBy: "size")).contains("order_by"))
        try expectTrue(try directRouteDecodeFailure("submit_file_operations_plan", renameRuleInput(dateSource: "\"taken\"")).contains("date_source"))
        try expectTrue(try directRouteDecodeFailure("submit_file_operations_plan", renameRuleInput(group: "nope")).contains("\"nope\""))
        guard case .submitDirectRoutePlan(.fileOperations(let draft)) = try decodedDirectRouteTool(
            "submit_file_operations_plan", renameRuleInput(dateSource: "\"modified\"")) else {
            throw CoreTestFailure(description: "expected a file operations draft")
        }
        try expectEqual(draft.renameRules.first?.dateSource, .modified)
        try expectEqual(draft.renameRules.first?.isDescending, true)
    },
    CoreTestCase(name: "each operation kind needs its own fields") {
        let shapeCases: [(String, String?, String?, String, String)] = [
            ("create_folder", "/a/x", "/a/y", "null", "create_folder needs `to` and a null `from`"),
            ("create_folder", nil, nil, "null", "create_folder needs `to` and a null `from`"),
            ("move", "/a/x", nil, "null", "move needs both `from` and `to`"),
            ("rename", nil, "/a/y", "null", "rename needs both `from` and `to`"),
            ("copy", "/a/x", nil, "null", "copy needs both `from` and `to`"),
            ("set_tags", "/a/x", nil, "null", "set_tags needs `from` and `tags`"),
            ("move_to_trash", nil, nil, "null", "move_to_trash needs `from`"),
        ]
        for (operationKind, fromPath, toPath, tagsJSON, expectedMessage) in shapeCases {
            let failureMessage = try directRouteDecodeFailure("submit_file_operations_plan", fileOperationsInput(
                operationsJSON: "[" + operationJSON(op: operationKind, from: fromPath, to: toPath, tags: tagsJSON) + "]"))
            try expectTrue(failureMessage.contains(expectedMessage), failureMessage)
        }
    },
    CoreTestCase(name: "an undeclared group_id is refused, naming the id") {
        let failureMessage = try directRouteDecodeFailure("submit_file_operations_plan", fileOperationsInput(
            operationsJSON: "[" + operationJSON(op: "move", from: "/a/x", to: "/a/y", group: "nope") + "]"))
        try expectTrue(failureMessage.contains("\"nope\""), failureMessage)
    },
    CoreTestCase(name: "more than 150 operations in one call asks for continues_in_next_call") {
        let operations = (0...150).map { operationJSON(op: "move", from: "/a/\($0)", to: "/a/b/\($0)") }.joined(separator: ",")
        let failureMessage = try directRouteDecodeFailure("submit_file_operations_plan", fileOperationsInput(operationsJSON: "[\(operations)]"))
        try expectEqual(failureMessage, "Send at most 150 operations per call; set continues_in_next_call.")
    },
    CoreTestCase(name: "submit_script_plan clamps the timeout, caps effects and refuses an oversized source") {
        let effects = (1...14).map { "\"effect \($0)\"" }.joined(separator: ",")
        let inputJSON = #"{"task_title":"Make mailboxes","target_bundle_id":"com.apple.mail","language":"applescript","source":"tell application \"Mail\" to return \"ok\"","summary":"Creates mailboxes.","expected_effects":[\#(effects)],"modifies_data":true,"timeout_seconds":900}"#
        guard case .submitDirectRoutePlan(.script(let draft)) = try decodedDirectRouteTool("submit_script_plan", inputJSON) else {
            throw CoreTestFailure(description: "expected a script draft")
        }
        try expectEqual(draft.timeoutSeconds, 300)
        try expectEqual(draft.expectedEffects.count, 10)
        try expectEqual(draft.language, .appleScript)
        let oversizedSource = String(repeating: "x", count: ScriptPlan.maximumSourceLength + 1)
        let oversizedInput = #"{"task_title":"t","target_bundle_id":"com.apple.mail","language":"jxa","source":"\#(oversizedSource)","summary":"s","expected_effects":[],"modifies_data":false,"timeout_seconds":1}"#
        try expectTrue(try directRouteDecodeFailure("submit_script_plan", oversizedInput).contains("longer than 20000"))
    },
    CoreTestCase(name: "submit_shortcut_plan checks its input kind against the input fields") {
        let textInput = #"{"task_title":"t","shortcut_name":"Resize for web","input_kind":"text","input_text":"hello","input_file_paths":[],"summary":"s","timeout_seconds":2}"#
        try expectEqual(try decodedDirectRouteTool("submit_shortcut_plan", textInput), .submitDirectRoutePlan(.shortcut(SubmittedShortcutPlanDraft(
            taskTitle: "t", shortcutName: "Resize for web", input: .text("hello"), summary: "s", timeoutSeconds: 5))))
        let emptyText = #"{"task_title":"t","shortcut_name":"S","input_kind":"text","input_text":null,"input_file_paths":[],"summary":"s","timeout_seconds":30}"#
        try expectTrue(try directRouteDecodeFailure("submit_shortcut_plan", emptyText).contains("input_text"))
        let noFiles = #"{"task_title":"t","shortcut_name":"S","input_kind":"files","input_text":null,"input_file_paths":[],"summary":"s","timeout_seconds":30}"#
        try expectTrue(try directRouteDecodeFailure("submit_shortcut_plan", noFiles).contains("1-20"))
        let filesInput = #"{"task_title":"t","shortcut_name":"S","input_kind":"files","input_text":null,"input_file_paths":["/a/x.png"],"summary":"s","timeout_seconds":30}"#
        guard case .submitDirectRoutePlan(.shortcut(let filesDraft)) = try decodedDirectRouteTool("submit_shortcut_plan", filesInput) else {
            throw CoreTestFailure(description: "expected a shortcut draft")
        }
        try expectEqual(filesDraft.input, .files(["/a/x.png"]))
    },
])
