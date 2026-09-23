import Foundation

private let baselineFingerprint = UserInterfaceChangeFingerprint(
    focusedElementToken: 1, focusedElementValueToken: 2, selectedTextRangeToken: 3, targetElementStateToken: 4, windowCount: 1,
    focusedWindowTitle: "Inbox", webAreaAddress: "https://example.com", focusedWindowChildCount: 12, windowImageThumbnail: nil)

let userInterfaceChangeFingerprintTestSuite = CoreTestSuite(name: "UserInterfaceChangeFingerprint", testCases: [
    CoreTestCase(name: "identical fingerprints show no change") {
        try expectTrue(!UserInterfaceChangeFingerprint.showsObservableChange(from: baselineFingerprint, to: baselineFingerprint))
    },
    CoreTestCase(name: "each Accessibility field alone counts as a change") {
        let mutations: [(String, (inout UserInterfaceChangeFingerprint) -> Void)] = [
            ("focused element", { $0.focusedElementToken = 9 }), ("value", { $0.focusedElementValueToken = nil }),
            ("selection", { $0.selectedTextRangeToken = 9 }), ("target state", { $0.targetElementStateToken = 9 }),
            ("window count", { $0.windowCount = 2 }), ("title", { $0.focusedWindowTitle = "Sent" }),
            ("address", { $0.webAreaAddress = "https://example.com/next" }), ("children", { $0.focusedWindowChildCount = 13 }),
        ]
        for (fieldName, mutate) in mutations {
            var changedFingerprint = baselineFingerprint
            mutate(&changedFingerprint)
            try expectTrue(UserInterfaceChangeFingerprint.showsObservableChange(from: baselineFingerprint, to: changedFingerprint), fieldName)
        }
    },
    CoreTestCase(name: "a thumbnail change counts from 3 clearly changed cells: a caret blink doesn't, a typed word does") {
        let blankCells = [UInt8](repeating: 250, count: WindowImageThumbnail.sideLengthInCells * WindowImageThumbnail.sideLengthInCells)
        var before = baselineFingerprint
        before.windowImageThumbnail = WindowImageThumbnail(grayscaleCells: blankCells)
        var caretBlinkCells = blankCells
        caretBlinkCells[100] = 200
        caretBlinkCells[164] = 200
        var after = baselineFingerprint
        after.windowImageThumbnail = WindowImageThumbnail(grayscaleCells: caretBlinkCells)
        try expectTrue(!UserInterfaceChangeFingerprint.showsObservableChange(from: before, to: after))
        var typedWordCells = blankCells
        for cellIndex in 300..<306 { typedWordCells[cellIndex] = 180 }
        after.windowImageThumbnail = WindowImageThumbnail(grayscaleCells: typedWordCells)
        try expectTrue(UserInterfaceChangeFingerprint.showsObservableChange(from: before, to: after))
        var faintCells = blankCells
        for cellIndex in 300..<340 { faintCells[cellIndex] = 245 }
        after.windowImageThumbnail = WindowImageThumbnail(grayscaleCells: faintCells)
        try expectTrue(!UserInterfaceChangeFingerprint.showsObservableChange(from: before, to: after))
    },
    CoreTestCase(name: "a missing thumbnail on either side is ignored, and a wrong-size buffer makes no thumbnail") {
        var after = baselineFingerprint
        after.windowImageThumbnail = WindowImageThumbnail(grayscaleCells: [UInt8](repeating: 0, count: 64 * 64))
        try expectTrue(!UserInterfaceChangeFingerprint.showsObservableChange(from: baselineFingerprint, to: after))
        try expectTrue(WindowImageThumbnail(grayscaleCells: [UInt8](repeating: 0, count: 72)) == nil)
    },
])
