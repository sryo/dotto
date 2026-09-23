import Foundation

let fileOperationPathRulesTestSuite = CoreTestSuite(name: "FileOperationPathRules", testCases: [
    CoreTestCase(name: "new names refuse separators, controls, dot names, edge whitespace, hidden names and over-long names") {
        try expectTrue(FileOperationPathRules.validateNewName("2026-09 Septiembre", sourceName: nil) == nil)
        try expectTrue(FileOperationPathRules.validateNewName("Family 👨‍👩‍👧 trip", sourceName: nil) == nil, "emoji joiners are not controls")
        for invalidName in ["", ".", "..", "a/b", "a:b", "a\u{0}b", "tab\there", "line\nbreak", " leading", "trailing ", ".hidden",
                            String(repeating: "é", count: 128)] {
            try expectTrue(FileOperationPathRules.validateNewName(invalidName, sourceName: nil) != nil, invalidName)
        }
        try expectTrue(FileOperationPathRules.validateNewName(String(repeating: "a", count: 255), sourceName: nil) == nil)
        try expectTrue(FileOperationPathRules.validateNewName(".env", sourceName: ".env") == nil, "an unchanged hidden name may be kept")
    },
    CoreTestCase(name: "the collision key ignores case and Unicode normalization") {
        let composedName = "/Users/me/Caf\u{00E9}.png"
        let decomposedName = "/Users/me/Cafe\u{0301}.png"
        try expectEqual(FileOperationPathRules.collisionKey(forPath: composedName), FileOperationPathRules.collisionKey(forPath: decomposedName))
        try expectEqual(FileOperationPathRules.collisionKey(forPath: "/Users/me/IMG_1.PNG"), FileOperationPathRules.collisionKey(forPath: "/Users/me/img_1.png"))
        try expectTrue(FileOperationPathRules.collisionKey(forPath: "/a/b") != FileOperationPathRules.collisionKey(forPath: "/a/c"))
    },
    CoreTestCase(name: "suffixing keeps the last extension, and folders and extensionless names get the suffix at the end") {
        try expectEqual(FileOperationPathRules.suffixedPath("/a/IMG_1.png", attempt: 2), "/a/IMG_1 2.png")
        try expectEqual(FileOperationPathRules.suffixedPath("/a/IMG_1.png", attempt: 3), "/a/IMG_1 3.png")
        try expectEqual(FileOperationPathRules.suffixedPath("/a/archive.tar.gz", attempt: 2), "/a/archive.tar 2.gz")
        try expectEqual(FileOperationPathRules.suffixedPath("/a/README", attempt: 2), "/a/README 2")
        try expectEqual(FileOperationPathRules.suffixedPath("/a/2026.09", attempt: 2, isPlainFolder: true), "/a/2026.09 2")
        try expectEqual(FileOperationPathRules.suffixedPath("/a/Tool.app", attempt: 2), "/a/Tool 2.app")
        try expectEqual(FileOperationPathRules.suffixedPath("/a/.env", attempt: 2), "/a/.env 2")
    },
    CoreTestCase(name: "the nearest existing ancestor is split from the components still to create") {
        let existingPaths: Set<String> = ["/a", "/a/b"]
        let split = FileOperationPathRules.splitAtNearestExistingAncestor("/a/b/new1/new2") { existingPaths.contains($0) }
        try expectEqual(split.existingAncestorPath, "/a/b")
        try expectEqual(split.missingComponents, ["new1", "new2"])
        let rootSplit = FileOperationPathRules.splitAtNearestExistingAncestor("/x/y") { _ in false }
        try expectEqual(rootSplit.existingAncestorPath, "/")
        try expectEqual(rootSplit.missingComponents, ["x", "y"])
    },
])
