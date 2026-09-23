import Foundation

/// Builds a checklist from a saved routine and the user's list of values, so "Run on a list" skips planning.
enum RoutineChecklistFactory {
    /// One line per item. With one parameter the whole line is the value; with more, values are split on tabs,
    /// else on " | ". Blank lines are skipped; errors name the line so the user can fix it.
    static func parseListInput(_ pastedText: String, parameterNames: [String]) -> Result<[[ChecklistItemParameter]], RoutineTemplateError> {
        guard !parameterNames.isEmpty else { return .failure(RoutineTemplateError(message: "This routine has no parameters to fill in.")) }
        var parameterSets: [[ChecklistItemParameter]] = []
        for (lineOffset, line) in pastedText.components(separatedBy: .newlines).enumerated() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let rawValues: [String]
            if parameterNames.count == 1 {
                rawValues = [line]
            } else {
                rawValues = line.contains("\t") ? line.components(separatedBy: "\t") : line.components(separatedBy: " | ")
            }
            let values = rawValues.map { $0.trimmingCharacters(in: .whitespaces) }
            guard values.count == parameterNames.count else {
                return .failure(RoutineTemplateError(message: "Line \(lineOffset + 1) has \(values.count) values; expected \(parameterNames.count) (\(parameterNames.joined(separator: ", ")))."))
            }
            if let offendingValue = values.first(where: containsDisallowedCharacter) {
                return .failure(RoutineTemplateError(
                    message: "Line \(lineOffset + 1) contains a control character in “\(displayableEntry(offendingValue))”. Remove it and try again."))
            }
            parameterSets.append(zip(parameterNames, values).map { ChecklistItemParameter(name: $0, value: $1) })
        }
        if parameterSets.isEmpty { return .failure(RoutineTemplateError(message: "Paste at least one line.")) }
        if parameterSets.count > Checklist.maximumItemCount {
            return .failure(RoutineTemplateError(message: "The list has \(parameterSets.count) items; the most Dotto runs at once is \(Checklist.maximumItemCount)."))
        }
        return .success(parameterSets)
    }

    /// Sorted by path. A parameter whose name mentions "path" gets the full path, one that mentions "name" gets the
    /// file name, and any other gets the full path. Fails, naming the file, when a path holds a newline or another
    /// control character: a file name is attacker-controllable text that ends up in a prompt.
    static func validatedParameterSets(forFileURLs fileURLs: [URL], parameterNames: [String])
        -> Result<[[ChecklistItemParameter]], RoutineTemplateError> {
        let sortedFileURLs = fileURLs.sorted { $0.path < $1.path }
        if let offendingFileURL = sortedFileURLs.first(where: { containsDisallowedCharacter($0.path) }) {
            return .failure(RoutineTemplateError(
                message: "The file “\(displayableEntry(offendingFileURL.lastPathComponent))” has a newline or control character in its name. Rename or remove it and try again."))
        }
        return .success(sortedFileURLs.map { fileURL in
            parameterNames.map { parameterName in
                let lowercasedName = parameterName.lowercased()
                let usesFileName = lowercasedName.contains("name") && !lowercasedName.contains("path")
                return ChecklistItemParameter(name: parameterName, value: usesFileName ? fileURL.lastPathComponent : fileURL.path)
            }
        })
    }

    static func makeChecklist(routine: Routine, parameterSets: [[ChecklistItemParameter]],
                              targetApplication: TargetApplicationReference, taskIdentifier: String, now: Date) -> Checklist {
        var routineStepRiskCategories: [SafetyRiskCategory] = []
        for step in routine.steps where step.requiresConfirmationEachItem {
            let stepRiskCategory = step.confirmationRiskCategory ?? .irreversibleItem
            if !routineStepRiskCategories.contains(stepRiskCategory) { routineStepRiskCategories.append(stepRiskCategory) }
        }
        let checklistItems = parameterSets.prefix(Checklist.maximumItemCount).enumerated().map { itemOffset, parameters in
            let fallbackText = "Item \(itemOffset + 1)"
            var checklistItem = ChecklistItem(itemIdentifier: "item-\(itemOffset + 1)",
                                              label: (try? RoutineTemplating.render(routine.itemLabelTemplate, parameters: parameters)) ?? fallbackText,
                                              actionSummary: (try? RoutineTemplating.render(routine.itemActionSummaryTemplate, parameters: parameters)) ?? fallbackText,
                                              parameters: parameters, isIrreversible: !routineStepRiskCategories.isEmpty)
            checklistItem.confirmationRiskCategoriesFromRoutine = routineStepRiskCategories
            return checklistItem
        }
        var checklist = Checklist(taskIdentifier: taskIdentifier, originalCommand: routine.originalCommand, title: routine.name,
                                  targetApplication: targetApplication, items: checklistItems, createdAt: now)
        checklist.sourceRoutineIdentifier = routine.routineIdentifier
        return checklist
    }

    // Newlines would let a value fake extra prompt lines; bidirectional overrides make a name display differently
    // from what it is.
    private static let bidirectionalControlScalars: ClosedRange<UInt32> = 0x202A...0x202E
    private static let bidirectionalIsolateScalars: ClosedRange<UInt32> = 0x2066...0x2069

    static func containsDisallowedCharacter(_ parameterValue: String) -> Bool {
        parameterValue.unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .control
                || CharacterSet.newlines.contains(scalar)
                || bidirectionalControlScalars.contains(scalar.value)
                || bidirectionalIsolateScalars.contains(scalar.value)
        }
    }

    /// The entry with each disallowed character shown as its code point, so the user can spot it.
    private static func displayableEntry(_ entry: String) -> String {
        let visibleEntry = entry.unicodeScalars.map { scalar -> String in
            containsDisallowedCharacter(String(scalar)) ? String(format: "\\u{%04X}", scalar.value) : String(scalar)
        }.joined()
        return visibleEntry.count > 120 ? String(visibleEntry.prefix(120)) + "…" : visibleEntry
    }
}
