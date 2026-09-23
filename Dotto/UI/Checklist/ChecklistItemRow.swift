import SwiftUI

/// One checklist line: status glyph (or the include checkbox before the run) and a one-line label. Clicking the
/// label or the chevron expands the row to show what Dotto will do, the item's values, and the label's edit field
/// before the run or the result after it.
struct ChecklistItemRow: View {
    let item: ChecklistItem
    let isCurrentItem: Bool
    let isEditable: Bool
    @ObservedObject var taskSessionController: TaskSessionController

    @State private var isExpanded = false
    @State private var isHovered = false

    private var requiresConfirmation: Bool {
        if case .requireUserConfirmation = SafetyGate.evaluateChecklistItem(item) { return true }
        return false
    }

    private var labelColor: Color {
        if isEditable { return item.isIncludedByUser ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textTertiary }
        return item.runStatus == .skipped ? DesignSystem.Colors.textTertiary : DesignSystem.Colors.textPrimary
    }

    /// The full label for the truncated line, with the result once the item has run and whether Dotto asks first.
    private var collapsedTooltip: String {
        var tooltipLines = [item.label]
        if let resultSummary = item.resultSummary, !resultSummary.isEmpty { tooltipLines.append(resultSummary) }
        if isEditable && requiresConfirmation { tooltipLines.append("Dotto asks before running this item") }
        return tooltipLines.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                leadingIndicator
                    .frame(width: 18, height: 18)
                expansionToggle
            }
            if isExpanded {
                expandedDetails
                    .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.medium, style: .continuous)
                .fill(isCurrentItem ? DesignSystem.Colors.accentSubtle
                      : (isHovered || isExpanded ? DesignSystem.Colors.surface1 : Color.clear))
        )
        .onHover { isHovering in isHovered = isHovering }
        .animation(.easeOut(duration: DesignSystem.Animation.fast), value: isHovered)
    }

    /// The label line and chevron, one button: clicking anywhere on it expands or folds the row.
    private var expansionToggle: some View {
        HoverAwarePlainButton(action: { isExpanded.toggle() }) { isToggleHovered in
            HStack(alignment: .center, spacing: 6) {
                Text(item.label)
                    .font(.system(size: 13, weight: isCurrentItem ? .semibold : .regular))
                    .foregroundColor(labelColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isEditable && requiresConfirmation {
                    Text("Asks first")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DesignSystem.Colors.warningText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(DesignSystem.Colors.warning.opacity(0.15)))
                        .fixedSize()
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(isToggleHovered ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeOut(duration: DesignSystem.Animation.fast), value: isExpanded)
                    .frame(width: 14, height: 14)
            }
            .contentShape(Rectangle())
        }
        .nativeTooltip(isExpanded ? nil : collapsedTooltip)
        .accessibilityLabel(item.label)
        .accessibilityHint(isExpanded ? "Hide details" : "Show details")
    }

    @ViewBuilder
    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isEditable {
                TextField("Item label", text: Binding(
                    get: { item.label },
                    set: { newLabel in
                        taskSessionController.editItemLabel(itemIdentifier: item.itemIdentifier, newLabel: newLabel)
                    }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(DesignSystem.Colors.textPrimary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DesignSystem.Colors.surface2))
                .accessibilityLabel("Item label")
            }
            if !item.actionSummary.isEmpty {
                Text(item.actionSummary)
                    .font(.system(size: 11))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Parameters are what Dotto will actually type or pick, so the user can check them before approving.
            if !item.parameters.isEmpty {
                ChecklistItemParameterList(parameters: item.parameters)
            }
            if !isEditable, let resultSummary = item.resultSummary, !resultSummary.isEmpty {
                Text(resultSummary)
                    .font(.system(size: 11))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        if isEditable {
            HoverAwarePlainButton(action: {
                taskSessionController.setItemIncluded(itemIdentifier: item.itemIdentifier, isIncluded: !item.isIncludedByUser)
            }) { isHovered in
                Image(systemName: item.isIncludedByUser ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundColor(item.isIncludedByUser ? DesignSystem.Colors.accentText
                                     : (isHovered ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textTertiary))
                    .brightness(isHovered && item.isIncludedByUser ? 0.1 : 0)
            }
        } else {
            runStatusGlyph
        }
    }

    @ViewBuilder
    private var runStatusGlyph: some View {
        if item.runStatus == .running {
            ProgressView().controlSize(.small).scaleEffect(0.7)
        } else {
            let (glyphSystemName, glyphColor): (String, Color) = switch item.runStatus {
            case .completed: ("checkmark", DesignSystem.Colors.success)
            case .failed: ("xmark", DesignSystem.Colors.destructiveText)
            case .needsUser: ("exclamationmark", DesignSystem.Colors.warningText)
            case .skipped: ("minus", DesignSystem.Colors.textTertiary)
            case .pending, .running: ("circle", DesignSystem.Colors.textTertiary)
            }
            Image(systemName: glyphSystemName)
                .font(.system(size: 12, weight: item.runStatus == .pending ? .regular : .bold))
                .foregroundColor(glyphColor)
        }
    }
}

/// An item's values as a small "name: value" list, the name muted.
struct ChecklistItemParameterList: View {
    let parameters: [ChecklistItemParameter]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 2) {
            ForEach(Array(parameters.enumerated()), id: \.offset) { _, parameter in
                GridRow {
                    Text(Self.readableName(parameter.name))
                        .font(.system(size: 11))
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                        .lineLimit(1)
                        .gridColumnAlignment(.leading)
                    Text(parameter.value)
                        .font(.system(size: 11))
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// Model-written names like "new_name" or "fileName" read as "New name" and "File name".
    static func readableName(_ parameterName: String) -> String {
        let spacedName = parameterName
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
        guard let firstCharacter = spacedName.first else { return parameterName }
        return firstCharacter.uppercased() + spacedName.dropFirst()
    }
}
