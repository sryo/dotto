import Foundation

/// Stands in for Platform's realpath-based canonicalizer: known symlinks resolve, unknown paths don't exist.
private func makeFakeCanonicalizer(existingFiles: Set<String>, symlinkTargets: [String: String] = [:]) -> (String) -> String? {
    { requestedPath in
        let expandedPath = requestedPath.hasPrefix("~/") ? "/Users/me/" + requestedPath.dropFirst(2) : requestedPath
        let resolvedPath = symlinkTargets[expandedPath] ?? expandedPath
        return existingFiles.contains(resolvedPath) ? resolvedPath : nil
    }
}

private let photosFolderGrant = UploadFileGrant.userPicked(canonicalPath: "/Users/me/Pictures/photos", isDirectory: true)
private let homeFolderGrant = UploadFileGrant.userPicked(canonicalPath: "/Users/me", isDirectory: true)
private let reportFileGrant = UploadFileGrant.userPicked(canonicalPath: "/Users/me/Documents/report.pdf", isDirectory: false)
private let existingFiles: Set<String> = [
    "/Users/me/Pictures/photos/img01.jpg", "/Users/me/Pictures/photos/img02.jpg", "/Users/me/Pictures/photos/trip/img03.jpg",
    "/Users/me/Pictures/photos-private/secret.jpg", "/Users/me/Documents/report.pdf", "/Users/me/.ssh/id_rsa",
    "/Users/me/Pictures/photos/.env", "/Users/me/Pictures/photos/.hidden/a.jpg", "/Users/me/.env",
    "/Users/me/Pictures/photos/../photos-private/secret.jpg",
    "/Users/me/Library/Application Support/Google/Chrome/Default/Login Data",
    "/Users/me/Library/Application Support/Dotto/BrowserProfile/Default/History",
    "/Users/me/Library/Mail/V10/message.emlx", "/Users/me/Library/notes.txt",
    "/Volumes/Data/Chrome/Default/Web Data", "/Volumes/Data/Chrome/Local State", "/Volumes/Data/Chrome/Default/Cookies",
    "/Volumes/Data/Chrome/Default/Login Data For Account", "/Volumes/Data/Application Support/Dotto/key.json",
]

private func deniedReason(_ decision: UploadFileAllowlistDecision) throws -> String {
    guard case .denied(let reasonForModel) = decision else { throw CoreTestFailure(description: "expected a denial, got \(decision)") }
    return reasonForModel
}

let uploadFileAllowlistTestSuite = CoreTestSuite(name: "UploadFileAllowlist", testCases: [
    CoreTestCase(name: "exact file grants and files inside folder grants are allowed") {
        let allowlist = UploadFileAllowlist(grants: [photosFolderGrant, reportFileGrant])
        let canonicalizer = makeFakeCanonicalizer(existingFiles: existingFiles)
        try expectEqual(allowlist.evaluate(requestedPaths: ["/Users/me/Documents/report.pdf", "/Users/me/Pictures/photos/trip/img03.jpg"],
                                           canonicalizeExistingRegularFile: canonicalizer),
                        .allowed(canonicalPaths: ["/Users/me/Documents/report.pdf", "/Users/me/Pictures/photos/trip/img03.jpg"]))
        try expectEqual(allowlist.evaluate(requestedPaths: ["~/Pictures/photos/img01.jpg"], canonicalizeExistingRegularFile: canonicalizer),
                        .allowed(canonicalPaths: ["/Users/me/Pictures/photos/img01.jpg"]))
    },
    CoreTestCase(name: "a sibling folder sharing the grant's prefix is denied, and the reason never lists grants") {
        let allowlist = UploadFileAllowlist(grants: [photosFolderGrant, reportFileGrant])
        let reason = try deniedReason(allowlist.evaluate(requestedPaths: ["/Users/me/Pictures/photos-private/secret.jpg"],
                                                         canonicalizeExistingRegularFile: makeFakeCanonicalizer(existingFiles: existingFiles)))
        try expectEqual(reason, "“secret.jpg” isn't one of the files attached to this task. Only files the user attached can be uploaded.")
        try expectTrue(!reason.contains("/Users/me") && !reason.contains("report.pdf"), reason)
    },
    CoreTestCase(name: "a symlink or .. that resolves outside the grant is denied") {
        let allowlist = UploadFileAllowlist(grants: [photosFolderGrant])
        let symlinkingCanonicalizer = makeFakeCanonicalizer(
            existingFiles: existingFiles, symlinkTargets: ["/Users/me/Pictures/photos/link.jpg": "/Users/me/.ssh/id_rsa",
                                                           "/Users/me/Pictures/photos/escape.jpg": "/Users/me/Pictures/photos-private/secret.jpg"])
        try expectTrue(try deniedReason(allowlist.evaluate(requestedPaths: ["/Users/me/Pictures/photos/escape.jpg"],
                                                           canonicalizeExistingRegularFile: symlinkingCanonicalizer)).contains("isn't one of the files"))
        try expectTrue(try deniedReason(allowlist.evaluate(requestedPaths: ["/Users/me/Pictures/photos/link.jpg"],
                                                           canonicalizeExistingRegularFile: symlinkingCanonicalizer)).contains("protected folder"))
        // A canonicalizer that fails to resolve ".." must not let the prefix test pass.
        try expectTrue(try deniedReason(allowlist.evaluate(requestedPaths: ["/Users/me/Pictures/photos/../photos-private/secret.jpg"],
                                                           canonicalizeExistingRegularFile: { $0 })).contains("doesn't exist"))
    },
    CoreTestCase(name: "protected folders are denied even inside a granted home folder") {
        let allowlist = UploadFileAllowlist(grants: [homeFolderGrant])
        let reason = try deniedReason(allowlist.evaluate(requestedPaths: ["~/.ssh/id_rsa"],
                                                         canonicalizeExistingRegularFile: makeFakeCanonicalizer(existingFiles: existingFiles)))
        try expectEqual(reason, "“id_rsa” is inside a protected folder and can't be uploaded.")
    },
    CoreTestCase(name: "hidden files inside a folder are denied but allowed when attached one by one") {
        let canonicalizer = makeFakeCanonicalizer(existingFiles: existingFiles)
        let folderOnly = UploadFileAllowlist(grants: [photosFolderGrant])
        for hiddenPath in ["/Users/me/Pictures/photos/.env", "/Users/me/Pictures/photos/.hidden/a.jpg"] {
            try expectTrue(try deniedReason(folderOnly.evaluate(requestedPaths: [hiddenPath], canonicalizeExistingRegularFile: canonicalizer))
                .contains("hidden file"), hiddenPath)
        }
        let directDotfileGrant = UploadFileAllowlist(grants: [UploadFileGrant(canonicalPath: "/Users/me/.env", isDirectory: false, source: .pickedByUser)])
        try expectEqual(directDotfileGrant.evaluate(requestedPaths: ["/Users/me/.env"], canonicalizeExistingRegularFile: canonicalizer),
                        .allowed(canonicalPaths: ["/Users/me/.env"]))
    },
    CoreTestCase(name: "relative, empty, too many and missing paths are denied") {
        let allowlist = UploadFileAllowlist(grants: [photosFolderGrant])
        let canonicalizer = makeFakeCanonicalizer(existingFiles: existingFiles)
        try expectTrue(try deniedReason(allowlist.evaluate(requestedPaths: ["photos/img01.jpg"], canonicalizeExistingRegularFile: canonicalizer))
            .contains("isn't an absolute path"))
        try expectEqual(try deniedReason(allowlist.evaluate(requestedPaths: [], canonicalizeExistingRegularFile: canonicalizer)),
                        "upload_files needs between 1 and 20 file paths.")
        let twentyOnePaths = Array(repeating: "/Users/me/Pictures/photos/img01.jpg", count: 21)
        try expectTrue(try deniedReason(allowlist.evaluate(requestedPaths: twentyOnePaths, canonicalizeExistingRegularFile: canonicalizer))
            .contains("between 1 and 20"))
        let twentyPaths = Array(repeating: "/Users/me/Pictures/photos/img01.jpg", count: 20)
        try expectEqual(allowlist.evaluate(requestedPaths: twentyPaths, canonicalizeExistingRegularFile: canonicalizer),
                        .allowed(canonicalPaths: ["/Users/me/Pictures/photos/img01.jpg"]))
        try expectEqual(try deniedReason(allowlist.evaluate(requestedPaths: ["/Users/me/Pictures/photos/nope.jpg"],
                                                            canonicalizeExistingRegularFile: canonicalizer)),
                        "“nope.jpg” doesn't exist or isn't a regular file.")
        try expectTrue(try deniedReason(UploadFileAllowlist.empty.evaluate(requestedPaths: ["/Users/me/Pictures/photos/img01.jpg"],
                                                                           canonicalizeExistingRegularFile: canonicalizer)).contains("isn't one of"))
    },
    CoreTestCase(name: "duplicates collapse and the request order is kept") {
        let allowlist = UploadFileAllowlist(grants: [photosFolderGrant])
        try expectEqual(allowlist.evaluate(requestedPaths: ["/Users/me/Pictures/photos/img02.jpg", "~/Pictures/photos/img01.jpg",
                                                            "/Users/me/Pictures/photos/img02.jpg"],
                                           canonicalizeExistingRegularFile: makeFakeCanonicalizer(existingFiles: existingFiles)),
                        .allowed(canonicalPaths: ["/Users/me/Pictures/photos/img02.jpg", "/Users/me/Pictures/photos/img01.jpg"]))
    },
    CoreTestCase(name: "the prompt listing caps at 50 files") {
        try expectEqual(UploadFileAllowlist.promptListing(ofFilePaths: ["/a.jpg", "/b.jpg"]), "- /a.jpg\n- /b.jpg")
        try expectEqual(UploadFileAllowlist.promptListing(ofFilePaths: (1...50).map { "/f\($0).jpg" }).split(separator: "\n").count, 50)
        let listing = UploadFileAllowlist.promptListing(ofFilePaths: (1...205).map { "/f\($0).jpg" })
        try expectEqual(listing.split(separator: "\n").count, 51)
        try expectTrue(listing.hasSuffix("- … and 155 more files not listed"), listing)
    },
    CoreTestCase(name: "~/Library, the Dotto profile and browser credential stores are denied, even when granted directly") {
        let canonicalizer = makeFakeCanonicalizer(existingFiles: existingFiles)
        let protectedPaths = [
            "/Users/me/Library/Application Support/Google/Chrome/Default/Login Data",
            "/Users/me/Library/Application Support/Dotto/BrowserProfile/Default/History",
            "/Users/me/Library/Mail/V10/message.emlx", "/Users/me/Library/notes.txt",
            "/Volumes/Data/Chrome/Default/Web Data", "/Volumes/Data/Chrome/Local State", "/Volumes/Data/Chrome/Default/Cookies",
            "/Volumes/Data/Chrome/Default/Login Data For Account", "/Volumes/Data/Application Support/Dotto/key.json",
        ]
        let homeAndVolumeFolders = UploadFileAllowlist(grants: [homeFolderGrant,
                                                                UploadFileGrant.userPicked(canonicalPath: "/Volumes/Data", isDirectory: true)],
                                                       homeDirectoryPath: "/Users/me")
        let everyFileDirectly = UploadFileAllowlist(grants: protectedPaths.map { UploadFileGrant.userPicked(canonicalPath: $0, isDirectory: false) },
                                                    homeDirectoryPath: "/Users/me")
        for protectedPath in protectedPaths {
            for allowlist in [homeAndVolumeFolders, everyFileDirectly] {
                try expectTrue(try deniedReason(allowlist.evaluate(requestedPaths: [protectedPath], canonicalizeExistingRegularFile: canonicalizer))
                    .contains("protected folder"), protectedPath)
            }
        }
        // Another home's Library is protected too, whatever the current home directory is.
        let elsewhereHome = UploadFileAllowlist(grants: [UploadFileGrant.userPicked(canonicalPath: "/Users/me/Library/notes.txt", isDirectory: false)],
                                                homeDirectoryPath: "/var/empty")
        try expectTrue(try deniedReason(elsewhereHome.evaluate(requestedPaths: ["/Users/me/Library/notes.txt"],
                                                               canonicalizeExistingRegularFile: canonicalizer)).contains("protected folder"))
        // A file named like the folder, directly in the home folder, is not inside ~/Library.
        let homeFolderOnly = UploadFileAllowlist(grants: [homeFolderGrant], homeDirectoryPath: "/Users/me")
        try expectEqual(homeFolderOnly.evaluate(requestedPaths: ["/Users/me/Documents/report.pdf"], canonicalizeExistingRegularFile: canonicalizer),
                        .allowed(canonicalPaths: ["/Users/me/Documents/report.pdf"]))
    },
    CoreTestCase(name: "folder grants count only when picked as folders") {
        try expectEqual(photosFolderGrant.source, .pickedFolderByUser)
        try expectEqual(UploadFileGrant.userPicked(canonicalPath: "/Users/me/.env", isDirectory: false).source, .pickedByUser)
        let unhonoredFolderGrant = UploadFileGrant(canonicalPath: "/Users/me/Pictures/photos", isDirectory: true, source: .pickedByUser)
        let allowlist = UploadFileAllowlist(grants: [unhonoredFolderGrant])
        try expectEqual(allowlist.grantsHonoredForUpload, [])
        try expectTrue(try deniedReason(allowlist.evaluate(requestedPaths: ["/Users/me/Pictures/photos/img01.jpg"],
                                                           canonicalizeExistingRegularFile: makeFakeCanonicalizer(existingFiles: existingFiles)))
            .contains("isn't one of"))
    },
    CoreTestCase(name: "several files share a parent folder only when they all sit in one folder") {
        try expectEqual(UploadFileAllowlist.sharedParentFolderPath(ofCanonicalPaths: ["/Users/me/Pictures/photos/img01.jpg",
                                                                                      "/Users/me/Pictures/photos/img02.jpg"]),
                        "/Users/me/Pictures/photos")
        try expectEqual(UploadFileAllowlist.sharedParentFolderPath(ofCanonicalPaths: ["/Users/me/Pictures/photos/img01.jpg"]),
                        "/Users/me/Pictures/photos")
        try expectEqual(UploadFileAllowlist.sharedParentFolderPath(ofCanonicalPaths: ["/Users/me/Pictures/photos/img01.jpg",
                                                                                      "/Users/me/Pictures/photos/trip/img03.jpg"]), nil)
        try expectEqual(UploadFileAllowlist.sharedParentFolderPath(ofCanonicalPaths: []), nil)
    },
    CoreTestCase(name: "the coverage description names attached files and picked folders, never full paths") {
        let coverage = UploadFileAllowlist(grants: [reportFileGrant, photosFolderGrant]).userFacingCoverageDescription
        try expectEqual(coverage, "“report.pdf” and files in the folder “photos”")
        try expectTrue(!coverage.contains("/Users"), coverage)
        try expectEqual(UploadFileAllowlist.empty.userFacingCoverageDescription, "nothing (no files are attached)")
        let manyFiles = UploadFileAllowlist(grants: (1...7).map { UploadFileGrant.userPicked(canonicalPath: "/Users/me/f\($0).pdf", isDirectory: false) })
        try expectEqual(manyFiles.userFacingCoverageDescription, "“f1.pdf”, “f2.pdf”, “f3.pdf”, “f4.pdf”, “f5.pdf” and 2 more")
    },
    CoreTestCase(name: "Users/<name>/Library is protected at any depth and in the data volume's spelling") {
        let libraryPaths = ["/Volumes/Backup/Users/me/Library/Mail/V10/message.emlx",
                            "/System/Volumes/Data/Users/me/Library/Mail/V10/message.emlx",
                            "/Volumes/Old Mac/Users/someone/Library/Safari/History.db"]
        let allowlist = UploadFileAllowlist(grants: [UploadFileGrant.userPicked(canonicalPath: "/Volumes/Backup/Users", isDirectory: true),
                                                     UploadFileGrant.userPicked(canonicalPath: "/Users/me", isDirectory: true),
                                                     UploadFileGrant.userPicked(canonicalPath: "/Volumes/Old Mac/Users/someone", isDirectory: true)],
                                            homeDirectoryPath: "/Users/me")
        for libraryPath in libraryPaths {
            let reason = try deniedReason(allowlist.evaluate(requestedPaths: [libraryPath], canonicalizeExistingRegularFile: { $0 }))
            try expectTrue(reason.contains("protected folder"), "\(libraryPath): \(reason)")
        }
    },
    CoreTestCase(name: "the data volume's spelling of a granted file or folder matches the grant") {
        let allowlist = UploadFileAllowlist(grants: [photosFolderGrant, reportFileGrant], homeDirectoryPath: "/Users/me")
        try expectEqual(allowlist.evaluate(requestedPaths: ["/System/Volumes/Data/Users/me/Documents/report.pdf",
                                                            "/System/Volumes/Data/Users/me/Pictures/photos/img01.jpg"],
                                           canonicalizeExistingRegularFile: { $0 }),
                        .allowed(canonicalPaths: ["/Users/me/Documents/report.pdf", "/Users/me/Pictures/photos/img01.jpg"]))
        let dataVolumeGrant = UploadFileAllowlist(grants: [UploadFileGrant.userPicked(canonicalPath: "/System/Volumes/Data/Users/me/Pictures/photos",
                                                                                      isDirectory: true)], homeDirectoryPath: "/Users/me")
        try expectEqual(dataVolumeGrant.evaluate(requestedPaths: ["/Users/me/Pictures/photos/img01.jpg"], canonicalizeExistingRegularFile: { $0 }),
                        .allowed(canonicalPaths: ["/Users/me/Pictures/photos/img01.jpg"]))
    },
    CoreTestCase(name: "grants of the disk, /Users, /Volumes and a whole volume are refused") {
        for rootPath in ["/", "/Users", "/Users/", "/Volumes", "/Volumes/Backup", "/System/Volumes/Data", "/System/Volumes/Data/Users"] {
            try expectTrue(UploadFileAllowlist.isRefusedGrantRoot(rootPath), rootPath)
            let rootGrantAllowlist = UploadFileAllowlist(grants: [UploadFileGrant.userPicked(canonicalPath: rootPath, isDirectory: true)],
                                                         homeDirectoryPath: "/Users/me")
            try expectEqual(rootGrantAllowlist.grantsHonoredForUpload, [], rootPath)
            let reason = try deniedReason(rootGrantAllowlist.evaluate(requestedPaths: ["/Users/me/Documents/report.pdf"],
                                                                      canonicalizeExistingRegularFile: { $0 }))
            try expectTrue(reason.contains("isn't one of the files"), "\(rootPath): \(reason)")
        }
        for specificPath in ["/Users/me", "/Volumes/Backup/Photos", "/System/Volumes/Data/Users/me/Pictures"] {
            try expectTrue(!UploadFileAllowlist.isRefusedGrantRoot(specificPath), specificPath)
        }
    },
])
