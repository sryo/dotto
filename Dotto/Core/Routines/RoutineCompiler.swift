import Foundation

/// Turns one verified item run into a parameterized Routine. Locators always come from recorded AX data; a model
/// only ever chooses which recorded events to keep and how to templatize them (ADR-14).
enum RoutineCompiler {
    /// Maps click / type_text / press_key and wait_for to steps and drops scrolls. nil if a step used click_point,
    /// targeted a secure field, clicked without a recorded target or picked a list row by literal text only, or if
    /// ADR-18 isn't met.
    static func compileFromAgentRun(recordedSteps: [RecordedAgentStep], completionEvidence: StepExpectation?,
                                    checklist: Checklist, item: ChecklistItem, modelCallsUsed: Int,
                                    routineIdentifier: String, now: Date) -> Routine? {
        guard let compiledSteps = compileAgentSteps(recordedSteps, parameters: item.parameters,
                                                    targetApplicationBundleIdentifier: checklist.targetApplication.bundleIdentifier),
              meetsParameterRequirement(compiledSteps, parameters: item.parameters) else { return nil }
        return makeRoutine(checklist: checklist, item: item, routineIdentifier: routineIdentifier, name: checklist.title,
                           itemLabelTemplate: RoutineTemplating.templatize(item.label, parameters: item.parameters),
                           steps: compiledSteps, completionEvidence: templatized(completionEvidence, item.parameters),
                           source: .agentRun, modelCallsUsedWhenLearned: modelCallsUsed, now: now)
    }

    /// Error messages go back to the model, which can resubmit.
    static func compileFromDemonstration(recording: DemonstrationRecording, draft: SubmittedRoutineDraft,
                                         checklist: Checklist, item: ChecklistItem, routineIdentifier: String,
                                         now: Date) -> Result<Routine, RoutineTemplateError> {
        func failure(_ message: String) -> Result<Routine, RoutineTemplateError> { .failure(RoutineTemplateError(message: message)) }
        guard !draft.steps.isEmpty else { return failure("steps is empty. Include the recorded events needed to do the item.") }
        let draftTemplates = [draft.itemLabelTemplate, draft.completionEvidence?.text]
            + draft.steps.flatMap { [$0.textTemplate, $0.targetTextTemplate, $0.expectation?.text] }
        let unknownNames = draftTemplates.compactMap { $0 }.flatMap(RoutineTemplating.placeholderNames)
            .filter { name in !item.parameters.contains { $0.name == name } }
        if let unknownName = unknownNames.first {
            return failure("{{\(unknownName)}} is not a parameter of this item. Use only: \(item.parameters.map(\.name).joined(separator: ", ")).")
        }

        var usedEventIndices = Set<Int>()
        var compiledSteps: [RoutineStep] = []
        for draftStep in draft.steps {
            let eventIndex = draftStep.eventIndex
            guard recording.events.indices.contains(eventIndex) else {
                return failure("event_index \(eventIndex) is out of range; the recording has events 0–\(recording.events.count - 1).")
            }
            guard usedEventIndices.insert(eventIndex).inserted else { return failure("event_index \(eventIndex) is used twice.") }
            let (stepAction, literalAction, targetContext) = routineAction(for: recording.events[eventIndex], draftStep: draftStep, item: item)
            if targetContext?.element.isSecureTextField == true {
                return failure("Event \(eventIndex) is in a password field; routines can't include it.")
            }
            if let targetContext, let mismatch = targetTextTemplateMismatch(draftStep.targetTextTemplate, targetContext, item) {
                return failure("target_text_template for event \(eventIndex) \(mismatch)")
            }
            if case .textEntered(_, let finalValue) = recording.events[eventIndex],
               let mismatch = typedTextTemplateMismatch(stepAction, recordedFinalValue: finalValue, item) {
                return failure("text_template for event \(eventIndex) \(mismatch)")
            }
            // The model's description is never used: the review shows what the step really does.
            var compiledStep = makeStep(stepAction, literalAction: literalAction, targetContext: targetContext,
                                        targetTextTemplateOverride: draftStep.targetTextTemplate,
                                        expectation: draftStep.expectation, parameters: item.parameters,
                                        wasConfirmedByUser: false, confirmedRiskCategory: nil,
                                        targetApplicationBundleIdentifier: checklist.targetApplication.bundleIdentifier)
            if let targetLocator = compiledStep.targetLocator, ElementLocatorBuilding.identifiesListElementWithoutParameter(targetLocator) {
                return failure("Event \(eventIndex) picks a row in a list, but nothing identifies that row by this item's parameter values, "
                               + "so replay would pick the same row for every item. Set target_text_template to the row's text with "
                               + "{{parameter}} placeholders, or leave the event out.")
            }
            // A shortcut with ⌘⇧ can send (Mail's ⌘⇧D) or do something else Dotto can't tell apart, so a taught
            // routine asks before it on every item.
            if case .pressKey(_, let modifiers) = stepAction, modifiers.contains(.command), modifiers.contains(.shift),
               !compiledStep.requiresConfirmationEachItem {
                compiledStep.requiresConfirmationEachItem = true
                compiledStep.confirmationRiskCategory = .unrecognizedShortcut
            }
            compiledSteps.append(compiledStep)
        }
        guard meetsParameterRequirement(compiledSteps, parameters: item.parameters) else {
            return failure("No step varies per item. Write parameter values as {{name}} in text_template or target_text_template.")
        }
        let trimmedName = draft.routineName.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(makeRoutine(checklist: checklist, item: item, routineIdentifier: routineIdentifier,
                                    name: trimmedName.isEmpty ? checklist.title : trimmedName,
                                    itemLabelTemplate: draft.itemLabelTemplate, steps: compiledSteps,
                                    completionEvidence: draft.completionEvidence, source: .userDemonstration,
                                    modelCallsUsedWhenLearned: nil, now: now))
    }

    /// ADR-16: keeps the steps before the failed one and appends the agent's steps from that UI state onwards.
    static func patch(_ routine: Routine, replacingStepsFrom failedStepIndex: Int,
                      withAgentSteps recordedSteps: [RecordedAgentStep], item: ChecklistItem, now: Date) -> Routine? {
        guard (0...routine.steps.count).contains(failedStepIndex),
              let agentSteps = compileAgentSteps(recordedSteps, parameters: item.parameters,
                                                 targetApplicationBundleIdentifier: routine.targetApplicationBundleIdentifier),
              !agentSteps.isEmpty else { return nil }
        var patchedRoutine = routine
        patchedRoutine.steps = Array(routine.steps.prefix(failedStepIndex)) + agentSteps
        guard meetsParameterRequirement(patchedRoutine.steps, parameters: item.parameters) else { return nil }
        patchedRoutine.patchCount += 1
        patchedRoutine.updatedAt = now
        return patchedRoutine
    }

    // MARK: - Steps

    private static func compileAgentSteps(_ recordedSteps: [RecordedAgentStep], parameters: [ChecklistItemParameter],
                                          targetApplicationBundleIdentifier: String?) -> [RoutineStep]? {
        var compiledSteps: [RoutineStep] = []
        for recordedStep in recordedSteps {
            if recordedStep.targetContext?.element.isSecureTextField == true { return nil }
            let stepAction: RoutineStepAction
            var literalAction: AgentAction?
            switch recordedStep.toolCall {
            case .action(let action):
                literalAction = action
                switch action {
                case .clickElement(_, let clickType):
                    guard recordedStep.targetContext != nil else { return nil }
                    stepAction = .click(clickType: clickType)
                case .typeText(_, let text, let replaceExistingText, let pressReturnAfter):
                    stepAction = .typeText(textTemplate: RoutineTemplating.templatize(text, parameters: parameters),
                                           replaceExistingText: replaceExistingText, pressReturnAfter: pressReturnAfter)
                case .pressKey(let keyName, let modifiers):
                    stepAction = .pressKey(keyName: keyName, modifiers: modifiers)
                case .clickScreenshotPoint:
                    return nil
                case .scroll:
                    continue
                case .uploadFiles(_, let filePaths):
                    guard recordedStep.targetContext != nil else { return nil }
                    stepAction = .uploadFiles(filePathTemplates: filePaths.map { RoutineTemplating.templatize($0, parameters: parameters) })
                }
            case .waitFor(let text, let timeoutSeconds):
                stepAction = .waitForText(textTemplate: RoutineTemplating.templatize(text, parameters: parameters), timeoutSeconds: timeoutSeconds)
            case .readUserInterface, .screenshot, .finishItem, .submitPlan, .askUser, .readDirectRouteData, .submitDirectRoutePlan:
                continue
            }
            let compiledStep = makeStep(stepAction, literalAction: literalAction, targetContext: recordedStep.targetContext,
                                        targetTextTemplateOverride: nil,
                                        expectation: templatized(recordedStep.expectation, parameters), parameters: parameters,
                                        wasConfirmedByUser: recordedStep.wasConfirmedByUser,
                                        confirmedRiskCategory: recordedStep.confirmedRiskCategory,
                                        targetApplicationBundleIdentifier: targetApplicationBundleIdentifier)
            if let targetLocator = compiledStep.targetLocator, ElementLocatorBuilding.identifiesListElementWithoutParameter(targetLocator) {
                return nil
            }
            compiledSteps.append(compiledStep)
        }
        return compiledSteps
    }

    private static func routineAction(for event: DemonstrationEvent, draftStep: SubmittedRoutineDraftStep, item: ChecklistItem)
        -> (RoutineStepAction, AgentAction, RecordedElementContext?) {
        switch event {
        case .click(let target, let clickType):
            return (.click(clickType: clickType), .clickElement(elementIdentifier: target.element.elementIdentifier, clickType: clickType), target)
        case .keyChord(let keyName, let modifiers):
            return (.pressKey(keyName: keyName, modifiers: modifiers), .pressKey(keyName: keyName, modifiers: modifiers), nil)
        case .textEntered(let target, let finalValue):
            let textTemplate = draftStep.textTemplate ?? RoutineTemplating.templatize(finalValue, parameters: item.parameters)
            return (.typeText(textTemplate: textTemplate, replaceExistingText: true, pressReturnAfter: false),
                    .typeText(elementIdentifier: target.element.elementIdentifier, text: finalValue, replaceExistingText: true,
                              pressReturnAfter: false), target)
        }
    }

    private static func makeStep(_ stepAction: RoutineStepAction, literalAction: AgentAction?, targetContext: RecordedElementContext?,
                                 targetTextTemplateOverride: String?, expectation: StepExpectation?,
                                 parameters: [ChecklistItemParameter], wasConfirmedByUser: Bool,
                                 confirmedRiskCategory: SafetyRiskCategory?, targetApplicationBundleIdentifier: String?) -> RoutineStep {
        let targetLocator = targetContext.map {
            ElementLocatorBuilding.makeLocator(from: $0, parameters: parameters, targetTextTemplateOverride: targetTextTemplateOverride)
        }
        // The recorded nodes are childless, so the descendant text is re-attached as a child: otherwise a button
        // titled by a child text would count as unlabeled and ask on every item.
        var safetyTargetNode = targetContext?.element
        if let descendantText = targetContext?.descendantText {
            safetyTargetNode?.children = [AccessibilityElementNode(
                elementIdentifier: "descendant", role: "AXStaticText", value: descendantText, isEnabled: true, isFocused: false,
                isSelected: false, isSecureTextField: false, supportsPressAction: false, children: [])]
        }
        var confirmationRiskCategory: SafetyRiskCategory? = wasConfirmedByUser ? (confirmedRiskCategory ?? .irreversibleItem) : nil
        if let literalAction, case .requireUserConfirmation(_, let riskCategory) = SafetyGate.evaluateAction(
            literalAction, targetNode: safetyTargetNode, riskCategoryConfirmedForThisItem: nil,
            targetApplicationBundleIdentifier: targetApplicationBundleIdentifier) {
            confirmationRiskCategory = riskCategory
        }
        return RoutineStep(stepDescription: describe(stepAction, targetLocator: targetLocator), action: stepAction,
                           targetLocator: targetLocator, expectation: expectation,
                           requiresConfirmationEachItem: confirmationRiskCategory != nil,
                           confirmationRiskCategory: confirmationRiskCategory)
    }

    /// Why the override can't stand in for the recorded text, or nil when it can. Rendered with this item's values
    /// it must reproduce the recorded text, so a model can templatize a target but never retarget it.
    private static func targetTextTemplateMismatch(_ targetTextTemplate: String?, _ targetContext: RecordedElementContext,
                                                   _ item: ChecklistItem) -> String? {
        guard let targetTextTemplate else { return nil }
        let recordedText = targetContext.element.title ?? targetContext.descendantText ?? targetContext.element.value ?? ""
        let renderedText = (try? RoutineTemplating.render(targetTextTemplate, parameters: item.parameters)) ?? ""
        let normalized = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return normalized(renderedText) == normalized(recordedText)
            ? nil : "must reproduce the element's text “\(recordedText.prefix(100))” when filled with this item's values."
    }

    /// Why the typed-text template can't stand in for what the user typed, or nil when it can. Filled with this
    /// item's values it must give back exactly the recorded final value, so the model can't change what is typed.
    private static func typedTextTemplateMismatch(_ stepAction: RoutineStepAction, recordedFinalValue: String,
                                                  _ item: ChecklistItem) -> String? {
        guard case .typeText(let textTemplate, _, _) = stepAction else { return nil }
        let renderedText = (try? RoutineTemplating.render(textTemplate, parameters: item.parameters)) ?? ""
        return renderedText == recordedFinalValue
            ? nil : "must reproduce the typed text “\(recordedFinalValue.prefix(100))” exactly when filled with this item's values."
    }

    /// ADR-18: unless an action or locator varies per item, replay would repeat item 1's actions verbatim.
    private static func meetsParameterRequirement(_ steps: [RoutineStep], parameters: [ChecklistItemParameter]) -> Bool {
        !parameters.isEmpty && steps.contains { step in
            var stepTemplates: [String?] = step.targetLocator.map { locator in
                [locator.titleTemplate, locator.descriptionTemplate, locator.valueTemplate, locator.descendantTextTemplate]
                    + locator.ancestorsNearestFirst.map(\.titleTemplate)
            } ?? []
            if case .typeText(let textTemplate, _, _) = step.action { stepTemplates.append(textTemplate) }
            if case .waitForText(let textTemplate, _) = step.action { stepTemplates.append(textTemplate) }
            if case .uploadFiles(let filePathTemplates) = step.action { stepTemplates += filePathTemplates }
            return stepTemplates.contains(where: RoutineTemplating.containsPlaceholder)
        }
    }

    private static func describe(_ stepAction: RoutineStepAction, targetLocator: ElementLocator?) -> String {
        let targetName = targetLocator.map { locator in
            let roleName = AccessibilityOutlineFormatter.shortRoleName(role: locator.role, subrole: locator.subrole)
            let identifyingText = locator.titleTemplate ?? locator.descriptionTemplate ?? locator.descendantTextTemplate ?? locator.valueTemplate
            return identifyingText.map { "\(roleName) “\($0)”" } ?? roleName
        }
        switch stepAction {
        case .click: return "Click \(targetName ?? "element")"
        case .typeText(let textTemplate, _, _): return "Type “\(textTemplate)”" + (targetName.map { " into \($0)" } ?? "")
        case .pressKey(let keyName, let modifiers): return "Press " + (modifiers.map(\.rawValue) + [keyName]).joined(separator: "+")
        case .waitForText(let textTemplate, _): return "Wait for “\(textTemplate)”"
        case .uploadFiles(let filePathTemplates):
            return "Upload \(AgentActionDescriptions.fileCountText(filePathTemplates.count))" + (targetName.map { " with \($0)" } ?? "")
        }
    }

    private static func templatized(_ expectation: StepExpectation?, _ parameters: [ChecklistItemParameter]) -> StepExpectation? {
        expectation.map { StepExpectation(kind: $0.kind, text: RoutineTemplating.templatize($0.text, parameters: parameters)) }
    }

    private static func makeRoutine(checklist: Checklist, item: ChecklistItem, routineIdentifier: String, name: String,
                                    itemLabelTemplate: String, steps: [RoutineStep], completionEvidence: StepExpectation?,
                                    source: RoutineSource, modelCallsUsedWhenLearned: Int?, now: Date) -> Routine {
        Routine(formatVersion: Routine.currentFormatVersion, routineIdentifier: routineIdentifier, name: name,
                originalCommand: checklist.originalCommand, targetApplicationName: checklist.targetApplication.applicationName,
                targetApplicationBundleIdentifier: checklist.targetApplication.bundleIdentifier,
                parameterNames: item.parameters.map(\.name), itemLabelTemplate: itemLabelTemplate,
                itemActionSummaryTemplate: RoutineTemplating.templatize(item.actionSummary, parameters: item.parameters),
                steps: steps, completionEvidence: completionEvidence, source: source,
                modelCallsUsedWhenLearned: modelCallsUsedWhenLearned, createdAt: now, updatedAt: now, patchCount: 0)
    }
}
