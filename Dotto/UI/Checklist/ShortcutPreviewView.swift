import SwiftUI

/// A shortcut plan before it runs: which of the user's shortcuts, with what input. A shortcut is opaque to Dotto, so
/// the preview says plainly that it can do anything its actions allow, and Dotto asks again before every run.
struct ShortcutPreviewView: View {
    let shortcutPlan: ShortcutPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "square.2.layers.3d")
                    .font(.system(size: 18))
                    .foregroundColor(DesignSystem.Colors.accentText)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    WrappingText("Runs your shortcut “\(shortcutPlan.shortcutName)”", size: 13, weight: .medium,
                                 color: DesignSystem.Colors.textPrimary)
                    if let inputDescription {
                        WrappingText(inputDescription, size: 11, color: DesignSystem.Colors.textTertiary)
                    }
                }
            }
            if !shortcutPlan.oneSentenceSummary.isEmpty {
                WrappingText(shortcutPlan.oneSentenceSummary, size: 12)
            }
            if case .files(let inputFilePaths) = shortcutPlan.input {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(inputFilePaths, id: \.self) { inputFilePath in
                        Label(FileOperationPreviewText.basename(of: inputFilePath), systemImage: "doc")
                            .font(.system(size: 11))
                            .foregroundColor(DesignSystem.Colors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            DirectRouteNoteLine(iconSystemName: "exclamationmark.shield.fill", color: DesignSystem.Colors.warningText,
                                text: "Shortcuts can do anything their actions allow. Dotto asks before running it.")
            DirectRouteNoteLine(iconSystemName: "arrow.uturn.backward.circle", color: DesignSystem.Colors.textSecondary,
                                text: "Dotto can't undo what a shortcut does.")
        }
    }

    /// "with 3 files from “Exports”", "with the text “…”", or nothing for a shortcut that takes no input.
    private var inputDescription: String? {
        switch shortcutPlan.input {
        case .none:
            return nil
        case .text(let inputText):
            return "with the text “\(UserFacingTextSanitizing.singleLine(inputText, maximumLength: 60))”"
        case .files(let inputFilePaths):
            let fileCountText = inputFilePaths.count == 1 ? "1 file" : "\(inputFilePaths.count) files"
            let parentFolderNames = Set(inputFilePaths.map { inputFilePath in
                FileOperationPreviewText.basename(of: (inputFilePath as NSString).deletingLastPathComponent)
            })
            guard parentFolderNames.count == 1, let parentFolderName = parentFolderNames.first else {
                return "with \(fileCountText)"
            }
            return "with \(fileCountText) from “\(parentFolderName)”"
        }
    }
}
