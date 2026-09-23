import SwiftUI

/// A file-operations plan before it runs: one disclosure row per group with its count, the changes of an open group
/// as "from → to" lines relative to the scope folder, and a warning that lists every name Dotto adjusted so nothing
/// is overwritten.
struct FileOperationsPreviewTable: View {
    let fileOperationsPlan: FileOperationsPlan

    @State private var expandedGroupIdentifiers: Set<String> = []
    @State private var isShowingCollisionAdjustments = false

    /// An open group's rows scroll inside the card past this height, so one big group can't push the others away.
    private static let maximumExpandedGroupHeight: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(fileOperationsPlan.groups) { operationGroup in
                groupSection(operationGroup)
            }
            if !fileOperationsPlan.collisionAdjustments.isEmpty {
                collisionAdjustmentsSection
                    .padding(.top, 6)
            }
            Label("Undo is available after it runs", systemImage: "info.circle")
                .font(.system(size: 11))
                .foregroundColor(DesignSystem.Colors.textTertiary)
                .padding(.top, 6)
        }
    }

    private func operations(inGroup groupIdentifier: String) -> [PlannedFileOperation] {
        fileOperationsPlan.operations.filter { $0.groupIdentifier == groupIdentifier }
    }

    @ViewBuilder
    private func groupSection(_ operationGroup: FileOperationGroup) -> some View {
        let groupOperations = operations(inGroup: operationGroup.groupIdentifier)
        let isExpanded = expandedGroupIdentifiers.contains(operationGroup.groupIdentifier)
        let movesToTrash = groupOperations.contains { $0.kind == .moveToTrash }
        VStack(alignment: .leading, spacing: 2) {
            HoverAwarePlainButton(action: { toggleGroup(operationGroup.groupIdentifier) }) { isHovered in
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                    Text(operationGroup.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if movesToTrash {
                        trashBadge
                    }
                    Spacer(minLength: 4)
                    Text("\(groupOperations.count)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.medium, style: .continuous)
                    .fill(isHovered ? DesignSystem.Colors.surface2 : Color.clear))
            }
            .accessibilityLabel("\(operationGroup.title), \(groupOperations.count) changes")
            .accessibilityHint(isExpanded ? "Hides the changes" : "Shows the changes")
            if isExpanded {
                expandedOperationRows(groupOperations)
            }
        }
    }

    private var trashBadge: some View {
        Text("Moves to the Trash")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(DesignSystem.Colors.destructiveText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(DesignSystem.Colors.destructive.opacity(0.15)))
            .fixedSize()
    }

    private func expandedOperationRows(_ groupOperations: [PlannedFileOperation]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                ForEach(groupOperations) { plannedOperation in
                    FileOperationPreviewRow(plannedOperation: plannedOperation, scope: fileOperationsPlan.scope)
                }
            }
            .padding(.leading, 24)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
        }
        // A ScrollView has no height of its own: about 20 points a row, up to the cap.
        .frame(height: min(Self.maximumExpandedGroupHeight, CGFloat(groupOperations.count) * 20 + 8))
    }

    private var collisionAdjustmentsSection: some View {
        let adjustmentCount = fileOperationsPlan.collisionAdjustments.count
        return VStack(alignment: .leading, spacing: 4) {
            HoverAwarePlainButton(action: { isShowingCollisionAdjustments.toggle() }) { isHovered in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(adjustmentCount == 1 ? "1 name adjusted so nothing is overwritten"
                                              : "\(adjustmentCount) names adjusted so nothing is overwritten")
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(isShowingCollisionAdjustments ? 90 : 0))
                }
                .foregroundColor(isHovered ? DesignSystem.Colors.warning : DesignSystem.Colors.warningText)
            }
            if isShowingCollisionAdjustments {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(fileOperationsPlan.collisionAdjustments, id: \.operationIdentifier) { collisionAdjustment in
                        FileOperationPreviewPathPair(
                            fromText: FileOperationPreviewText.basename(of: collisionAdjustment.requestedDestinationPath),
                            toText: FileOperationPreviewText.basename(of: collisionAdjustment.adjustedDestinationPath))
                    }
                }
                .padding(.leading, 16)
            }
        }
    }

    private func toggleGroup(_ groupIdentifier: String) {
        if expandedGroupIdentifiers.contains(groupIdentifier) {
            expandedGroupIdentifiers.remove(groupIdentifier)
        } else {
            expandedGroupIdentifiers.insert(groupIdentifier)
        }
    }
}

/// One planned change as "IMG_2041.png → 2026-09 Septiembre/", with the planner's reason as its tooltip.
private struct FileOperationPreviewRow: View {
    let plannedOperation: PlannedFileOperation
    let scope: DirectRouteScope

    var body: some View {
        let displayedTexts = FileOperationPreviewText.displayedTexts(for: plannedOperation, scope: scope)
        FileOperationPreviewPathPair(fromText: displayedTexts.fromText, toText: displayedTexts.toText)
            // The reason is model-written text: shown only as a plain tooltip, never parsed.
            .nativeTooltip(plannedOperation.reason.isEmpty ? nil : plannedOperation.reason)
    }
}

private struct FileOperationPreviewPathPair: View {
    let fromText: String
    let toText: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(fromText)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(DesignSystem.Colors.textSecondary)
            if let toText {
                Text("→")
                    .foregroundColor(DesignSystem.Colors.textTertiary)
                Text(toText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(DesignSystem.Colors.textPrimary)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
    }
}

/// How the preview names paths: basenames for sources, and destinations relative to the scope folder they are in.
enum FileOperationPreviewText {
    static func basename(of path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// The path below the scope root that contains it ("2026-09 Septiembre/IMG_2041.png"), or its basename when no
    /// root does. Compared component by component, so "/a/bc" is never read as inside "/a/b".
    static func pathRelativeToScope(_ path: String, scope: DirectRouteScope) -> String {
        let pathComponents = (path as NSString).pathComponents
        for scopeRoot in scope.roots {
            let rootComponents = (scopeRoot.canonicalPath as NSString).pathComponents
            guard pathComponents.count > rootComponents.count,
                  Array(pathComponents.prefix(rootComponents.count)) == rootComponents else { continue }
            return pathComponents.dropFirst(rootComponents.count).joined(separator: "/")
        }
        return basename(of: path)
    }

    /// The scope as the header names it: "“Screenshots”", or "2 folders".
    static func scopeDescription(_ scope: DirectRouteScope) -> String {
        if scope.roots.count == 1, let onlyRoot = scope.roots.first {
            return "“\(basename(of: onlyRoot.canonicalPath))”"
        }
        return "\(scope.roots.count) folders"
    }

    static func displayedTexts(for plannedOperation: PlannedFileOperation, scope: DirectRouteScope) -> (fromText: String, toText: String?) {
        let sourceName = plannedOperation.sourcePath.map(basename(of:)) ?? ""
        switch plannedOperation.kind {
        case .createFolder:
            let createdFolderText = plannedOperation.destinationPath.map { pathRelativeToScope($0, scope: scope) } ?? ""
            return ("New folder", createdFolderText + "/")
        case .rename:
            return (sourceName, plannedOperation.destinationPath.map(basename(of:)))
        case .move, .copy:
            guard let destinationPath = plannedOperation.destinationPath else { return (sourceName, nil) }
            let destinationName = basename(of: destinationPath)
            let destinationFolderPath = (destinationPath as NSString).deletingLastPathComponent
            let destinationFolderText = pathRelativeToScope(destinationFolderPath, scope: scope)
            let folderIsAScopeRoot = scope.roots.contains { $0.canonicalPath == destinationFolderPath }
            let folderText = folderIsAScopeRoot ? basename(of: destinationFolderPath) + "/" : destinationFolderText + "/"
            // The name only shows when it changes on the way: "IMG_1.png → Shots/IMG_1 2.png".
            let destinationText = destinationName == sourceName ? folderText : folderText + destinationName
            return (plannedOperation.kind == .copy ? "Copy of \(sourceName)" : sourceName, destinationText)
        case .setTags:
            let tagsText = (plannedOperation.tags ?? []).isEmpty ? "no tags" : (plannedOperation.tags ?? []).joined(separator: ", ")
            return (sourceName, "tags: \(tagsText)")
        case .moveToTrash:
            return (sourceName, "Trash")
        }
    }
}
