import Foundation

/// The checklist every other checklist fixture builds on: the fixture app, and a fixed creation date.
func makeFixtureChecklist(items: [ChecklistItem], taskIdentifier: String = "20260922-153012-ab12cd",
                          originalCommand: String = "rename the screenshots", title: String = "Rename screenshots") -> Checklist {
    Checklist(taskIdentifier: taskIdentifier, originalCommand: originalCommand, title: title,
              targetApplication: fixtureTargetApplication, items: items, createdAt: Date(timeIntervalSince1970: 1_790_000_000))
}

func makeFixtureChecklist(itemCount: Int = 3, irreversibleItemIdentifiers: Set<String> = []) -> Checklist {
    makeFixtureChecklist(items: (1...max(itemCount, 1)).prefix(itemCount).map { itemNumber in
        ChecklistItem(itemIdentifier: "item-\(itemNumber)", label: "Rename file \(itemNumber)",
                      actionSummary: "Rename the file in row \(itemNumber).",
                      parameters: [ChecklistItemParameter(name: "newName", value: "shot-0\(itemNumber)")],
                      isIrreversible: irreversibleItemIdentifiers.contains("item-\(itemNumber)"))
    })
}
