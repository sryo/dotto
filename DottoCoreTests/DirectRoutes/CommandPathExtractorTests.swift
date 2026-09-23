import Foundation

private func candidates(_ userText: String) -> [String] {
    CommandPathExtractor.candidateFolderPaths(inUserText: userText, homeDirectoryPath: "/Users/me")
}

let commandPathExtractorTestSuite = CoreTestSuite(name: "CommandPathExtractor", testCases: [
    CoreTestCase(name: "absolute and home-relative paths are found, without trailing punctuation") {
        try expectEqual(candidates("sort /Users/me/Shots by month."), ["/Users/me/Shots"])
        try expectEqual(candidates("move everything in ~/Desktop/x, then stop"), ["/Users/me/Desktop/x"])
        try expectEqual(candidates("tidy /Users/me/My\\ Folder now"), ["/Users/me/My Folder"])
    },
    CoreTestCase(name: "quoted paths keep their spaces") {
        try expectEqual(candidates("rename files in \"/Users/me/Tax Docs/2025\" please"), ["/Users/me/Tax Docs/2025"])
        try expectEqual(candidates("ordená “~/Mis Fotos/Viaje”"), ["/Users/me/Mis Fotos/Viaje"])
    },
    CoreTestCase(name: "well-known folders named as folders or quoted map under the home folder, in English and Spanish") {
        try expectEqual(candidates("clean up my Downloads folder"), ["/Users/me/Downloads"])
        try expectEqual(candidates("ordená la carpeta de Descargas y la carpeta del Escritorio"), ["/Users/me/Downloads", "/Users/me/Desktop"])
        try expectEqual(candidates("sort the folder called Imágenes"), ["/Users/me/Pictures"])
        try expectEqual(candidates("sort \"Pictures\" by month"), ["/Users/me/Pictures"])
    },
    CoreTestCase(name: "a bare folder noun never becomes a scope folder") {
        try expectEqual(candidates("rename the documents in this window"), [])
        try expectEqual(candidates("ordená las fotos de Descargas y del Escritorio"), [])
        try expectEqual(candidates("sort Imágenes"), [])
        try expectEqual(candidates("put my music and movies in order"), [])
        try expectEqual(candidates("the folder of this project has documents"), [])
    },
    CoreTestCase(name: "fractions, URLs and words inside other words are not paths") {
        try expectEqual(candidates("keep 1/2 of the files"), [])
        try expectEqual(candidates("open https://example.com/Users/me"), [])
        try expectEqual(candidates("the desktops and downloader app"), [])
        try expectEqual(candidates("it's /"), [])
    },
])
