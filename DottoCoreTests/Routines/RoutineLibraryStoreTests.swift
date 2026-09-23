import Foundation

private func makeTemporaryRoutinesDirectory() -> URL {
    makeScratchDirectoryURL(prefix: "routines")
}

private func makeSignedLibraryStore(directoryURL: URL) -> RoutineLibraryStore {
    RoutineLibraryStore(directoryURL: directoryURL, signingKeyProvider: FixedRoutineSigningKeyProvider())
}

/// Loaded routines carry their signature; the fixtures compare without it.
private func unsigned(_ routines: [Routine]) -> [Routine] {
    routines.map { routine in
        var unsignedRoutine = routine
        unsignedRoutine.integritySignature = nil
        return unsignedRoutine
    }
}

private func skippedReason(_ fileName: String, in libraryContents: RoutineLibraryContents) -> String? {
    libraryContents.skippedFiles.first { $0.fileName == fileName }?.reason
}

let routineLibraryStoreTestSuite = CoreTestSuite(name: "RoutineLibraryStore", testCases: [
    CoreTestCase(name: "the signature is over the same canonical bytes as before, so saved routines keep loading") {
        // Computed with the encoder options routines have always been signed with; a change here invalidates every
        // routine users have saved.
        let goldenRoutine = makeFixtureRoutine(identifier: "routine-golden", updatedAt: Date(timeIntervalSince1970: 1_000))
        try expectEqual(try RoutineIntegritySigning.signature(for: goldenRoutine, signingKey: FixedRoutineSigningKeyProvider().signingKey),
                        "1160f123f72aba7ec6c13a9ba683fbf36c51e7da1ef33cf721c804068141f675")
    },
    CoreTestCase(name: "save, load and delete round trip, newest first") {
        let directoryURL = makeTemporaryRoutinesDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let libraryStore = makeSignedLibraryStore(directoryURL: directoryURL)
        try expectEqual(libraryStore.loadRoutineLibrary().routines, [])
        let olderRoutine = makeFixtureRoutine(identifier: "routine-older", updatedAt: Date(timeIntervalSince1970: 1_000))
        let newerRoutine = makeFixtureRoutine(identifier: "routine-newer", updatedAt: Date(timeIntervalSince1970: 2_000))
        try libraryStore.save(olderRoutine)
        try libraryStore.save(newerRoutine)
        try expectEqual(unsigned(libraryStore.loadRoutineLibrary().routines), [newerRoutine, olderRoutine])
        try expectTrue(libraryStore.loadRoutineLibrary().routines.allSatisfy { $0.integritySignature?.count == 64 })

        let savedFilePath = directoryURL.appendingPathComponent("routine-newer.json").path
        let filePermissions = try FileManager.default.attributesOfItem(atPath: savedFilePath)[.posixPermissions] as? Int
        try expectEqual(filePermissions, 0o600)

        try libraryStore.deleteRoutine(withIdentifier: "routine-newer")
        try expectEqual(unsigned(libraryStore.loadRoutineLibrary().routines), [olderRoutine])
    },
    CoreTestCase(name: "corrupt files and other format versions are skipped with reasons") {
        let directoryURL = makeTemporaryRoutinesDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let libraryStore = makeSignedLibraryStore(directoryURL: directoryURL)
        let keptRoutine = makeFixtureRoutine(identifier: "routine-kept", updatedAt: Date(timeIntervalSince1970: 1_000))
        var futureRoutine = makeFixtureRoutine(identifier: "routine-future", updatedAt: Date(timeIntervalSince1970: 3_000))
        futureRoutine.formatVersion = Routine.currentFormatVersion + 1
        try libraryStore.save(keptRoutine)
        try libraryStore.save(futureRoutine)
        try Data("{not json".utf8).write(to: directoryURL.appendingPathComponent("routine-corrupt.json"))
        try Data(#"{"formatVersion":1,"name":"half"}"#.utf8).write(to: directoryURL.appendingPathComponent("routine-half.json"))
        let libraryContents = libraryStore.loadRoutineLibrary()
        try expectEqual(unsigned(libraryContents.routines), [keptRoutine])
        try expectEqual(skippedReason("routine-future.json", in: libraryContents), "Saved by a different version of Dotto (format 2).")
        try expectEqual(skippedReason("routine-corrupt.json", in: libraryContents), "Not an Dotto routine file.")
        try expectEqual(skippedReason("routine-half.json", in: libraryContents), "The file is damaged and can't be read.")
    },
    CoreTestCase(name: "unsigned, tampered and foreign-key files are refused") {
        let directoryURL = makeTemporaryRoutinesDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let libraryStore = makeSignedLibraryStore(directoryURL: directoryURL)
        try libraryStore.save(makeFixtureRoutine(identifier: "routine-tampered", updatedAt: Date(timeIntervalSince1970: 1)))
        let tamperedFileURL = directoryURL.appendingPathComponent("routine-tampered.json")
        let tamperedText = try String(contentsOf: tamperedFileURL, encoding: .utf8)
            .replacingOccurrences(of: "rename them", with: "delete everything")
        try Data(tamperedText.utf8).write(to: tamperedFileURL)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(makeFixtureRoutine(identifier: "routine-unsigned", updatedAt: Date(timeIntervalSince1970: 1)))
            .write(to: directoryURL.appendingPathComponent("routine-unsigned.json"))

        let otherKeyStore = RoutineLibraryStore(directoryURL: directoryURL,
                                                signingKeyProvider: FixedRoutineSigningKeyProvider(signingKey: Data(repeating: 7, count: 32)))
        try otherKeyStore.save(makeFixtureRoutine(identifier: "routine-foreign", updatedAt: Date(timeIntervalSince1970: 1)))

        let libraryContents = libraryStore.loadRoutineLibrary()
        try expectEqual(libraryContents.routines, [])
        try expectEqual(skippedReason("routine-tampered.json", in: libraryContents), "Changed outside Dotto: its signature doesn't match.")
        try expectEqual(skippedReason("routine-unsigned.json", in: libraryContents), "Not signed by Dotto on this Mac.")
        try expectEqual(skippedReason("routine-foreign.json", in: libraryContents), "Changed outside Dotto: its signature doesn't match.")
    },
    CoreTestCase(name: "a signed file renamed to another identifier, a symlink, or a store without a key is refused") {
        let directoryURL = makeTemporaryRoutinesDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let libraryStore = makeSignedLibraryStore(directoryURL: directoryURL)
        try libraryStore.save(makeFixtureRoutine(identifier: "routine-real", updatedAt: Date(timeIntervalSince1970: 1)))
        let realFileURL = directoryURL.appendingPathComponent("routine-real.json")
        try FileManager.default.copyItem(at: realFileURL, to: directoryURL.appendingPathComponent("routine-renamed.json"))
        let outsideFileURL = makeScratchDirectoryURL(prefix: "outside").appendingPathExtension("json")
        try FileManager.default.copyItem(at: realFileURL, to: outsideFileURL)
        defer { try? FileManager.default.removeItem(at: outsideFileURL) }
        try FileManager.default.createSymbolicLink(at: directoryURL.appendingPathComponent("routine-link.json"), withDestinationURL: outsideFileURL)

        let libraryContents = libraryStore.loadRoutineLibrary()
        try expectEqual(libraryContents.routines.map(\.routineIdentifier), ["routine-real"])
        try expectEqual(skippedReason("routine-renamed.json", in: libraryContents), "The file name doesn't match the routine inside it.")
        try expectEqual(skippedReason("routine-link.json", in: libraryContents), "It is a symbolic link, not a routine file.")

        let keylessContents = RoutineLibraryStore(directoryURL: directoryURL).loadRoutineLibrary()
        try expectEqual(keylessContents.routines, [])
        try expectEqual(keylessContents.skippedFiles.count, 3)
        _ = try expectThrowsError("saving without a key") {
            try RoutineLibraryStore(directoryURL: directoryURL).save(makeFixtureRoutine(identifier: "routine-new", updatedAt: Date()))
        }
    },
    CoreTestCase(name: "a routine without a bundle identifier is neither saved nor loaded") {
        let directoryURL = makeTemporaryRoutinesDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        var nameOnlyRoutine = makeFixtureRoutine(identifier: "routine-name-only", updatedAt: Date(timeIntervalSince1970: 1))
        nameOnlyRoutine.targetApplicationBundleIdentifier = nil
        let libraryStore = makeSignedLibraryStore(directoryURL: directoryURL)
        _ = try expectThrowsError("saving a name-only routine") { try libraryStore.save(nameOnlyRoutine) }

        // Signed by hand, as a pre-existing file would be.
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        nameOnlyRoutine.integritySignature = try RoutineIntegritySigning.signature(for: nameOnlyRoutine,
                                                                                   signingKey: FixedRoutineSigningKeyProvider().signingKey)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(nameOnlyRoutine).write(to: directoryURL.appendingPathComponent("routine-name-only.json"))
        let libraryContents = libraryStore.loadRoutineLibrary()
        try expectEqual(libraryContents.routines, [])
        try expectEqual(skippedReason("routine-name-only.json", in: libraryContents), "It doesn't name its app's bundle identifier.")
    },
    CoreTestCase(name: "HMAC-SHA256 matches the RFC 4231 test vector") {
        let authenticationCode = HMACSHA256.authenticationCode(for: Data("Hi There".utf8), key: Data(repeating: 0x0b, count: 20))
        try expectEqual(authenticationCode.map { String(format: "%02x", $0) }.joined(),
                        "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
        let longKeyCode = HMACSHA256.authenticationCode(for: Data("Test Using Larger Than Block-Size Key - Hash Key First".utf8),
                                                        key: Data(repeating: 0xaa, count: 131))
        try expectEqual(longKeyCode.map { String(format: "%02x", $0) }.joined(),
                        "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
    },
    CoreTestCase(name: "identifiers that could escape the directory are rejected") {
        let directoryURL = makeTemporaryRoutinesDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let libraryStore = makeSignedLibraryStore(directoryURL: directoryURL)
        for invalidIdentifier in ["../evil", "Routine", "", "a/b", "routine-x\n"] {
            _ = try expectThrowsError(invalidIdentifier) {
                try libraryStore.save(makeFixtureRoutine(identifier: invalidIdentifier, updatedAt: Date()))
            }
            _ = try expectThrowsError(invalidIdentifier) { try libraryStore.deleteRoutine(withIdentifier: invalidIdentifier) }
        }
        try expectTrue(!FileManager.default.fileExists(atPath: directoryURL.deletingLastPathComponent().appendingPathComponent("evil.json").path))
    },
])
