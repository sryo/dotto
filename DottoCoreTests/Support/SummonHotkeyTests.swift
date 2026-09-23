import Foundation

let summonHotkeyTestSuite = CoreTestSuite(name: "SummonHotkey", testCases: [
    CoreTestCase(name: "the default is ⌃⌥Space and survives a JSON round trip") {
        try expectEqual(SummonHotkey.standard.displayText, "⌃⌥Space")
        try expectEqual(SummonHotkey.standard.validationProblem, nil)
        let roundTripped = try JSONDecoder().decode(SummonHotkey.self, from: JSONEncoder().encode(SummonHotkey.standard))
        try expectEqual(roundTripped, .standard)
    },
    CoreTestCase(name: "a shortcut needs ⌘, ⌥ or ⌃ plus a real key, and avoids Esc, Return, Tab and ⌘Q") {
        let shiftK = SummonHotkey(keyCode: 40, usesCommand: false, usesOption: false, usesControl: false, usesShift: true, keyDisplayName: "K")
        try expectTrue(shiftK.validationProblem != nil)
        let controlOnly = SummonHotkey(keyCode: 59, usesCommand: false, usesOption: false, usesControl: true, usesShift: false, keyDisplayName: "Key 59")
        try expectTrue(controlOnly.validationProblem != nil)
        let optionEscape = SummonHotkey(keyCode: 53, usesCommand: false, usesOption: true, usesControl: false, usesShift: false, keyDisplayName: "Esc")
        try expectTrue(optionEscape.validationProblem != nil)
        let commandQ = SummonHotkey(keyCode: 12, usesCommand: true, usesOption: false, usesControl: false, usesShift: false, keyDisplayName: "Q")
        try expectTrue(commandQ.validationProblem != nil)
        let commandShiftK = SummonHotkey(keyCode: 40, usesCommand: true, usesOption: false, usesControl: false, usesShift: true, keyDisplayName: "K")
        try expectEqual(commandShiftK.validationProblem, nil)
        try expectEqual(commandShiftK.displayText, "⇧⌘K")
    },
    CoreTestCase(name: "key names: named keys by code, others by the typed character") {
        try expectEqual(SummonHotkey.keyDisplayName(forKeyCode: 49, typedCharacters: " "), "Space")
        try expectEqual(SummonHotkey.keyDisplayName(forKeyCode: 96, typedCharacters: nil), "F5")
        try expectEqual(SummonHotkey.keyDisplayName(forKeyCode: 40, typedCharacters: "k"), "K")
        try expectEqual(SummonHotkey.keyDisplayName(forKeyCode: 50, typedCharacters: ""), "Key 50")
    },
])
