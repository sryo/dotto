import Foundation

/// What to do at launch with an API key saved before the product was renamed from Again to Dotto, when the Keychain
/// item's service name changed. A key already saved under the current name always wins, so the move happens at most
/// once and never overwrites a key the user entered since.
enum AnthropicAPIKeyRenameMigrationStep: Equatable {
    case leaveKeychainUnchanged
    case copyPreviousKeyToCurrentItemThenDeletePreviousItem
}

enum AnthropicAPIKeyRenameMigration {
    static func step(currentItemHoldsAKey: Bool, previousItemHoldsAKey: Bool) -> AnthropicAPIKeyRenameMigrationStep {
        guard !currentItemHoldsAKey, previousItemHoldsAKey else { return .leaveKeychainUnchanged }
        return .copyPreviousKeyToCurrentItemThenDeletePreviousItem
    }
}
