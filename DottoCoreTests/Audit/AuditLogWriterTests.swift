import Foundation

private func makeTemporaryLogsDirectory() -> URL {
    makeScratchDirectoryURL(prefix: "audit")
}

private func readJSONLines(at logFileURL: URL) throws -> [[String: Any]] {
    let logText = try String(contentsOf: logFileURL, encoding: .utf8)
    try expectTrue(logText.hasSuffix("\n"), "every entry ends with a newline")
    return try logText.split(separator: "\n").map { logLine in
        try unwrapOrFail(try JSONSerialization.jsonObject(with: Data(logLine.utf8)) as? [String: Any], "line is a JSON object")
    }
}

let auditLogWriterTestSuite = CoreTestSuite(name: "AuditLogWriter", testCases: [
    CoreTestCase(name: "writes one sorted-key JSON object per line into <dir>/<task>.jsonl") {
        let logsDirectoryURL = makeTemporaryLogsDirectory()
        defer { try? FileManager.default.removeItem(at: logsDirectoryURL) }
        let auditLogWriter = try AuditLogWriter(taskIdentifier: "20260922-153012-ab12cd", logsDirectoryURL: logsDirectoryURL)
        try expectEqual(auditLogWriter.logFileURL.lastPathComponent, "20260922-153012-ab12cd.jsonl")

        auditLogWriter.append(eventKind: .taskStarted, itemIdentifier: nil, message: "Task started", details: ["command": "rename"])
        auditLogWriter.append(AuditLogEntry(timestamp: Date(timeIntervalSince1970: 1_790_000_000.25), taskIdentifier: "20260922-153012-ab12cd",
                                            itemIdentifier: "item-1", eventKind: .toolCall, message: "click",
                                            details: ["element": "e12", "long": String(repeating: "x", count: 600)]))

        let logLines = try readJSONLines(at: auditLogWriter.logFileURL)
        try expectEqual(logLines.count, 2)
        try expectEqual(logLines[0]["eventKind"] as? String, "taskStarted")
        try expectTrue(logLines[0]["itemIdentifier"] == nil, "nil item id is omitted")
        try expectEqual(logLines[1]["itemIdentifier"] as? String, "item-1")
        try expectEqual(logLines[1]["timestamp"] as? String, "2026-09-21T14:13:20.250Z")
        let secondLineDetails = try unwrapOrFail(logLines[1]["details"] as? [String: String])
        try expectEqual(secondLineDetails["long"]?.count, AuditLogWriter.maximumDetailValueLength + 1)

        let rawSecondLine = try String(contentsOf: auditLogWriter.logFileURL, encoding: .utf8).split(separator: "\n")[1]
        try expectTrue(rawSecondLine.hasPrefix(#"{"details":"#), "keys are sorted")
    },
    CoreTestCase(name: "a second writer for the same task appends instead of truncating") {
        let logsDirectoryURL = makeTemporaryLogsDirectory()
        defer { try? FileManager.default.removeItem(at: logsDirectoryURL) }
        let firstWriter = try AuditLogWriter(taskIdentifier: "task-append", logsDirectoryURL: logsDirectoryURL)
        firstWriter.append(eventKind: .taskStarted, itemIdentifier: nil, message: "one", details: [:])
        let secondWriter = try AuditLogWriter(taskIdentifier: "task-append", logsDirectoryURL: logsDirectoryURL)
        secondWriter.append(eventKind: .taskFinished, itemIdentifier: nil, message: "two", details: [:])
        try expectEqual(try readJSONLines(at: secondWriter.logFileURL).compactMap { $0["message"] as? String }, ["one", "two"])
    },
    CoreTestCase(name: "entries decode back with the same values") {
        let logsDirectoryURL = makeTemporaryLogsDirectory()
        defer { try? FileManager.default.removeItem(at: logsDirectoryURL) }
        let auditLogWriter = try AuditLogWriter(taskIdentifier: "task-decode", logsDirectoryURL: logsDirectoryURL)
        auditLogWriter.append(eventKind: .safetyDecision, itemIdentifier: "item-3", message: "confirm", details: ["verdict": "allowOnce"])
        let logLine = try String(contentsOf: auditLogWriter.logFileURL, encoding: .utf8).split(separator: "\n")[0]
        let lineObject = try unwrapOrFail(try JSONSerialization.jsonObject(with: Data(logLine.utf8)) as? [String: Any])
        try expectEqual(lineObject["taskIdentifier"] as? String, "task-decode")
        try expectEqual(lineObject["eventKind"] as? String, "safetyDecision")
        try expectEqual((lineObject["details"] as? [String: String])?["verdict"], "allowOnce")
    },
    CoreTestCase(name: "default directory is ~/Library/Logs/Dotto") {
        try expectTrue(AuditLogWriter.defaultLogsDirectoryURL.path.hasSuffix("/Library/Logs/Dotto"))
    },
    CoreTestCase(name: "log directory is 0700 and log files are 0600") {
        let logsDirectoryURL = makeTemporaryLogsDirectory()
        defer { try? FileManager.default.removeItem(at: logsDirectoryURL) }
        let auditLogWriter = try AuditLogWriter(taskIdentifier: "task-permissions", logsDirectoryURL: logsDirectoryURL)
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: logsDirectoryURL.path)[.posixPermissions] as? Int
        let filePermissions = try FileManager.default.attributesOfItem(atPath: auditLogWriter.logFileURL.path)[.posixPermissions] as? Int
        try expectEqual(directoryPermissions, 0o700)
        try expectEqual(filePermissions, 0o600)
    },
    CoreTestCase(name: "registered typed text is redacted from messages and details, longest first") {
        let logsDirectoryURL = makeTemporaryLogsDirectory()
        defer { try? FileManager.default.removeItem(at: logsDirectoryURL) }
        let auditLogWriter = try AuditLogWriter(taskIdentifier: "task-redaction", logsDirectoryURL: logsDirectoryURL)
        auditLogWriter.registerTypedTextForRedaction("hunter")
        auditLogWriter.registerTypedTextForRedaction("hunter2 is my password")
        auditLogWriter.registerTypedTextForRedaction("ok")
        auditLogWriter.append(eventKind: .toolResult, itemIdentifier: "item-1", message: "value=\"hunter2 is my password\" ok",
                              details: ["summary": "typed hunter"])
        let logText = try String(contentsOf: auditLogWriter.logFileURL, encoding: .utf8)
        try expectTrue(!logText.contains("hunter"), logText)
        try expectTrue(logText.contains(AuditLogRedaction.fingerprint(of: "hunter2 is my password")), logText)
        try expectTrue(logText.contains(AuditLogRedaction.fingerprint(of: "hunter")), logText)
        try expectTrue(logText.contains("\" ok"), "strings shorter than the minimum are left alone")
    },
    CoreTestCase(name: "SHA-256 matches the FIPS test vectors") {
        try expectEqual(SHA256Digest.hexDigest(of: Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        try expectEqual(SHA256Digest.hexDigest(of: Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        try expectEqual(SHA256Digest.hexDigest(of: Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        try expectEqual(AuditLogRedaction.fingerprint(of: "abc"), "[typed sha256:ba7816bf8f01 len=3]")
    },
])
