import Foundation

let anthropicAPIKeyRenameMigrationTestSuite = CoreTestSuite(name: "AnthropicAPIKeyRenameMigration", testCases: [
    CoreTestCase(name: "a key only under the previous name is copied to the current item, then the previous item is deleted") {
        try expectEqual(AnthropicAPIKeyRenameMigration.step(currentItemHoldsAKey: false, previousItemHoldsAKey: true),
                        .copyPreviousKeyToCurrentItemThenDeletePreviousItem)
    },
    CoreTestCase(name: "a key under the current name is never overwritten, whatever the previous item holds") {
        try expectEqual(AnthropicAPIKeyRenameMigration.step(currentItemHoldsAKey: true, previousItemHoldsAKey: true),
                        .leaveKeychainUnchanged)
        try expectEqual(AnthropicAPIKeyRenameMigration.step(currentItemHoldsAKey: true, previousItemHoldsAKey: false),
                        .leaveKeychainUnchanged)
    },
    CoreTestCase(name: "with no key under either name there is nothing to move") {
        try expectEqual(AnthropicAPIKeyRenameMigration.step(currentItemHoldsAKey: false, previousItemHoldsAKey: false),
                        .leaveKeychainUnchanged)
    },
])
