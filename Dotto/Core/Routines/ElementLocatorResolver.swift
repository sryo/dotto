import Foundation
import CoreGraphics

extension AccessibilityTreeSnapshot {
    func recordedElementContext(forNodeWithIdentifier elementIdentifier: String) -> RecordedElementContext? {
        guard let (node, ancestorsNearestFirst) = ElementLocatorResolver.nodesWithAncestors(in: rootNodes)
            .first(where: { $0.node.elementIdentifier == elementIdentifier }) else { return nil }
        func childless(_ node: AccessibilityElementNode) -> AccessibilityElementNode {
            var strippedNode = node
            strippedNode.children = []
            if strippedNode.isSecureTextField { strippedNode.value = nil }
            return strippedNode
        }
        return RecordedElementContext(element: childless(node), ancestorsNearestFirst: ancestorsNearestFirst.map(childless),
                                      descendantText: RecordedElementContext.descendantText(below: node),
                                      windowFrameInTopLeftGlobalPoints: ElementLocatorResolver.windowFrame(ancestorsNearestFirst),
                                      readScope: scope)
    }
}

enum ElementLocatorBuilding {
    private static let maximumLocatorAncestorCount = 4
    static let listRowRoles: Set<String> = ["AXRow", "AXCell", "AXOutlineRow"]
    static let listContainerRoles: Set<String> = ["AXTable", "AXOutline", "AXList", "AXBrowser", "AXGrid"]
    private static let textEntryRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// `targetTextTemplateOverride` (from a demonstration draft) is used only when templatizing found no parameter:
    /// it replaces the title if there is one, else the descendant text, else the value.
    static func makeLocator(from recordedContext: RecordedElementContext, parameters: [ChecklistItemParameter],
                            targetTextTemplateOverride: String?) -> ElementLocator {
        let element = recordedContext.element
        let ancestorRoles = recordedContext.ancestorsNearestFirst.map(\.role)
        // A list row's or text field's text is item data, so a parameter value may be one word of it. Anywhere
        // else (a button, a menu item) only a whole-text match is item data: "New" in "New Folder" is a fixed label.
        let allowsWholeTokenMatches = isListElement(role: element.role, subrole: element.subrole, ancestorRoles: ancestorRoles)
            || textEntryRoles.contains(element.role) || element.subrole == "AXSearchField"
        func templatized(_ literalText: String?) -> String? {
            literalText.map { RoutineTemplating.templatizeLocatorText($0, parameters: parameters, allowsWholeTokenMatches: allowsWholeTokenMatches) }
        }
        let templatizedValue = templatized(element.value)
        var locator = ElementLocator(
            role: element.role, subrole: element.subrole, titleTemplate: templatized(element.title),
            descriptionTemplate: templatized(element.elementDescription),
            valueTemplate: templatizedValue != element.value ? templatizedValue : nil,
            descendantTextTemplate: templatized(recordedContext.descendantText), placeholder: element.placeholder,
            accessibilityIdentifier: element.accessibilityIdentifier,
            ancestorsNearestFirst: recordedContext.ancestorsNearestFirst.filter { $0.role != "AXWindow" }
                .prefix(maximumLocatorAncestorCount).map { LocatorAncestor(role: $0.role, titleTemplate: templatized($0.title)) },
            normalizedPositionInWindow: ElementLocatorResolver.normalizedCenter(of: element.frameInTopLeftGlobalPoints,
                                                                                in: recordedContext.windowFrameInTopLeftGlobalPoints),
            readScope: readScope(forElementRole: element.role, ancestorRoles: ancestorRoles, recordedScope: recordedContext.readScope))
        let templatizingFoundParameter = [locator.titleTemplate, locator.descriptionTemplate, locator.valueTemplate,
                                          locator.descendantTextTemplate].contains(where: RoutineTemplating.containsPlaceholder)
        if let targetTextTemplateOverride, !templatizingFoundParameter {
            if locator.titleTemplate != nil {
                locator.titleTemplate = targetTextTemplateOverride
            } else if locator.descendantTextTemplate != nil {
                locator.descendantTextTemplate = targetTextTemplateOverride
            } else {
                locator.valueTemplate = targetTextTemplateOverride
            }
        }
        return locator
    }

    /// Menu bar items live in the menu bar; a menu item does only when its menu hangs off the menu bar. A context
    /// or pop-up menu item is read where it was recorded.
    private static func readScope(forElementRole elementRole: String, ancestorRoles: [String],
                                  recordedScope: ReadUserInterfaceScope) -> ReadUserInterfaceScope {
        if elementRole == "AXMenuBarItem" { return .menuBar }
        if elementRole == "AXMenuItem", ancestorRoles.contains(where: { $0 == "AXMenuBar" || $0 == "AXMenuBarItem" }) { return .menuBar }
        return recordedScope
    }

    static func isListElement(role: String, subrole: String?, ancestorRoles: [String]) -> Bool {
        listRowRoles.contains(role) || subrole.map(listRowRoles.contains) == true || ancestorRoles.contains(where: listContainerRoles.contains)
    }

    /// A row or cell (or anything inside a table, outline or list) found only by literal text is whichever row
    /// item 1 happened to use, e.g. the first message's sender. Replaying it would act on that row for every item.
    static func identifiesListElementWithoutParameter(_ locator: ElementLocator) -> Bool {
        guard isListElement(role: locator.role, subrole: locator.subrole, ancestorRoles: locator.ancestorsNearestFirst.map(\.role)) else {
            return false
        }
        let locatorTemplates = [locator.titleTemplate, locator.descriptionTemplate, locator.valueTemplate, locator.descendantTextTemplate]
            + locator.ancestorsNearestFirst.map(\.titleTemplate)
        return !locatorTemplates.contains(where: RoutineTemplating.containsPlaceholder)
    }
}

enum ElementLocatorResolution: Equatable, Sendable {
    case resolved(AccessibilityElementNode, score: Int)
    case ambiguous(candidateCount: Int, bestScore: Int)
    case notFound
    case listElementWithoutParameter

    var failureReasonForModel: String? {
        switch self {
        case .resolved: return nil
        case .ambiguous(let candidateCount, _):
            return "The recorded element matched \(candidateCount) elements equally well, so replay couldn't tell which one to use."
        case .notFound: return "The recorded element isn't in the current UI."
        case .listElementWithoutParameter:
            return "The recorded element is a row in a list that isn't identified by this item's values, so replay can't tell which row this item needs."
        }
    }
}

enum ElementLocatorResolver {
    static let minimumAcceptedScore = 25
    static let minimumLeadOverRunnerUp = 8
    private static let maximumScoredAncestorLevels = 4

    /// Throws RoutineTemplateError when a template names an unknown parameter.
    static func resolve(_ locator: ElementLocator, parameters: [ChecklistItemParameter],
                        in snapshot: AccessibilityTreeSnapshot) throws -> ElementLocatorResolution {
        if ElementLocatorBuilding.identifiesListElementWithoutParameter(locator) { return .listElementWithoutParameter }
        func rendered(_ template: String?) throws -> String? {
            try template.map { try RoutineTemplating.render($0, parameters: parameters) }
        }
        let expectedTitle = try rendered(locator.titleTemplate)
        let expectedDescription = try rendered(locator.descriptionTemplate)
        let expectedValue = try rendered(locator.valueTemplate)
        let expectedDescendantText = try rendered(locator.descendantTextTemplate)
        let expectedAncestorTitles = try locator.ancestorsNearestFirst.map { try rendered($0.titleTemplate) }

        // Candidates stay in document order, so equal scores keep a stable order; ties are still reported as
        // ambiguous rather than broken by that order.
        var candidateScores: [(node: AccessibilityElementNode, score: Int)] = []
        for (candidate, allAncestorsNearestFirst) in nodesWithAncestors(in: snapshot.rootNodes) where candidate.role == locator.role {
            let candidateAncestors = allAncestorsNearestFirst.filter { $0.role != "AXWindow" }
            let candidateDescendantText = RecordedElementContext.descendantText(below: candidate)

            // ADR-15: a templated field names this item's element, so any other element is excluded outright.
            var hardConstraints = [(locator.titleTemplate, expectedTitle, candidate.title),
                                   (locator.descriptionTemplate, expectedDescription, candidate.elementDescription),
                                   (locator.valueTemplate, expectedValue, candidate.value),
                                   (locator.descendantTextTemplate, expectedDescendantText, candidateDescendantText)]
            for (ancestorLevel, ancestor) in locator.ancestorsNearestFirst.enumerated() {
                hardConstraints.append((ancestor.titleTemplate, expectedAncestorTitles[ancestorLevel],
                                        candidateAncestors.indices.contains(ancestorLevel) ? candidateAncestors[ancestorLevel].title : nil))
            }
            let violatesHardConstraint = hardConstraints.contains { template, expectedText, candidateText in
                RoutineTemplating.containsPlaceholder(template) && !textsMatch(expectedText, candidateText)
            }
            if violatesHardConstraint { continue }

            var score = candidate.subrole == locator.subrole ? 3 : -5
            if let identifier = nonEmpty(locator.accessibilityIdentifier), let candidateIdentifier = nonEmpty(candidate.accessibilityIdentifier) {
                score += identifier == candidateIdentifier ? 40 : -20
            }
            if let expectedTitle = nonEmpty(expectedTitle) {
                if textsMatch(expectedTitle, candidate.title) {
                    score += 30
                } else if expectedTitle.count >= 3, candidate.title?.range(of: expectedTitle, options: .caseInsensitive) != nil {
                    score += 10
                } else {
                    score -= 20
                }
            }
            if let expectedDescription = nonEmpty(expectedDescription) {
                score += textsMatch(expectedDescription, candidate.elementDescription) ? 20 : -10
            }
            if let expectedValue = nonEmpty(expectedValue), textsMatch(expectedValue, candidate.value) { score += 30 }
            if let expectedDescendantText = nonEmpty(expectedDescendantText) {
                score += textsMatch(expectedDescendantText, candidateDescendantText) ? 25 : -15
            }
            if let placeholder = nonEmpty(locator.placeholder), textsMatch(placeholder, candidate.placeholder) { score += 10 }
            for ancestorLevel in 0..<min(maximumScoredAncestorLevels, locator.ancestorsNearestFirst.count, candidateAncestors.count) {
                if locator.ancestorsNearestFirst[ancestorLevel].role == candidateAncestors[ancestorLevel].role { score += 3 }
                if let expectedAncestorTitle = nonEmpty(expectedAncestorTitles[ancestorLevel]),
                   textsMatch(expectedAncestorTitle, candidateAncestors[ancestorLevel].title) { score += 4 }
            }
            if let recordedPosition = locator.normalizedPositionInWindow,
               let candidatePosition = normalizedCenter(of: candidate.frameInTopLeftGlobalPoints, in: windowFrame(allAncestorsNearestFirst)) {
                let distance = hypot(recordedPosition.x - candidatePosition.x, recordedPosition.y - candidatePosition.y)
                score += max(0, 12 - Int(distance * 40))
            }
            if !candidate.isEnabled { score -= 5 }
            candidateScores.append((candidate, score))
        }

        let rankedCandidates = candidateScores.enumerated()
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map(\.element)
        guard let bestCandidate = rankedCandidates.first, bestCandidate.score >= minimumAcceptedScore else { return .notFound }
        let runnerUpScore = rankedCandidates.dropFirst().first?.score ?? Int.min
        if runnerUpScore != Int.min, bestCandidate.score - runnerUpScore < minimumLeadOverRunnerUp {
            let tiedCandidateCount = rankedCandidates.filter { bestCandidate.score - $0.score < minimumLeadOverRunnerUp }.count
            return .ambiguous(candidateCount: tiedCandidateCount, bestScore: bestCandidate.score)
        }
        return .resolved(bestCandidate.node, score: bestCandidate.score)
    }

    /// Every node in document order, each with its ancestors nearest first.
    static func nodesWithAncestors(in rootNodes: [AccessibilityElementNode])
        -> [(node: AccessibilityElementNode, ancestorsNearestFirst: [AccessibilityElementNode])] {
        var collectedNodes: [(node: AccessibilityElementNode, ancestorsNearestFirst: [AccessibilityElementNode])] = []
        func collect(_ nodes: [AccessibilityElementNode], ancestorsNearestFirst: [AccessibilityElementNode]) {
            for node in nodes {
                collectedNodes.append((node, ancestorsNearestFirst))
                collect(node.children, ancestorsNearestFirst: [node] + ancestorsNearestFirst)
            }
        }
        collect(rootNodes, ancestorsNearestFirst: [])
        return collectedNodes
    }

    /// The nearest AXWindow ancestor's frame, else the outermost ancestor's (a menu bar, for menu items).
    static func windowFrame(_ ancestorsNearestFirst: [AccessibilityElementNode]) -> CGRect? {
        (ancestorsNearestFirst.first { $0.role == "AXWindow" } ?? ancestorsNearestFirst.last)?.frameInTopLeftGlobalPoints
    }

    static func normalizedCenter(of elementFrame: CGRect?, in windowFrame: CGRect?) -> CGPoint? {
        guard let elementFrame, let windowFrame, windowFrame.width > 0, windowFrame.height > 0 else { return nil }
        return CGPoint(x: (elementFrame.midX - windowFrame.minX) / windowFrame.width,
                       y: (elementFrame.midY - windowFrame.minY) / windowFrame.height)
    }

    private static func textsMatch(_ expectedText: String?, _ candidateText: String?) -> Bool {
        guard let expectedText, let candidateText else { return false }
        return expectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(candidateText.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedText.isEmpty else { return nil }
        return trimmedText
    }
}
