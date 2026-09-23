import Foundation

/// Counts the checklist items in a submit_plan call while its input streams in, so planning can show progress during
/// the long turn that writes the plan. Every item has exactly one `"label"` key. Inside a JSON string a quote is
/// always escaped (`\"label\"`), so the unescaped key text can only be the key itself. A fragment boundary can split
/// the key, so the tail of the previous fragment is kept and searched again with the next one.
struct SubmittedChecklistItemStreamCounter: Sendable {
    private static let itemKeyText = "\"label\""

    private(set) var itemsWrittenSoFar = 0
    private var carriedTail = ""

    /// Returns true when the count changed.
    mutating func consume(partialJSON partialJSONFragment: String) -> Bool {
        let searchedText = carriedTail + partialJSONFragment
        var newlyFoundItemCount = 0
        var searchStartIndex = searchedText.startIndex
        while let foundRange = searchedText.range(of: Self.itemKeyText, range: searchStartIndex..<searchedText.endIndex) {
            newlyFoundItemCount += 1
            searchStartIndex = foundRange.upperBound
        }
        // Everything up to the last match is spent; of the rest, only a possible key prefix needs carrying.
        let unsearchedRemainder = searchedText[searchStartIndex...]
        carriedTail = String(unsearchedRemainder.suffix(Self.itemKeyText.count - 1))
        itemsWrittenSoFar += newlyFoundItemCount
        return newlyFoundItemCount > 0
    }
}
