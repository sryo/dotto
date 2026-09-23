import CoreGraphics
import Foundation

let finderWindowScriptOutputTestSuite = CoreTestSuite(name: "Finder window script output", testCases: [
    CoreTestCase(name: "the front window under the summon point gives its folder and the selection inside it") {
        let scriptOutputText = """
        W\t100,100,900,700\t/Users/me/pruebita/
        W\t0,0,1400,900\t/Users/me/Documents/
        S\t/Users/me/pruebita/a.png
        S\t/Users/me/pruebita/b.png
        S\t/Users/me/elsewhere/c.png
        """
        let windowContents = try unwrapOrFail(FinderWindowScriptOutput.chosenWindowContents(
            fromScriptOutputText: scriptOutputText, summonOriginInTopLeftGlobalPoints: CGPoint(x: 300, y: 300),
            accessibilityFolderPath: nil))
        try expectEqual(windowContents.folderPath, "/Users/me/pruebita")
        try expectEqual(windowContents.selectedItemPaths, ["/Users/me/pruebita/a.png", "/Users/me/pruebita/b.png"])
    },
    CoreTestCase(name: "a window behind the front one gives its folder but never the front window's selection") {
        let scriptOutputText = "W\t100,100,500,500\t/Users/me/front/\nW\t600,100,1200,800\t/Users/me/back/\nS\t/Users/me/front/a.png\n"
        let windowContents = try unwrapOrFail(FinderWindowScriptOutput.chosenWindowContents(
            fromScriptOutputText: scriptOutputText, summonOriginInTopLeftGlobalPoints: CGPoint(x: 800, y: 300),
            accessibilityFolderPath: nil))
        try expectEqual(windowContents.folderPath, "/Users/me/back")
        try expectEqual(windowContents.selectedItemPaths, [])
    },
    CoreTestCase(name: "no window under the point gives nothing, and a folder with a tab in its name stays whole") {
        try expectTrue(FinderWindowScriptOutput.chosenWindowContents(
            fromScriptOutputText: "W\t100,100,500,500\t/Users/me/front/\n", summonOriginInTopLeftGlobalPoints: CGPoint(x: 900, y: 900),
            accessibilityFolderPath: nil) == nil)
        let windowContents = try unwrapOrFail(FinderWindowScriptOutput.chosenWindowContents(
            fromScriptOutputText: "W\t100,100,500,500\t/Users/me/odd\tname/\n", summonOriginInTopLeftGlobalPoints: nil,
            accessibilityFolderPath: nil))
        try expectEqual(windowContents.folderPath, "/Users/me/odd\tname")
    },
])
