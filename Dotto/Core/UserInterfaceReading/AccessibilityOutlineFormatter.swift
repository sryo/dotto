import Foundation
import CoreGraphics

enum AccessibilityOutlineFormatter {
    private static let hoistableContainerRoles: Set<String> = ["AXGroup", "AXSplitGroup", "AXScrollArea", "AXLayoutArea",
                                                               "AXLayoutItem", "AXUnknown", "AXSection"]
    private static let interactiveRoles: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea",
        "AXComboBox", "AXPopUpButton", "AXMenuButton", "AXLink", "AXSlider", "AXIncrementor", "AXMenuItem", "AXMenuBarItem",
        "AXRow", "AXCell", "AXDisclosureTriangle", "AXTab", "AXColorWell", "AXDateField"]
    private static let shortRoleNameOverrides: [String: String] = ["AXStaticText": "text", "AXPopUpButton": "popup",
        "AXRadioButton": "radio", "AXCheckBox": "checkbox", "AXMenuItem": "menuitem", "AXMenuBarItem": "menubaritem",
        "AXComboBox": "combobox", "AXTextArea": "textarea", "AXDisclosureTriangle": "disclosure", "AXWebArea": "webarea"]

    /// How many levels below a query match stay visible, so the model sees e.g. a matching row's cells.
    private static let queryMatchDescendantDepth = 2

    static func formatOutline(_ snapshot: AccessibilityTreeSnapshot, query: String?, limits: AccessibilityOutlineLimits) -> String {
        var visibleRootNodes = prunedNodes(snapshot.rootNodes)
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var querySuffix = ""
        if !trimmedQuery.isEmpty {
            let matchCount = countQueryMatches(in: visibleRootNodes, query: trimmedQuery)
            querySuffix = " query=\"\(sanitize(trimmedQuery, limits: limits))\" matches=\(matchCount)"
            if matchCount == 0 {
                return headerLine(snapshot, shownElementCount: 0, querySuffix: querySuffix, limits: limits)
                    + "\n(no elements match \"\(sanitize(trimmedQuery, limits: limits))\")"
            }
            visibleRootNodes = visibleRootNodes.compactMap {
                filterNodeForQuery($0, query: trimmedQuery, remainingContextDepth: 0)
            }
        }

        var outlineLines: [(text: String, isElementLine: Bool)] = []
        appendOutlineLines(for: visibleRootNodes, depth: 0, limits: limits, into: &outlineLines)

        let totalLength = outlineLines.reduce(0) { $0 + $1.text.count + 1 }
        // The header's shown= count is only known after truncation; rawNodeCount bounds its digit count.
        let headerLengthUpperBound = headerLine(snapshot, shownElementCount: max(snapshot.rawNodeCount, outlineLines.count),
                                                querySuffix: querySuffix, limits: limits).count
        let truncationLine = "… outline truncated at \(limits.maximumCharacterCount) characters — narrow it with a query or scope"
        var includedLines = outlineLines
        var wasTruncated = false
        if headerLengthUpperBound + totalLength > limits.maximumCharacterCount {
            wasTruncated = true
            var remainingCharacterBudget = limits.maximumCharacterCount - headerLengthUpperBound - truncationLine.count - 1
            includedLines = []
            for outlineLine in outlineLines {
                remainingCharacterBudget -= outlineLine.text.count + 1
                if remainingCharacterBudget < 0 { break }
                includedLines.append(outlineLine)
            }
        }

        let shownElementCount = includedLines.filter(\.isElementLine).count
        var outputLines = [headerLine(snapshot, shownElementCount: shownElementCount, querySuffix: querySuffix, limits: limits)]
        outputLines += includedLines.map(\.text)
        if outlineLines.isEmpty { outputLines.append("(no elements)") }
        if wasTruncated { outputLines.append(truncationLine) }
        return outputLines.joined(separator: "\n")
    }

    static func prunedNodes(_ nodes: [AccessibilityElementNode]) -> [AccessibilityElementNode] {
        nodes.flatMap { pruneNode($0, parentNode: nil) }
    }

    static func shortRoleName(role: String, subrole: String?) -> String {
        if subrole == "AXSearchField" { return "searchfield" }
        let baseRoleName = shortRoleNameOverrides[role] ?? (role.hasPrefix("AX") ? String(role.dropFirst(2)) : role).lowercased()
        return subrole == "AXSecureTextField" ? baseRoleName + "(secure)" : baseRoleName
    }

    static func nodeTextMatches(_ node: AccessibilityElementNode, query: String) -> Bool {
        [node.title, node.value, node.elementDescription, node.placeholder].contains { candidateText in
            candidateText?.range(of: query, options: .caseInsensitive) != nil
        }
    }

    // MARK: - Pruning

    private static func pruneNode(_ node: AccessibilityElementNode, parentNode: AccessibilityElementNode?) -> [AccessibilityElementNode] {
        if let frame = node.frameInTopLeftGlobalPoints, frame.width < 1 || frame.height < 1 { return [] }

        if node.role == "AXStaticText", let staticText = nonEmpty(node.value) ?? nonEmpty(node.title), let parentNode,
           staticText == parentNode.title || staticText == parentNode.elementDescription {
            return []
        }

        let prunedChildren = node.children.flatMap { pruneNode($0, parentNode: node) }
        let hasOwnText = nonEmpty(node.title) != nil || nonEmpty(node.value) != nil || nonEmpty(node.elementDescription) != nil

        if hoistableContainerRoles.contains(node.role) && !hasOwnText && !node.supportsPressAction {
            return prunedChildren
        }
        if prunedChildren.isEmpty && !isInteractive(node) && !hasOwnText && nonEmpty(node.placeholder) == nil {
            return []
        }
        var prunedNode = node
        prunedNode.children = prunedChildren
        return [prunedNode]
    }

    private static func isInteractive(_ node: AccessibilityElementNode) -> Bool {
        node.supportsPressAction || interactiveRoles.contains(node.role)
    }

    // MARK: - Query filtering

    private static func countQueryMatches(in nodes: [AccessibilityElementNode], query: String) -> Int {
        nodes.reduce(0) { runningCount, node in
            runningCount + (nodeTextMatches(node, query: query) ? 1 : 0) + countQueryMatches(in: node.children, query: query)
        }
    }

    /// remainingContextDepth > 0 means the node sits within `queryMatchDescendantDepth` levels below a match and is kept
    /// unconditionally; otherwise it is kept only if it matches or has a kept descendant.
    private static func filterNodeForQuery(_ node: AccessibilityElementNode, query: String,
                                           remainingContextDepth: Int) -> AccessibilityElementNode? {
        let nodeMatches = nodeTextMatches(node, query: query)
        let childContextDepth = nodeMatches ? queryMatchDescendantDepth : remainingContextDepth - 1
        let keptChildren = node.children.compactMap {
            filterNodeForQuery($0, query: query, remainingContextDepth: childContextDepth)
        }
        guard nodeMatches || remainingContextDepth > 0 || !keptChildren.isEmpty else { return nil }
        var filteredNode = node
        filteredNode.children = keptChildren
        return filteredNode
    }

    // MARK: - Line formatting

    private static func headerLine(_ snapshot: AccessibilityTreeSnapshot, shownElementCount: Int, querySuffix: String,
                                   limits: AccessibilityOutlineLimits) -> String {
        var header = "app=\"\(sanitize(snapshot.application.applicationName, limits: limits))\""
        if let windowTitle = nonEmpty(snapshot.windowTitle) {
            header += " window=\"\(sanitize(windowTitle, limits: limits))\""
        }
        header += " scope=\(snapshot.scope.rawValue) snapshot=\(snapshot.snapshotGeneration)"
        header += " elements=\(snapshot.rawNodeCount) shown=\(shownElementCount)" + querySuffix
        if snapshot.wasTruncatedDuringRead {
            header += " (reading stopped at the element limit; use a query or narrower scope)"
        }
        return header
    }

    private static func appendOutlineLines(for nodes: [AccessibilityElementNode], depth: Int, limits: AccessibilityOutlineLimits,
                                           into outlineLines: inout [(text: String, isElementLine: Bool)]) {
        let indentation = String(repeating: "  ", count: depth)
        for node in nodes {
            outlineLines.append((indentation + elementLine(for: node, limits: limits), true))
            let shownChildren = node.children.prefix(limits.maximumChildrenShownPerNode)
            appendOutlineLines(for: Array(shownChildren), depth: depth + 1, limits: limits, into: &outlineLines)
            let hiddenChildCount = node.children.count - shownChildren.count
            if hiddenChildCount > 0 {
                let childIndentation = String(repeating: "  ", count: depth + 1)
                outlineLines.append((childIndentation + "… \(hiddenChildCount) more children of [\(node.elementIdentifier)] hidden — call read_ui with a query to find specific ones", false))
            }
        }
    }

    private static func elementLine(for node: AccessibilityElementNode, limits: AccessibilityOutlineLimits) -> String {
        "[\(node.elementIdentifier)] " + elementDescription(for: node, limits: limits)
    }

    /// An outline line without its element id.
    static func elementDescription(for node: AccessibilityElementNode, limits: AccessibilityOutlineLimits) -> String {
        let effectiveSubrole = node.isSecureTextField ? "AXSecureTextField" : node.subrole
        var lineParts = [shortRoleName(role: node.role, subrole: effectiveSubrole)]
        let title = nonEmpty(node.title)
        if let title { lineParts.append("\"\(sanitize(title, limits: limits))\"") }

        if node.isSecureTextField {
            lineParts.append("value=<hidden>")
        } else if let value = nonEmpty(node.value), value != title {
            lineParts.append("value=\"\(sanitize(value, limits: limits))\"")
        }
        if let elementDescription = nonEmpty(node.elementDescription), elementDescription != title {
            lineParts.append("desc=\"\(sanitize(elementDescription, limits: limits))\"")
        }
        if let placeholder = nonEmpty(node.placeholder), placeholder != title {
            lineParts.append("placeholder=\"\(sanitize(placeholder, limits: limits))\"")
        }

        if !node.isEnabled { lineParts.append("disabled") }
        if node.isFocused { lineParts.append("focused") }
        if node.isSelected { lineParts.append("selected") }
        if node.supportsPressAction && !interactiveRoles.contains(node.role) { lineParts.append("clickable") }
        return lineParts.joined(separator: " ")
    }

    static func sanitize(_ rawText: String, limits: AccessibilityOutlineLimits) -> String {
        let singleLineText = rawText.components(separatedBy: .newlines).joined(separator: " ")
        let truncatedText = singleLineText.count > limits.maximumTextLength
            ? String(singleLineText.prefix(limits.maximumTextLength)) + "…"
            : singleLineText
        return truncatedText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func nonEmpty(_ optionalText: String?) -> String? {
        guard let optionalText, !optionalText.isEmpty else { return nil }
        return optionalText
    }
}
