import AppKit
import SwiftUI

/// A script plan before it runs: what it does, the app it tells, what it will change, and the whole script exactly as
/// it will run. Nothing is highlighted or reformatted, so what the user reads is what runs.
struct ScriptPreviewView: View {
    let scriptPlan: ScriptPlan
    let automationPermissionState: AutomationPermissionState

    @State private var copyConfirmationIsShowing = false

    private static let maximumSourceHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                applicationIcon
                VStack(alignment: .leading, spacing: 2) {
                    WrappingText(scriptPlan.oneSentenceSummary, size: 13, weight: .medium, color: DesignSystem.Colors.textPrimary)
                    Text("\(scriptPlan.language == .appleScript ? "AppleScript" : "JavaScript") for \(scriptPlan.targetApplicationName)")
                        .font(.system(size: 11))
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                }
            }
            if !scriptPlan.expectedEffects.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(scriptPlan.expectedEffects.enumerated()), id: \.offset) { _, expectedEffect in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundColor(DesignSystem.Colors.textTertiary)
                            WrappingText(expectedEffect, size: 12)
                        }
                    }
                }
            }
            sourceBox
            notes
        }
    }

    @ViewBuilder
    private var applicationIcon: some View {
        if let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: scriptPlan.targetBundleIdentifier) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: applicationURL.path))
                .resizable()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "applescript")
                .font(.system(size: 20))
                .foregroundColor(DesignSystem.Colors.textSecondary)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        }
    }

    private var sourceBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("The script")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
                Spacer()
                Button(copyConfirmationIsShowing ? "Copied" : "Copy") { copySourceToPasteboard() }
                    .dsTextButtonStyle()
                    .nativeTooltip("Copy the script")
            }
            ScrollView([.vertical, .horizontal]) {
                Text(scriptPlan.source)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(DesignSystem.Colors.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: min(Self.maximumSourceHeight, estimatedSourceHeight))
            .background(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.medium, style: .continuous)
                .fill(DesignSystem.Colors.surface1))
            .overlay(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.medium, style: .continuous)
                .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 1))
        }
    }

    /// About 15 points a line at 11.5 points, plus the padding, so a short script doesn't sit in a tall empty box.
    private var estimatedSourceHeight: CGFloat {
        let lineCount = scriptPlan.source.split(separator: "\n", omittingEmptySubsequences: false).count
        return CGFloat(max(lineCount, 1)) * 15 + 20
    }

    @ViewBuilder
    private var notes: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let riskMatch = scriptPlan.inspection.riskMatch {
                DirectRouteNoteLine(iconSystemName: "exclamationmark.shield.fill", color: DesignSystem.Colors.warningText,
                                    text: "\(Self.riskDescription(riskMatch)): Dotto asks before running")
            }
            if scriptPlan.modifiesData {
                DirectRouteNoteLine(iconSystemName: "arrow.uturn.backward.circle", color: DesignSystem.Colors.textSecondary,
                                    text: "Changes data in \(scriptPlan.targetApplicationName). Dotto can't undo this.")
            }
            switch automationPermissionState {
            case .notYetAsked:
                DirectRouteNoteLine(iconSystemName: "lock", color: DesignSystem.Colors.textSecondary,
                                    text: "macOS will ask to let Dotto control \(scriptPlan.targetApplicationName).")
            case .denied:
                DirectRouteNoteLine(iconSystemName: "lock.slash", color: DesignSystem.Colors.warningText,
                                    text: "Dotto isn't allowed to control \(scriptPlan.targetApplicationName). Turn it on in System Settings › Privacy & Security › Automation.")
            case .targetNotRunning:
                DirectRouteNoteLine(iconSystemName: "app.dashed", color: DesignSystem.Colors.warningText,
                                    text: "Open \(scriptPlan.targetApplicationName) first: Dotto never opens apps.")
            case .granted, .unknown:
                EmptyView()
            }
        }
    }

    /// "Deletes: “delete every message”": the kind of risk, then what in the script matched it.
    private static func riskDescription(_ riskMatch: SafetyRiskMatch) -> String {
        let riskKind: String
        switch riskMatch.riskCategory {
        case .deleting: riskKind = "Deletes"
        case .sendingOrPublishing: riskKind = "Sends or shares"
        case .payingOrBuying: riskKind = "Pays or buys"
        default: riskKind = "Risky"
        }
        return "\(riskKind) (“\(UserFacingTextSanitizing.singleLine(riskMatch.matchedText, maximumLength: 40))”)"
    }

    private func copySourceToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(scriptPlan.source, forType: .string)
        copyConfirmationIsShowing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copyConfirmationIsShowing = false
        }
    }
}

/// An icon and one wrapping line: the notes under a direct-route preview or result.
struct DirectRouteNoteLine: View {
    let iconSystemName: String
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: iconSystemName)
                .font(.system(size: 10))
                .foregroundColor(color)
                .accessibilityHidden(true)
            WrappingText(text, size: 11, color: color)
        }
    }
}
