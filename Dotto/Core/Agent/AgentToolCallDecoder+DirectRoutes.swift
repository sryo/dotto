import Foundation

/// Decode rules for the direct-route tools. Every limit a tool description states is enforced here (or by the
/// planner), never trusted from the model. Long display text is truncated rather than rejected, since bouncing it
/// back would cost a model turn; shape errors are rejected with a message that says what to fix.
extension AgentToolCallDecoder {
    static let maximumFolderListingDepth = 2
    static let maximumMetadataPathsPerCall = 200
    static let maximumOperationsPerSubmitCall = 150
    static let maximumFileOperationGroups = 20
    static let maximumGroupTitleLength = 60
    static let maximumOperationReasonLength = 120
    static let maximumScriptSummaryLength = 140
    static let maximumExpectedEffectCount = 10
    static let maximumExpectedEffectLength = 120
    static let allowedScriptTimeoutSeconds = 5...300
    static let maximumShortcutInputFileCount = 20
    static let maximumTagsPerOperation = 20

    static func decodeDirectRouteToolCall(toolName: AgentToolName, inputReader: ToolInputReader) throws -> AgentToolCall {
        switch toolName {
        case .listFolder:
            return .readDirectRouteData(.listFolder(
                path: try requiredTrimmedNonEmptyString("path", inputReader: inputReader),
                depth: try inputReader.requiredInteger("depth", clampedTo: 1...maximumFolderListingDepth),
                includesHiddenItems: try inputReader.requiredBool("include_hidden")))
        case .readFileMetadata:
            return .readDirectRouteData(try decodeFileMetadataReadRequest(inputReader: inputReader))
        case .listShortcuts:
            let query = try inputReader.optionalNonEmptyString("query")?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .readDirectRouteData(.listShortcuts(query: query?.isEmpty == true ? nil : query))
        case .submitFileOperationsPlan:
            return .submitDirectRoutePlan(.fileOperations(try decodeSubmittedFileOperationsDraft(inputReader: inputReader)))
        case .submitScriptPlan:
            return .submitDirectRoutePlan(.script(try decodeSubmittedScriptPlanDraft(inputReader: inputReader)))
        case .submitShortcutPlan:
            return .submitDirectRoutePlan(.shortcut(try decodeSubmittedShortcutPlanDraft(inputReader: inputReader)))
        default:
            throw AgentToolInputError(messageForModel: "\(toolName.rawValue) isn't a direct-route tool.")
        }
    }

    // MARK: - Reads

    /// Exactly one of `paths` and `folder`. The schema lists both as required and nullable, but tools are sent
    /// non-strict, so an absent field counts as null and an empty `paths` as not given.
    private static func decodeFileMetadataReadRequest(inputReader: ToolInputReader) throws -> DirectRouteReadRequest {
        let eitherFormMessage = "Invalid input for read_file_metadata: give either `folder` (one absolute folder path) or `paths` (1-\(maximumMetadataPathsPerCall) absolute paths), and null for the other."
        let folderPath = try optionalTrimmedNonEmptyString("folder", inputReader: inputReader)
        var paths: [String] = []
        switch inputReader.inputObject["paths"] {
        case nil, .null?:
            break
        case .array?:
            paths = try requiredTrimmedStringArray("paths", inputReader: inputReader)
        default:
            throw inputReader.typeError(fieldName: "paths", expectedDescription: "an array of strings or null")
        }
        if let folderPath {
            guard paths.isEmpty else { throw AgentToolInputError(messageForModel: eitherFormMessage) }
            return .readFolderMetadata(folderPath: folderPath)
        }
        guard (1...maximumMetadataPathsPerCall).contains(paths.count), !paths.contains(where: \.isEmpty) else {
            throw AgentToolInputError(messageForModel: eitherFormMessage)
        }
        return .readFileMetadata(paths: paths)
    }

    // MARK: - File operations

    private static func decodeSubmittedFileOperationsDraft(inputReader: ToolInputReader) throws -> SubmittedFileOperationsDraft {
        let groups = try decodeFileOperationGroups(inputReader: inputReader)
        let declaredGroupIdentifiers = Set(groups.map(\.groupIdentifier))

        guard let operationJSONValues = inputReader.inputObject["operations"]?.arrayValue else {
            throw inputReader.typeError(fieldName: "operations", expectedDescription: "an array")
        }
        guard operationJSONValues.count <= maximumOperationsPerSubmitCall else {
            throw AgentToolInputError(messageForModel:
                "Send at most \(maximumOperationsPerSubmitCall) operations per call; set continues_in_next_call.")
        }
        let operations = try operationJSONValues.enumerated().map { operationOffset, operationJSONValue in
            try decodeFileOperationDraft(operationJSONValue, operationNumber: operationOffset + 1,
                                         declaredGroupIdentifiers: declaredGroupIdentifiers)
        }

        guard let ruleJSONValues = inputReader.inputObject["date_folder_rules"]?.arrayValue else {
            throw inputReader.typeError(fieldName: "date_folder_rules", expectedDescription: "an array")
        }
        let dateFolderRules = try ruleJSONValues.map { ruleJSONValue in
            try decodeDateFolderRule(ruleJSONValue, declaredGroupIdentifiers: declaredGroupIdentifiers)
        }

        let renameRuleJSONValues: [JSONValue]
        switch inputReader.inputObject["rename_rules"] {
        case nil, .null?:
            renameRuleJSONValues = []
        case .array(let arrayValues)?:
            renameRuleJSONValues = arrayValues
        default:
            throw inputReader.typeError(fieldName: "rename_rules", expectedDescription: "an array")
        }
        let renameRules = try renameRuleJSONValues.map { ruleJSONValue in
            try decodeRenameRule(ruleJSONValue, declaredGroupIdentifiers: declaredGroupIdentifiers)
        }

        return SubmittedFileOperationsDraft(
            taskTitle: try requiredTrimmedNonEmptyString("task_title", inputReader: inputReader),
            messageToUser: try inputReader.optionalNonEmptyString("message_to_user"),
            groups: groups, operations: operations, dateFolderRules: dateFolderRules, renameRules: renameRules,
            continuesInNextCall: try inputReader.requiredBool("continues_in_next_call"))
    }

    private static func decodeFileOperationGroups(inputReader: ToolInputReader) throws -> [FileOperationGroup] {
        guard let groupJSONValues = inputReader.inputObject["groups"]?.arrayValue else {
            throw inputReader.typeError(fieldName: "groups", expectedDescription: "an array")
        }
        guard groupJSONValues.count <= maximumFileOperationGroups else {
            throw AgentToolInputError(messageForModel:
                "Invalid input for submit_file_operations_plan: use at most \(maximumFileOperationGroups) groups.")
        }
        var groups: [FileOperationGroup] = []
        for groupJSONValue in groupJSONValues {
            guard let groupObject = groupJSONValue.objectValue else {
                throw inputReader.typeError(fieldName: "groups", expectedDescription: "an array of {group_id, title} objects")
            }
            let groupReader = ToolInputReader(toolName: inputReader.toolName, inputObject: groupObject)
            let groupIdentifier = try requiredTrimmedNonEmptyString("group_id", inputReader: groupReader)
            guard !groups.contains(where: { $0.groupIdentifier == groupIdentifier }) else {
                throw AgentToolInputError(messageForModel:
                    "Invalid input for submit_file_operations_plan: group_id \"\(groupIdentifier)\" is declared twice.")
            }
            let title = truncated(try requiredTrimmedNonEmptyString("title", inputReader: groupReader), toLength: maximumGroupTitleLength)
            groups.append(FileOperationGroup(groupIdentifier: groupIdentifier, title: title))
        }
        return groups
    }

    private static func decodeFileOperationDraft(_ operationJSONValue: JSONValue, operationNumber: Int,
                                                 declaredGroupIdentifiers: Set<String>) throws -> SubmittedFileOperationDraft {
        guard let operationObject = operationJSONValue.objectValue else {
            throw AgentToolInputError(messageForModel: "Invalid input for submit_file_operations_plan: `operations` must be an array of objects.")
        }
        let operationReader = ToolInputReader(toolName: .submitFileOperationsPlan, inputObject: operationObject)
        let operationKind: FileOperationKind = try operationReader.requiredEnum("op")
        let fromPath = try optionalTrimmedNonEmptyString("from", inputReader: operationReader)
        let toPath = try optionalTrimmedNonEmptyString("to", inputReader: operationReader)
        let tags = try optionalTagList(operationObject["tags"], operationNumber: operationNumber)
        let groupIdentifier = try requiredTrimmedNonEmptyString("group_id", inputReader: operationReader)
        guard declaredGroupIdentifiers.contains(groupIdentifier) else {
            throw AgentToolInputError(messageForModel:
                "Invalid input for submit_file_operations_plan: operation \(operationNumber) uses group_id \"\(groupIdentifier)\", which isn't declared in `groups`.")
        }

        let shapeProblem: String?
        switch operationKind {
        case .createFolder:
            shapeProblem = (fromPath == nil && toPath != nil) ? nil : "create_folder needs `to` and a null `from`"
        case .move, .rename, .copy:
            shapeProblem = (fromPath != nil && toPath != nil) ? nil : "\(operationKind.rawValue) needs both `from` and `to`"
        case .setTags:
            shapeProblem = (fromPath != nil && tags != nil) ? nil : "set_tags needs `from` and `tags`"
        case .moveToTrash:
            shapeProblem = fromPath != nil ? nil : "move_to_trash needs `from`"
        }
        if let shapeProblem {
            throw AgentToolInputError(messageForModel:
                "Invalid input for submit_file_operations_plan: operation \(operationNumber): \(shapeProblem).")
        }

        return SubmittedFileOperationDraft(
            kind: operationKind,
            fromPath: fromPath,
            toPath: (operationKind == .setTags || operationKind == .moveToTrash) ? nil : toPath,
            tags: operationKind == .setTags ? tags : nil,
            reason: truncated(try operationReader.requiredString("reason").trimmingCharacters(in: .whitespacesAndNewlines),
                              toLength: maximumOperationReasonLength),
            groupIdentifier: groupIdentifier)
    }

    private static func optionalTagList(_ tagsJSONValue: JSONValue?, operationNumber: Int) throws -> [String]? {
        switch tagsJSONValue {
        case nil, .null?:
            return nil
        case .array(let tagJSONValues)?:
            let tags = tagJSONValues.compactMap(\.stringValue).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard tags.count == tagJSONValues.count, tags.count <= maximumTagsPerOperation, !tags.contains(where: \.isEmpty) else {
                throw AgentToolInputError(messageForModel:
                    "Invalid input for submit_file_operations_plan: operation \(operationNumber): `tags` must be at most \(maximumTagsPerOperation) non-empty strings.")
            }
            return tags
        default:
            throw AgentToolInputError(messageForModel:
                "Invalid input for submit_file_operations_plan: operation \(operationNumber): `tags` must be an array of strings or null.")
        }
    }

    private static func decodeDateFolderRule(_ ruleJSONValue: JSONValue,
                                             declaredGroupIdentifiers: Set<String>) throws -> SubmittedDateFolderRule {
        guard let ruleObject = ruleJSONValue.objectValue else {
            throw AgentToolInputError(messageForModel: "Invalid input for submit_file_operations_plan: `date_folder_rules` must be an array of objects.")
        }
        let ruleReader = ToolInputReader(toolName: .submitFileOperationsPlan, inputObject: ruleObject)
        let groupIdentifier = try requiredTrimmedNonEmptyString("group_id", inputReader: ruleReader)
        guard declaredGroupIdentifiers.contains(groupIdentifier) else {
            throw AgentToolInputError(messageForModel:
                "Invalid input for submit_file_operations_plan: a date folder rule uses group_id \"\(groupIdentifier)\", which isn't declared in `groups`.")
        }
        let (lowercasedExtensions, typeIdentifiers) = try decodeRuleFileFilterLists(ruleReader: ruleReader)
        return SubmittedDateFolderRule(
            sourceFolderPath: try requiredTrimmedNonEmptyString("source_folder", inputReader: ruleReader),
            destinationParentFolderPath: try requiredTrimmedNonEmptyString("destination_parent_folder", inputReader: ruleReader),
            nameContains: try optionalTrimmedNonEmptyString("name_contains", inputReader: ruleReader),
            lowercasedExtensions: lowercasedExtensions,
            typeIdentifiers: typeIdentifiers,
            dateSource: try ruleReader.requiredEnum("date_source"),
            folderNameFormat: try requiredTrimmedNonEmptyString("folder_name_format", inputReader: ruleReader),
            groupIdentifier: groupIdentifier)
    }

    private static func decodeRenameRule(_ ruleJSONValue: JSONValue,
                                         declaredGroupIdentifiers: Set<String>) throws -> SubmittedRenameRule {
        guard let ruleObject = ruleJSONValue.objectValue else {
            throw AgentToolInputError(messageForModel: "Invalid input for submit_file_operations_plan: `rename_rules` must be an array of objects.")
        }
        let ruleReader = ToolInputReader(toolName: .submitFileOperationsPlan, inputObject: ruleObject)
        let groupIdentifier = try requiredTrimmedNonEmptyString("group_id", inputReader: ruleReader)
        guard declaredGroupIdentifiers.contains(groupIdentifier) else {
            throw AgentToolInputError(messageForModel:
                "Invalid input for submit_file_operations_plan: a rename rule uses group_id \"\(groupIdentifier)\", which isn't declared in `groups`.")
        }
        let (lowercasedExtensions, typeIdentifiers) = try decodeRuleFileFilterLists(ruleReader: ruleReader)
        let dateSource: DateFolderRuleDateSource?
        switch ruleObject["date_source"] {
        case nil, .null?: dateSource = nil
        default: dateSource = try ruleReader.requiredEnum("date_source")
        }
        let isDescending: Bool
        switch ruleObject["descending"] {
        case nil, .null?: isDescending = false
        default: isDescending = try ruleReader.requiredBool("descending")
        }
        return SubmittedRenameRule(
            sourceFolderPath: try requiredTrimmedNonEmptyString("source_folder", inputReader: ruleReader),
            nameContains: try optionalTrimmedNonEmptyString("name_contains", inputReader: ruleReader),
            lowercasedExtensions: lowercasedExtensions,
            typeIdentifiers: typeIdentifiers,
            order: try ruleReader.requiredEnum("order_by"),
            isDescending: isDescending,
            dateSource: dateSource,
            nameTemplate: try requiredTrimmedNonEmptyString("name_template", inputReader: ruleReader),
            groupIdentifier: groupIdentifier)
    }

    /// `extensions` lowercased without a leading dot, and `type_identifiers`, both without empty entries.
    private static func decodeRuleFileFilterLists(ruleReader: ToolInputReader) throws -> (lowercasedExtensions: [String], typeIdentifiers: [String]) {
        let lowercasedExtensions = try requiredTrimmedStringArray("extensions", inputReader: ruleReader)
            .map { rawExtension in
                (rawExtension.hasPrefix(".") ? String(rawExtension.dropFirst()) : rawExtension).lowercased()
            }
            .filter { !$0.isEmpty }
        let typeIdentifiers = try requiredTrimmedStringArray("type_identifiers", inputReader: ruleReader).filter { !$0.isEmpty }
        return (lowercasedExtensions, typeIdentifiers)
    }

    // MARK: - Scripts and shortcuts

    private static func decodeSubmittedScriptPlanDraft(inputReader: ToolInputReader) throws -> SubmittedScriptPlanDraft {
        let source = try inputReader.requiredString("source")
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolInputError(messageForModel: "Invalid input for submit_script_plan: `source` must not be empty.")
        }
        guard source.count <= ScriptPlan.maximumSourceLength else {
            throw AgentToolInputError(messageForModel:
                "Invalid input for submit_script_plan: `source` is longer than \(ScriptPlan.maximumSourceLength) characters. Keep the script short, or use submit_plan.")
        }
        let expectedEffects = try requiredTrimmedStringArray("expected_effects", inputReader: inputReader)
            .filter { !$0.isEmpty }
            .prefix(maximumExpectedEffectCount)
            .map { truncated($0, toLength: maximumExpectedEffectLength) }
        return SubmittedScriptPlanDraft(
            taskTitle: try requiredTrimmedNonEmptyString("task_title", inputReader: inputReader),
            targetBundleIdentifier: try requiredTrimmedNonEmptyString("target_bundle_id", inputReader: inputReader),
            language: try inputReader.requiredEnum("language"),
            source: source,
            summary: truncated(try requiredTrimmedNonEmptyString("summary", inputReader: inputReader), toLength: maximumScriptSummaryLength),
            expectedEffects: Array(expectedEffects),
            modifiesData: try inputReader.requiredBool("modifies_data"),
            timeoutSeconds: try inputReader.requiredInteger("timeout_seconds", clampedTo: allowedScriptTimeoutSeconds))
    }

    private enum ShortcutInputKind: String { case none, text, files }

    private static func decodeSubmittedShortcutPlanDraft(inputReader: ToolInputReader) throws -> SubmittedShortcutPlanDraft {
        let inputKind: ShortcutInputKind = try inputReader.requiredEnum("input_kind")
        let shortcutInput: ShortcutInput
        switch inputKind {
        case .none:
            shortcutInput = .none
        case .text:
            guard let inputText = try inputReader.optionalNonEmptyString("input_text") else {
                throw AgentToolInputError(messageForModel: "Invalid input for submit_shortcut_plan: input_kind text needs a non-empty `input_text`.")
            }
            shortcutInput = .text(inputText)
        case .files:
            let inputFilePaths = try requiredTrimmedStringArray("input_file_paths", inputReader: inputReader)
            guard (1...maximumShortcutInputFileCount).contains(inputFilePaths.count), !inputFilePaths.contains(where: \.isEmpty) else {
                throw AgentToolInputError(messageForModel:
                    "Invalid input for submit_shortcut_plan: input_kind files needs 1-\(maximumShortcutInputFileCount) absolute paths in `input_file_paths`.")
            }
            shortcutInput = .files(inputFilePaths)
        }
        return SubmittedShortcutPlanDraft(
            taskTitle: try requiredTrimmedNonEmptyString("task_title", inputReader: inputReader),
            shortcutName: try requiredTrimmedNonEmptyString("shortcut_name", inputReader: inputReader),
            input: shortcutInput,
            summary: truncated(try requiredTrimmedNonEmptyString("summary", inputReader: inputReader), toLength: maximumScriptSummaryLength),
            timeoutSeconds: try inputReader.requiredInteger("timeout_seconds", clampedTo: allowedScriptTimeoutSeconds))
    }

    // MARK: - Field helpers

    private static func requiredTrimmedNonEmptyString(_ fieldName: String, inputReader: ToolInputReader) throws -> String {
        let trimmedValue = try inputReader.requiredString(fieldName).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { throw inputReader.typeError(fieldName: fieldName, expectedDescription: "a non-empty string") }
        return trimmedValue
    }

    private static func optionalTrimmedNonEmptyString(_ fieldName: String, inputReader: ToolInputReader) throws -> String? {
        guard let rawValue = try inputReader.optionalNonEmptyString(fieldName) else { return nil }
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private static func requiredTrimmedStringArray(_ fieldName: String, inputReader: ToolInputReader) throws -> [String] {
        guard let elementJSONValues = inputReader.inputObject[fieldName]?.arrayValue else {
            throw inputReader.typeError(fieldName: fieldName, expectedDescription: "an array of strings")
        }
        return try elementJSONValues.map { elementJSONValue in
            guard let stringValue = elementJSONValue.stringValue else {
                throw inputReader.typeError(fieldName: fieldName, expectedDescription: "an array of strings")
            }
            return stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func truncated(_ text: String, toLength maximumLength: Int) -> String {
        text.count <= maximumLength ? text : String(text.prefix(maximumLength - 1)) + "…"
    }
}
