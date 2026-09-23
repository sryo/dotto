import Foundation

/// A small in-memory reader for planner tests: every path is canonical already, and folders, files and dates are
/// whatever the test registers.
private final class PlannerTestFileSystemReader: DirectRouteFileSystemReading, @unchecked Sendable {
    var itemKindByPath: [String: ExistingFileSystemItemKind] = ["/": .folder, "/Users": .folder, "/Users/tester": .folder]
    var creationDateByPath: [String: Date] = [:]
    private(set) var metadataReadPaths: [String] = []

    func addFolder(_ path: String) { itemKindByPath[path] = .folder }
    func addFile(_ path: String, createdAt: Date) {
        itemKindByPath[path] = .regularFile
        creationDateByPath[path] = createdAt
    }

    func canonicalPathKeepingLastComponent(_ path: String) -> String? {
        itemKindByPath[(path as NSString).deletingLastPathComponent] == .folder ? path : nil
    }

    func canonicalExistingFolderPath(_ path: String) -> String? { itemKindByPath[path] == .folder ? path : nil }
    func existingItemKind(atCanonicalPath canonicalPath: String) -> ExistingFileSystemItemKind? { itemKindByPath[canonicalPath] }
    func volumeIdentifier(ofCanonicalPath canonicalPath: String) -> String? { "test-volume" }

    func listFolder(atCanonicalPath canonicalPath: String, depth: Int, includesHiddenItems: Bool,
                    maximumEntryCount: Int, abortSignal: TaskAbortSignal) async throws -> FolderListing {
        let childEntries = itemKindByPath.keys
            .filter { $0 != "/" && ($0 as NSString).deletingLastPathComponent == canonicalPath }
            .sorted()
            .map { FolderListingEntry(path: $0, kind: itemKindByPath[$0] ?? .other, isHidden: ($0 as NSString).lastPathComponent.hasPrefix("."), depth: 1) }
            .filter { includesHiddenItems || !$0.isHidden }
        return FolderListing(folderPath: canonicalPath, entries: Array(childEntries.prefix(maximumEntryCount)),
                             omittedEntryCount: max(0, childEntries.count - maximumEntryCount))
    }

    func readMetadata(ofCanonicalPaths canonicalPaths: [String], abortSignal: TaskAbortSignal) async throws -> [FileMetadataRecord] {
        metadataReadPaths += canonicalPaths
        return canonicalPaths.compactMap { canonicalPath in
            guard let itemKind = itemKindByPath[canonicalPath] else { return nil }
            let isImage = canonicalPath.hasSuffix(".png")
            return FileMetadataRecord(
                path: canonicalPath, kind: itemKind, isHidden: false, sizeInBytes: 10, createdAt: creationDateByPath[canonicalPath],
                modifiedAt: nil, addedToFolderAt: nil, contentTypeIdentifier: isImage ? "public.png" : "public.plain-text",
                conformingTypeIdentifiers: isImage ? ["public.png", "public.image", "public.data", "public.item"] : ["public.plain-text"],
                imageCaptureDate: nil, imagePixelWidth: nil, imagePixelHeight: nil, finderTags: [], contentIsNotLocal: false,
                volumeIdentifier: "test-volume")
        }
    }
}

private final class PlannerTestShortcutRunner: ShortcutRunning, @unchecked Sendable {
    let shortcutNames: [String]
    private(set) var listCallCount = 0
    init(shortcutNames: [String]) { self.shortcutNames = shortcutNames }

    func listShortcutNames(abortSignal: TaskAbortSignal) async throws -> [String] {
        listCallCount += 1
        return shortcutNames
    }

    func run(_ shortcutPlan: ShortcutPlan, abortSignal: TaskAbortSignal) async throws -> ShortcutRunOutput {
        throw CoreTestFailure(description: "planning never runs a shortcut")
    }
}

private let scopeFolderPath = "/Users/tester/Shots"

private func utcDate(_ isoText: String) -> Date { ISO8601DateFormatter().date(from: isoText) ?? Date(timeIntervalSince1970: 0) }

private func makeScreenshotsReader() -> PlannerTestFileSystemReader {
    let fileSystemReader = PlannerTestFileSystemReader()
    fileSystemReader.addFolder(scopeFolderPath)
    fileSystemReader.addFile(scopeFolderPath + "/a.png", createdAt: utcDate("2026-08-10T12:00:00Z"))
    fileSystemReader.addFile(scopeFolderPath + "/b.png", createdAt: utcDate("2026-09-02T12:00:00Z"))
    fileSystemReader.addFile(scopeFolderPath + "/notes.txt", createdAt: utcDate("2026-09-03T12:00:00Z"))
    fileSystemReader.addFolder("/Users/tester/Private")
    return fileSystemReader
}

private func makeDirectRoutePlanner(replies: [ScriptedClaudeTransport.ScriptedReply],
                                    fileSystemReader: PlannerTestFileSystemReader = makeScreenshotsReader(),
                                    shortcutRunner: PlannerTestShortcutRunner? = nil,
                                    directRoutesAreEnabled: Bool = true,
                                    targetApplicationIsScriptable: Bool = true,
                                    safetyLimits: SafetyLimits = .standard) throws -> (ChecklistPlanner, ScriptedClaudeTransport) {
    let transport = ScriptedClaudeTransport(replies: replies)
    let checklistPlanner = ChecklistPlanner(transport: transport,
                                            actionBackend: FakeActionBackend(snapshotRootNodes: ConversationFixtures.windowRootNodes()),
                                            auditLogWriter: try ConversationFixtures.makeAuditLogWriter(),
                                            taskResourceBudget: TaskResourceBudget(safetyLimits: .standard), safetyLimits: safetyLimits)
    checklistPlanner.directRouteContext = PlannerDirectRouteContext(
        scope: DirectRouteScope(roots: [DirectRouteScopeRoot(canonicalPath: scopeFolderPath, source: .finderWindowUnderSummonPoint)]),
        targetApplicationIsScriptable: targetApplicationIsScriptable, targetApplicationAutomationState: .granted,
        directRoutesAreEnabled: directRoutesAreEnabled)
    checklistPlanner.directRouteFileSystemReader = fileSystemReader
    checklistPlanner.shortcutRunner = shortcutRunner
    checklistPlanner.directRouteHomeDirectoryPath = "/Users/tester"
    checklistPlanner.dateFolderNamingEnvironment = DateFolderNamingEnvironment(timeZoneIdentifier: "UTC", localeIdentifier: "en_US",
                                                                              calendarIdentifier: "gregorian")
    return (checklistPlanner, transport)
}

private func planDirectRoute(with checklistPlanner: ChecklistPlanner) async throws -> ChecklistPlanningResult {
    try await checklistPlanner.produceChecklist(command: "sort these screenshots by month", targetApplication: fixtureTargetApplication,
                                                taskIdentifier: "direct-task", abortSignal: TaskAbortSignal(), onProgress: { _ in })
}

private func toolResult(ofRequest requestIndex: Int, in transport: ScriptedClaudeTransport) throws -> (text: String, isError: Bool) {
    let resultBlock = try unwrapOrFail(ConversationFixtures.toolResults(inLastMessageOf: transport.recordedRequests[requestIndex]).first)
    return (ConversationFixtures.firstText(of: resultBlock), resultBlock.isError)
}

private let minimalSubmitPlanInput = #"{"task_title":"Sort","message_to_user":null,"items":[{"label":"Sort a","action_summary":"Sort a.","parameters":[],"is_irreversible":false}]}"#

private func fileOperationsSubmitInput(operationsJSON: String, rulesJSON: String = "[]", continues: Bool = false) -> String {
    #"{"task_title":"Sort screenshots by month","message_to_user":null,"groups":[{"group_id":"months","title":"Move screenshots into month folders"},{"group_id":"notes","title":"Rename 1 note"}],"operations":\#(operationsJSON),"date_folder_rules":\#(rulesJSON),"continues_in_next_call":\#(continues)}"#
}

private let monthRuleJSON = #"[{"source_folder":"/Users/tester/Shots","destination_parent_folder":"/Users/tester/Shots","name_contains":null,"extensions":["png"],"type_identifiers":[],"date_source":"capture_date_or_created","folder_name_format":"yyyy-MM","group_id":"months"}]"#

private let renameNoteOperationJSON = #"{"op":"rename","from":"/Users/tester/Shots/notes.txt","to":"/Users/tester/Shots/notes-2026.txt","tags":null,"reason":"dated name","group_id":"notes"}"#

let checklistPlannerDirectRouteTestSuite = CoreTestSuite(name: "ChecklistPlanner direct routes", testCases: [
    CoreTestCase(name: "list_folder outside the scope is a tool error, not a thrown one, and nothing is listed") {
        let (checklistPlanner, transport) = try makeDirectRoutePlanner(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_list", "list_folder",
                #"{"path":"/Users/tester/Private","depth":1,"include_hidden":false}"#)),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_plan", "submit_plan", minimalSubmitPlanInput)),
        ])
        guard case .checklist(let checklist) = try await planDirectRoute(with: checklistPlanner) else {
            throw CoreTestFailure(description: "expected the checklist fallback")
        }
        try expectEqual(checklist.directRoutePlan, nil)
        let listResult = try toolResult(ofRequest: 1, in: transport)
        try expectEqual(listResult.isError, true)
        try expectTrue(listResult.text.contains("outside the scope folders"), listResult.text)
    },
    CoreTestCase(name: "list_folder inside the scope lists entries fenced as untrusted") {
        let (checklistPlanner, transport) = try makeDirectRoutePlanner(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_list", "list_folder",
                #"{"path":"/Users/tester/Shots/","depth":1,"include_hidden":false}"#)),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_plan", "submit_plan", minimalSubmitPlanInput)),
        ])
        _ = try await planDirectRoute(with: checklistPlanner)
        let listResult = try toolResult(ofRequest: 1, in: transport)
        try expectEqual(listResult.isError, false)
        try expectTrue(listResult.text.contains("<untrusted_ui>\nFolder: /Users/tester/Shots\nfile  a.png\nfile  b.png\nfile  notes.txt\n</untrusted_ui>"),
                       listResult.text)
    },
    CoreTestCase(name: "a date rule plus an explicit rename becomes a two-group checklist carrying the plan") {
        let (checklistPlanner, transport) = try makeDirectRoutePlanner(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_submit", "submit_file_operations_plan",
                fileOperationsSubmitInput(operationsJSON: "[\(renameNoteOperationJSON)]", rulesJSON: monthRuleJSON))),
        ])
        guard case .checklist(let checklist) = try await planDirectRoute(with: checklistPlanner) else {
            throw CoreTestFailure(description: "expected a checklist")
        }
        try expectEqual(transport.recordedRequests.count, 1, "the accepted plan ends planning")
        try expectEqual(checklist.title, "Sort screenshots by month")
        try expectEqual(checklist.items.map(\.label), ["Move screenshots into month folders", "Rename 1 note"])
        guard case .fileOperations(let fileOperationsPlan)? = checklist.directRoutePlan else {
            throw CoreTestFailure(description: "expected a file operations plan")
        }
        try expectEqual(fileOperationsPlan.operations.map(\.kind), [.createFolder, .createFolder, .move, .move, .rename])
        try expectEqual(fileOperationsPlan.operations.map(\.operationIdentifier), ["op-1", "op-2", "op-3", "op-4", "op-5"])
        try expectEqual(fileOperationsPlan.operations[2].destinationPath, "/Users/tester/Shots/2026-08/a.png")
        try expectEqual(fileOperationsPlan.scope.roots.map(\.canonicalPath), [scopeFolderPath])
        try expectEqual(checklist.items[0].parameters, [ChecklistItemParameter(name: "operation_count", value: "4")])
    },
    CoreTestCase(name: "an invalid plan comes back as problems; the fixed resubmission is accepted in the same conversation") {
        let missingSourceOperation = #"{"op":"move","from":"/Users/tester/Shots/missing.png","to":"/Users/tester/Shots/x/missing.png","tags":null,"reason":"r","group_id":"months"}"#
        let (checklistPlanner, transport) = try makeDirectRoutePlanner(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_bad", "submit_file_operations_plan",
                fileOperationsSubmitInput(operationsJSON: "[\(missingSourceOperation)]"))),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_good", "submit_file_operations_plan",
                fileOperationsSubmitInput(operationsJSON: "[\(renameNoteOperationJSON)]"))),
        ])
        guard case .checklist(let checklist) = try await planDirectRoute(with: checklistPlanner) else {
            throw CoreTestFailure(description: "expected a checklist")
        }
        let problemResult = try toolResult(ofRequest: 1, in: transport)
        try expectEqual(problemResult.isError, true)
        try expectTrue(problemResult.text.hasPrefix("The plan wasn't accepted"), problemResult.text)
        try expectEqual(checklist.items.map(\.label), ["Rename 1 note"], "only groups with operations become items")
    },
    CoreTestCase(name: "a plan sent in two calls is accepted whole on the last call") {
        let firstMoveJSON = #"{"op":"create_folder","from":null,"to":"/Users/tester/Shots/Old","tags":null,"reason":"r","group_id":"months"}"#
        let secondMoveJSON = #"{"op":"move","from":"/Users/tester/Shots/a.png","to":"/Users/tester/Shots/Old/a.png","tags":null,"reason":"r","group_id":"months"}"#
        let (checklistPlanner, transport) = try makeDirectRoutePlanner(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_part1", "submit_file_operations_plan",
                fileOperationsSubmitInput(operationsJSON: "[\(firstMoveJSON)]", continues: true))),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_part2", "submit_file_operations_plan",
                fileOperationsSubmitInput(operationsJSON: "[\(secondMoveJSON)]"))),
        ])
        guard case .checklist(let checklist) = try await planDirectRoute(with: checklistPlanner),
              case .fileOperations(let fileOperationsPlan)? = checklist.directRoutePlan else {
            throw CoreTestFailure(description: "expected a file operations checklist")
        }
        let partResult = try toolResult(ofRequest: 1, in: transport)
        try expectEqual(partResult.isError, false)
        try expectTrue(partResult.text.contains("Send the rest."), partResult.text)
        try expectEqual(fileOperationsPlan.operations.map(\.kind), [.createFolder, .move])
    },
    CoreTestCase(name: "a script with do shell script is refused with what to remove") {
        let shellScriptInput = #"{"task_title":"List","target_bundle_id":"com.apple.finder","language":"applescript","source":"tell application \"Finder\"\n do shell script \"ls\"\nend tell","summary":"Lists.","expected_effects":["Nothing"],"modifies_data":false,"timeout_seconds":30}"#
        let (checklistPlanner, transport) = try makeDirectRoutePlanner(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_script", "submit_script_plan", shellScriptInput)),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_plan", "submit_plan", minimalSubmitPlanInput)),
        ])
        guard case .checklist(let checklist) = try await planDirectRoute(with: checklistPlanner) else {
            throw CoreTestFailure(description: "expected the checklist fallback")
        }
        try expectEqual(checklist.directRoutePlan, nil)
        let scriptResult = try toolResult(ofRequest: 1, in: transport)
        try expectEqual(scriptResult.isError, true)
        try expectTrue(scriptResult.text.contains("do shell script"), scriptResult.text)
    },
    CoreTestCase(name: "a script for another app is refused; a clean one for the target is accepted and inspected by Dotto") {
        let otherAppInput = #"{"task_title":"Mail","target_bundle_id":"com.apple.mail","language":"applescript","source":"tell application \"Mail\" to return \"ok\"","summary":"s","expected_effects":[],"modifies_data":false,"timeout_seconds":30}"#
        let cleanFinderInput = #"{"task_title":"Count windows","target_bundle_id":"com.apple.finder","language":"applescript","source":"tell application \"Finder\"\nreturn (count of Finder windows) as text\nend tell","summary":"Counts Finder windows.","expected_effects":["Nothing changes"],"modifies_data":false,"timeout_seconds":30}"#
        let (checklistPlanner, transport) = try makeDirectRoutePlanner(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_mail", "submit_script_plan", otherAppInput)),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_finder", "submit_script_plan", cleanFinderInput)),
        ])
        guard case .checklist(let checklist) = try await planDirectRoute(with: checklistPlanner),
              case .script(let scriptPlan)? = checklist.directRoutePlan else {
            throw CoreTestFailure(description: "expected a script checklist")
        }
        let otherAppResult = try toolResult(ofRequest: 1, in: transport)
        try expectEqual(otherAppResult.isError, true)
        try expectTrue(otherAppResult.text.contains("com.apple.finder"), otherAppResult.text)
        try expectEqual(scriptPlan.targetApplicationName, "Finder")
        try expectEqual(scriptPlan.inspection.deniedConstructs, [])
        try expectEqual(checklist.items.map(\.label), ["Run script in Finder"])
    },
    CoreTestCase(name: "a script is refused when the target app isn't scriptable") {
        let cleanFinderInput = #"{"task_title":"t","target_bundle_id":"com.apple.finder","language":"applescript","source":"tell application \"Finder\" to return \"ok\"","summary":"s","expected_effects":[],"modifies_data":false,"timeout_seconds":30}"#
        let (checklistPlanner, transport) = try makeDirectRoutePlanner(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_script", "submit_script_plan", cleanFinderInput)),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_plan", "submit_plan", minimalSubmitPlanInput)),
        ], targetApplicationIsScriptable: false)
        _ = try await planDirectRoute(with: checklistPlanner)
        try expectEqual(try toolResult(ofRequest: 1, in: transport).isError, true)
    },
    CoreTestCase(name: "a shortcut runs only under an exactly listed name; the list is read once per task") {
        let shortcutRunner = PlannerTestShortcutRunner(shortcutNames: ["Resize for web", "Make GIF"])
        let (checklistPlanner, transport) = try makeDirectRoutePlanner(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_list", "list_shortcuts", #"{"query":"resize"}"#)),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_wrong", "submit_shortcut_plan",
                #"{"task_title":"t","shortcut_name":"resize for web","input_kind":"none","input_text":null,"input_file_paths":[],"summary":"s","timeout_seconds":60}"#)),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_right", "submit_shortcut_plan",
                #"{"task_title":"Resize","shortcut_name":"Resize for web","input_kind":"files","input_text":null,"input_file_paths":["/Users/tester/Shots/a.png"],"summary":"Resizes a.png.","timeout_seconds":60}"#)),
        ], shortcutRunner: shortcutRunner)
        guard case .checklist(let checklist) = try await planDirectRoute(with: checklistPlanner),
              case .shortcut(let shortcutPlan)? = checklist.directRoutePlan else {
            throw CoreTestFailure(description: "expected a shortcut checklist")
        }
        let listResult = try toolResult(ofRequest: 1, in: transport)
        try expectTrue(listResult.text.contains("<untrusted_ui>\n- Resize for web\n</untrusted_ui>"), listResult.text)
        try expectEqual(try toolResult(ofRequest: 2, in: transport).isError, true, "names match exactly, case included")
        try expectEqual(shortcutPlan.input, .files(["/Users/tester/Shots/a.png"]))
        try expectEqual(shortcutRunner.listCallCount, 1)
        try expectEqual(checklist.items.map(\.label), ["Run shortcut “Resize for web”"])
    },
    CoreTestCase(name: "with direct routes off, direct tools answer that they are unavailable and nothing is read") {
        let fileSystemReader = makeScreenshotsReader()
        let (checklistPlanner, transport) = try makeDirectRoutePlanner(replies: [
            try ConversationFixtures.toolTurn(
                ConversationFixtures.toolUse("toolu_meta", "read_file_metadata", #"{"paths":["/Users/tester/Shots/a.png"]}"#),
                ConversationFixtures.toolUse("toolu_submit", "submit_file_operations_plan",
                                             fileOperationsSubmitInput(operationsJSON: "[\(renameNoteOperationJSON)]"))),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_plan", "submit_plan", minimalSubmitPlanInput)),
        ], fileSystemReader: fileSystemReader, directRoutesAreEnabled: false)
        guard case .checklist(let checklist) = try await planDirectRoute(with: checklistPlanner) else {
            throw CoreTestFailure(description: "expected the checklist")
        }
        try expectEqual(checklist.directRoutePlan, nil)
        let turnResults = ConversationFixtures.toolResults(inLastMessageOf: transport.recordedRequests[1])
        try expectEqual(turnResults.map(\.isError), [true, true])
        try expectEqual(turnResults.map(ConversationFixtures.firstText(of:)),
                        [PromptLibrary.directRoutesUnavailableToolText, PromptLibrary.directRoutesUnavailableToolText])
        try expectEqual(fileSystemReader.metadataReadPaths, [])
        try expectTrue(ConversationFixtures.initialUserText(of: transport.recordedRequests[0])
            .contains("Direct routes are off for this task: use submit_plan."))
    },
    CoreTestCase(name: "read_file_metadata reads inside the scope and refuses the whole call if any path is outside") {
        let fileSystemReader = makeScreenshotsReader()
        let (checklistPlanner, transport) = try makeDirectRoutePlanner(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_mixed", "read_file_metadata",
                #"{"paths":["/Users/tester/Shots/a.png","/Users/tester/Private"]}"#)),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_inside", "read_file_metadata",
                #"{"paths":["/Users/tester/Shots/a.png","/Users/tester/Shots/gone.png"]}"#)),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_plan", "submit_plan", minimalSubmitPlanInput)),
        ], fileSystemReader: fileSystemReader)
        _ = try await planDirectRoute(with: checklistPlanner)
        try expectEqual(try toolResult(ofRequest: 1, in: transport).isError, true)
        let insideResult = try toolResult(ofRequest: 2, in: transport)
        try expectEqual(insideResult.isError, false)
        try expectTrue(insideResult.text.contains("/Users/tester/Shots/a.png | file | 10 bytes | 2026-08-10T12:00:00Z"), insideResult.text)
        try expectTrue(insideResult.text.contains("/Users/tester/Shots/gone.png | missing"), insideResult.text)
        try expectEqual(fileSystemReader.metadataReadPaths, ["/Users/tester/Shots/a.png"])
    },
    CoreTestCase(name: "a folder the user names in a reply becomes a scope folder; a protected one doesn't") {
        let fileSystemReader = makeScreenshotsReader()
        fileSystemReader.addFolder("/Users/tester/Desktop")
        fileSystemReader.addFolder("/Users/tester/Library")
        let (checklistPlanner, transport) = try makeDirectRoutePlanner(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_ask", "ask_user",
                #"{"question":"Which folder?","choices":[],"allow_free_text":true}"#)),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_list", "list_folder",
                #"{"path":"/Users/tester/Desktop","depth":1,"include_hidden":false}"#)),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_plan", "submit_plan", minimalSubmitPlanInput)),
        ], fileSystemReader: fileSystemReader)
        checklistPlanner.directRouteContext.scope = .empty
        guard case .question = try await planDirectRoute(with: checklistPlanner) else { throw CoreTestFailure(description: "expected a question") }
        _ = try await checklistPlanner.continuePlanning(withUserReply: "my Desktop folder, not ~/Library", abortSignal: TaskAbortSignal(),
                                                        onProgress: { _ in })
        try expectEqual(checklistPlanner.directRouteContext.scope.roots,
                        [DirectRouteScopeRoot(canonicalPath: "/Users/tester/Desktop", source: .typedInUserReply)])
        let replyText = try toolResult(ofRequest: 1, in: transport).text
        try expectTrue(replyText.contains("</user_reply>\n\nDotto added these scope folders from the user's reply:\n<untrusted_ui>\n- /Users/tester/Desktop\n</untrusted_ui>"),
                       replyText)
        try expectEqual(try toolResult(ofRequest: 2, in: transport).isError, false, "list_folder now works there")
    },
    CoreTestCase(name: "a rule over an already sorted folder ends planning with a message, not a tool error") {
        let sortedReader = PlannerTestFileSystemReader()
        sortedReader.addFolder(scopeFolderPath)
        sortedReader.addFolder(scopeFolderPath + "/2026-08")
        sortedReader.addFile(scopeFolderPath + "/2026-08/a.png", createdAt: utcDate("2026-08-10T12:00:00Z"))
        let (checklistPlanner, transport) = try makeDirectRoutePlanner(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_submit", "submit_file_operations_plan",
                fileOperationsSubmitInput(operationsJSON: "[]", rulesJSON: monthRuleJSON))),
        ], fileSystemReader: sortedReader)
        let planningResult = try await planDirectRoute(with: checklistPlanner)
        try expectEqual(planningResult, .cannotPlan(messageToUser: ChecklistPlanner.nothingToChangeMessageToUser))
        try expectEqual(transport.recordedRequests.count, 1, "no second turn to fix a problem")
    },
    CoreTestCase(name: "a date rule counts only the files it matches, and the folders it creates don't count") {
        let crowdedReader = makeScreenshotsReader()
        for noteNumber in 1...5 { crowdedReader.addFile(scopeFolderPath + "/note \(noteNumber).txt", createdAt: utcDate("2026-09-03T12:00:00Z")) }
        for folderNumber in 1...5 { crowdedReader.addFolder(scopeFolderPath + "/Folder \(folderNumber)") }
        let (checklistPlanner, transport) = try makeDirectRoutePlanner(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_submit", "submit_file_operations_plan",
                fileOperationsSubmitInput(operationsJSON: "[]", rulesJSON: monthRuleJSON))),
        ], fileSystemReader: crowdedReader, safetyLimits: {
            var tightLimits = SafetyLimits.standard
            tightLimits.maximumFileOperationsPerTask = 2
            return tightLimits
        }())
        guard case .checklist(let checklist) = try await planDirectRoute(with: checklistPlanner),
              case .fileOperations(let fileOperationsPlan)? = checklist.directRoutePlan else {
            throw CoreTestFailure(description: "expected a file operations checklist, got \(try toolResult(ofRequest: 0, in: transport))")
        }
        try expectEqual(fileOperationsPlan.operations.map(\.kind), [.createFolder, .createFolder, .move, .move])
        try expectEqual(crowdedReader.metadataReadPaths, [scopeFolderPath + "/a.png", scopeFolderPath + "/b.png"],
                        "files the rule can't match aren't read")
    },
    CoreTestCase(name: "a rule that matches more files than the cap says how many and what the limit is") {
        let (checklistPlanner, transport) = try makeDirectRoutePlanner(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_submit", "submit_file_operations_plan",
                fileOperationsSubmitInput(operationsJSON: "[]", rulesJSON: monthRuleJSON))),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_plan", "submit_plan", minimalSubmitPlanInput)),
        ], safetyLimits: {
            var tightLimits = SafetyLimits.standard
            tightLimits.maximumFileOperationsPerTask = 1
            return tightLimits
        }())
        _ = try await planDirectRoute(with: checklistPlanner)
        let ruleResult = try toolResult(ofRequest: 1, in: transport)
        try expectEqual(ruleResult.isError, true)
        try expectTrue(ruleResult.text.contains("2 files in “Shots” match, and one plan may move at most 1"), ruleResult.text)
    },
    CoreTestCase(name: "explicit folders run before a rule that sorts into them, and problems name what the model wrote") {
        let rulesIntoNewFolder = #"[{"source_folder":"/Users/tester/Shots","destination_parent_folder":"/Users/tester/Shots/Sorted","name_contains":null,"extensions":["png"],"type_identifiers":[],"date_source":"capture_date_or_created","folder_name_format":"yyyy-MM","group_id":"months"}]"#
        let createSortedJSON = #"{"op":"create_folder","from":null,"to":"/Users/tester/Shots/Sorted","tags":null,"reason":"r","group_id":"months"}"#
        let badRenameJSON = #"{"op":"rename","from":"/Users/tester/Shots/missing.txt","to":"/Users/tester/Shots/x.txt","tags":null,"reason":"r","group_id":"notes"}"#
        let (checklistPlanner, transport) = try makeDirectRoutePlanner(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_bad", "submit_file_operations_plan",
                fileOperationsSubmitInput(operationsJSON: "[\(createSortedJSON), \(badRenameJSON)]", rulesJSON: rulesIntoNewFolder))),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_good", "submit_file_operations_plan",
                fileOperationsSubmitInput(operationsJSON: "[\(createSortedJSON)]", rulesJSON: rulesIntoNewFolder))),
        ])
        guard case .checklist(let checklist) = try await planDirectRoute(with: checklistPlanner),
              case .fileOperations(let fileOperationsPlan)? = checklist.directRoutePlan else {
            throw CoreTestFailure(description: "expected a file operations checklist")
        }
        let problemText = try toolResult(ofRequest: 1, in: transport).text
        try expectTrue(problemText.contains("- Operation 2 (rename):"), problemText)
        try expectEqual(fileOperationsPlan.operations.map(\.destinationPath), [
            "/Users/tester/Shots/Sorted", "/Users/tester/Shots/Sorted/2026-08", "/Users/tester/Shots/Sorted/2026-09",
            "/Users/tester/Shots/Sorted/2026-08/a.png", "/Users/tester/Shots/Sorted/2026-09/b.png",
        ])
    },
    CoreTestCase(name: "a rename rule becomes one rename per file, oldest first, and files without a date are counted") {
        let fileSystemReader = makeScreenshotsReader()
        fileSystemReader.itemKindByPath[scopeFolderPath + "/undated.png"] = .regularFile
        let renameRuleJSON = #"[{"source_folder":"/Users/tester/Shots/","name_contains":null,"extensions":["png"],"type_identifiers":[],"order_by":"created","descending":false,"date_source":null,"name_template":"shot-{n:2}","group_id":"months"}]"#
        let submitInput = #"{"task_title":"Number screenshots","message_to_user":null,"groups":[{"group_id":"months","title":"Rename 2 screenshots"}],"operations":[],"date_folder_rules":[],"rename_rules":\#(renameRuleJSON),"continues_in_next_call":false}"#
        let (checklistPlanner, transport) = try makeDirectRoutePlanner(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_submit", "submit_file_operations_plan", submitInput)),
        ], fileSystemReader: fileSystemReader)
        guard case .checklist(let checklist) = try await planDirectRoute(with: checklistPlanner),
              case .fileOperations(let fileOperationsPlan)? = checklist.directRoutePlan else {
            throw CoreTestFailure(description: "expected a file operations checklist")
        }
        try expectEqual(transport.recordedRequests.count, 1, "the accepted plan ends planning")
        try expectEqual(fileOperationsPlan.operations.map(\.kind), [.rename, .rename])
        try expectEqual(fileOperationsPlan.operations.map(\.sourcePath), [scopeFolderPath + "/a.png", scopeFolderPath + "/b.png"])
        try expectEqual(fileOperationsPlan.operations.map(\.destinationPath), [scopeFolderPath + "/shot-01.png", scopeFolderPath + "/shot-02.png"])
        try expectEqual(fileOperationsPlan.operations.map(\.reason), ["#1 · created 2026-08-10", "#2 · created 2026-09-02"])
        try expectEqual(checklist.items.map(\.label), ["Rename 2 screenshots"])
        try expectEqual(fileSystemReader.metadataReadPaths,
                        [scopeFolderPath + "/a.png", scopeFolderPath + "/b.png", scopeFolderPath + "/undated.png"],
                        "only files the rule's name filters match are read")
    },
    CoreTestCase(name: "a rename rule's template problem comes back to the model before anything is read") {
        let fileSystemReader = makeScreenshotsReader()
        let renameRuleJSON = #"[{"source_folder":"/Users/tester/Shots","name_contains":null,"extensions":[],"type_identifiers":[],"order_by":"name","descending":false,"date_source":null,"name_template":"shot-{index}","group_id":"months"}]"#
        let (checklistPlanner, transport) = try makeDirectRoutePlanner(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_submit", "submit_file_operations_plan",
                #"{"task_title":"t","message_to_user":null,"groups":[{"group_id":"months","title":"Rename"}],"operations":[],"date_folder_rules":[],"rename_rules":\#(renameRuleJSON),"continues_in_next_call":false}"#)),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_plan", "submit_plan", minimalSubmitPlanInput)),
        ], fileSystemReader: fileSystemReader)
        _ = try await planDirectRoute(with: checklistPlanner)
        let ruleResult = try toolResult(ofRequest: 1, in: transport)
        try expectEqual(ruleResult.isError, true)
        try expectTrue(ruleResult.text.contains("unknown token {index}"), ruleResult.text)
        try expectEqual(fileSystemReader.metadataReadPaths, [])
    },
    CoreTestCase(name: "read_file_metadata with a folder reads its items, names them relative to it, and stops at the read cap") {
        let fileSystemReader = makeScreenshotsReader()
        let (checklistPlanner, transport) = try makeDirectRoutePlanner(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_folder", "read_file_metadata",
                #"{"folder":"/Users/tester/Shots","paths":null}"#)),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_again", "read_file_metadata",
                #"{"folder":"/Users/tester/Shots","paths":null}"#)),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_outside", "read_file_metadata",
                #"{"folder":"/Users/tester/Private","paths":null}"#)),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_plan", "submit_plan", minimalSubmitPlanInput)),
        ], fileSystemReader: fileSystemReader, safetyLimits: {
            var tightLimits = SafetyLimits.standard
            tightLimits.maximumFileMetadataReadsPerPlanning = 5
            return tightLimits
        }())
        _ = try await planDirectRoute(with: checklistPlanner)
        let folderResult = try toolResult(ofRequest: 1, in: transport)
        try expectEqual(folderResult.isError, false)
        try expectTrue(folderResult.text.contains("<untrusted_ui>\nFolder: /Users/tester/Shots\na.png | file | 10 bytes | 2026-08-10T12:00:00Z"),
                       folderResult.text)
        try expectTrue(folderResult.text.contains("\nnotes.txt | file |"), folderResult.text)
        let cappedResult = try toolResult(ofRequest: 2, in: transport)
        try expectEqual(cappedResult.isError, false)
        try expectTrue(cappedResult.text.hasPrefix("Read 2 items; 1 more were not read."), cappedResult.text)
        try expectTrue(cappedResult.text.contains("… 1 more items not read\n</untrusted_ui>"), cappedResult.text)
        try expectEqual(try toolResult(ofRequest: 3, in: transport).isError, true, "a folder outside the scope is refused")
        try expectEqual(fileSystemReader.metadataReadPaths.count, 5)
    },
    CoreTestCase(name: "an accepted script plan carries the task's scope folders for the Finder check") {
        let finderInput = #"{"task_title":"Count","target_bundle_id":"com.apple.finder","language":"applescript","source":"tell application \"Finder\" to return \"ok\"","summary":"s","expected_effects":[],"modifies_data":false,"timeout_seconds":30}"#
        let (checklistPlanner, _) = try makeDirectRoutePlanner(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_script", "submit_script_plan", finderInput)),
        ])
        guard case .checklist(let checklist) = try await planDirectRoute(with: checklistPlanner),
              case .script(let scriptPlan)? = checklist.directRoutePlan else {
            throw CoreTestFailure(description: "expected a script checklist")
        }
        try expectEqual(scriptPlan.fileScope?.roots.map(\.canonicalPath), [scopeFolderPath])
    },
    CoreTestCase(name: "the executor's item loop answers direct-route tools with an error") {
        let harness = try ItemLoopTestHarness(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_list", "list_folder",
                #"{"path":"/Users/tester/Shots","depth":1,"include_hidden":false}"#)),
            try ConversationFixtures.finishItemTurn(outcome: "failed"),
        ])
        _ = try await harness.runItem()
        let listResult = try toolResult(ofRequest: 1, in: harness.transport)
        try expectEqual(listResult.isError, true)
        try expectTrue(listResult.text.contains("only available during planning"), listResult.text)
    },
])
