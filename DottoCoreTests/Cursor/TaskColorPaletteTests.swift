import Foundation
import CoreGraphics

let taskColorPaletteTestSuite = CoreTestSuite(name: "TaskColorPalette", testCases: [
    CoreTestCase(name: "the first task gets the owner's color, the next ones the palette's in order") {
        let ownerColorHex = CursorStyleConfiguration.defaultTaskColorHex
        try expectEqual(TaskColorPalette.colorHex(forNewTaskWithOwnerTaskColorHex: ownerColorHex, colorHexesInUse: []), ownerColorHex)
        try expectEqual(TaskColorPalette.colorHex(forNewTaskWithOwnerTaskColorHex: ownerColorHex, colorHexesInUse: [ownerColorHex]),
                        "#2F7BF5")
        try expectEqual(TaskColorPalette.colorHex(forNewTaskWithOwnerTaskColorHex: ownerColorHex,
                                                  colorHexesInUse: [ownerColorHex, "#2F7BF5"]), "#1FA37A")
    },
    CoreTestCase(name: "a color freed by a finished task is reused first, and a full palette reuses the least used") {
        let ownerColorHex = CursorStyleConfiguration.defaultTaskColorHex
        try expectEqual(TaskColorPalette.colorHex(forNewTaskWithOwnerTaskColorHex: ownerColorHex, colorHexesInUse: ["#2F7BF5"]),
                        ownerColorHex)
        try expectEqual(TaskColorPalette.colorHex(forNewTaskWithOwnerTaskColorHex: ownerColorHex,
                                                  colorHexesInUse: [ownerColorHex, "#2F7BF5", "#1FA37A", ownerColorHex]), "#2F7BF5")
    },
    CoreTestCase(name: "an owner color that matches a palette color isn't offered twice") {
        try expectEqual(TaskColorPalette.taskColorHexes(ownerTaskColorHex: "#2f7bf5"), ["#2f7bf5", "#1FA37A"])
    },
])
