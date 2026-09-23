import Foundation

private func matches(_ commandCharacter: String?, mask commandModifierMask: Int?, key keyName: String,
                     _ modifiers: [AgentKeyModifier]) -> Bool {
    MenuShortcutMatcher.menuItem(commandCharacter: commandCharacter, commandModifierMask: commandModifierMask,
                                 matchesKeyName: keyName, modifiers: modifiers)
}

let menuShortcutMatcherTestSuite = CoreTestSuite(name: "MenuShortcutMatcher", testCases: [
    CoreTestCase(name: "⌘S matches an item with no mask or mask 0, whatever the character's case") {
        try expectTrue(matches("S", mask: nil, key: "s", [.command]))
        try expectTrue(matches("s", mask: 0, key: "S", [.command]))
    },
    CoreTestCase(name: "⇧⌘S matches mask 1, ⌥⌘S mask 2 and ⌃⌘S mask 4; modifier sets must be equal") {
        try expectTrue(matches("S", mask: 1, key: "s", [.shift, .command]))
        try expectTrue(matches("S", mask: 2, key: "s", [.command, .option]))
        try expectTrue(matches("S", mask: 4, key: "s", [.control, .command]))
        try expectTrue(!matches("S", mask: 1, key: "s", [.command]))
        try expectTrue(!matches("S", mask: 0, key: "s", [.shift, .command]))
    },
    CoreTestCase(name: "a no-⌘ mask never matches a ⌘ chord") {
        try expectTrue(!matches("S", mask: 8, key: "s", [.command]))
        try expectTrue(matches("S", mask: 8, key: "s", []))
    },
    CoreTestCase(name: "key aliases go through canonicalKeyName, and a missing character never matches") {
        try expectTrue(matches("\r", mask: 0, key: "enter", [.command]))
        try expectTrue(!matches(nil, mask: 0, key: "s", [.command]))
        try expectTrue(!matches("", mask: 0, key: "s", [.command]))
        try expectTrue(!matches("A", mask: 0, key: "s", [.command]))
    },
])
