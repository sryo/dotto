import AppKit
import ApplicationServices

/// Teach mode: what the demonstration recorder reads about the element the user clicked or typed into.
extension AccessibilityElementReader {
    /// Also returns the live element so the recorder can read a clicked text field's value before the user types.
    func elementWithRecordedContext(atTopLeftGlobalPoint topLeftGlobalPoint: CGPoint, in application: TargetApplicationReference)
        -> (accessibilityElement: AXUIElement, recordedContext: RecordedElementContext)? {
        let applicationElement = Self.makeApplicationElement(for: application.processIdentifier)
        guard let elementAtPoint = Self.element(atTopLeftGlobalPoint: topLeftGlobalPoint, in: applicationElement),
              Self.processIdentifier(of: elementAtPoint) == application.processIdentifier,
              let recordedContext = recordedElementContext(of: elementAtPoint, in: application) else { return nil }
        return (elementAtPoint, recordedContext)
    }

    /// The process that owns the topmost accessible element at a point, or nil when the hit test fails.
    func processIdentifierOfElement(atTopLeftGlobalPoint topLeftGlobalPoint: CGPoint) -> pid_t? {
        Self.element(atTopLeftGlobalPoint: topLeftGlobalPoint, in: systemWideElement).flatMap(Self.processIdentifier(of:))
    }

    /// Builds the chain window › … › parent › target (target keeps two child levels) as a one-branch snapshot and lets
    /// the Core walk describe it, so a recorded element is described exactly like a replayed snapshot's node.
    func recordedElementContext(of targetElement: AXUIElement, in application: TargetApplicationReference) -> RecordedElementContext? {
        var nextRecordedElementNumber = 1
        var recordingWalkProgress = TreeWalkProgress()
        func node(of accessibilityElement: AXUIElement, keptChildLevels: Int) -> AccessibilityElementNode? {
            buildNode(from: accessibilityElement, depth: recordingWalkProgress.budget.maximumDepth - keptChildLevels,
                      isInsideWebContent: false, nextElementNumber: &nextRecordedElementNumber,
                      treeWalkProgress: &recordingWalkProgress, shouldAbortWalk: { false })
        }
        guard var chainRootNode = node(of: targetElement, keptChildLevels: 2) else { return nil }
        let targetNode = chainRootNode
        var currentElement = targetElement
        for _ in 0..<Self.maximumRecordedAncestorCount where chainRootNode.role != kAXWindowRole {
            guard let parentElement = Self.elementAttribute(kAXParentAttribute, of: currentElement),
                  var parentNode = node(of: parentElement, keptChildLevels: 0), parentNode.role != kAXApplicationRole else { break }
            parentNode.children = [chainRootNode]
            chainRootNode = parentNode
            currentElement = parentElement
        }
        let isMenuTarget = targetNode.role == kAXMenuItemRole || targetNode.role == kAXMenuBarItemRole
        let chainSnapshot = AccessibilityTreeSnapshot(
            snapshotGeneration: 0, application: application, windowTitle: nil, scope: isMenuTarget ? .menuBar : .focusedWindow,
            rootNodes: [chainRootNode], rawNodeCount: recordingWalkProgress.rawNodeCount, wasTruncatedDuringRead: false)
        return chainSnapshot.recordedElementContext(forNodeWithIdentifier: targetNode.elementIdentifier)
    }
}
