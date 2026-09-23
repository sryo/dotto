import Foundation

struct CoreTestFailure: Error, CustomStringConvertible { let description: String }
struct CoreTestCase { let name: String; let run: () async throws -> Void }
struct CoreTestSuite { let name: String; let testCases: [CoreTestCase] }

/// Every file a test writes (audit logs, routine libraries) lives under this one directory, removed after the run.
let coreTestScratchDirectoryURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("dotto-core-tests-\(UUID().uuidString)", isDirectory: true)

/// A fresh, not yet created directory inside the run's scratch directory.
func makeScratchDirectoryURL(prefix directoryNamePrefix: String) -> URL {
    coreTestScratchDirectoryURL.appendingPathComponent("\(directoryNamePrefix)-\(UUID().uuidString)", isDirectory: true)
}

func runCoreTestSuites(_ testSuites: [CoreTestSuite]) async -> Int {
    var failureCount = 0
    var testCaseCount = 0
    for testSuite in testSuites {
        print("\(testSuite.name)")
        for testCase in testSuite.testCases {
            testCaseCount += 1
            do {
                try await testCase.run()
                print("  ✓ \(testCase.name)")
            } catch {
                failureCount += 1
                print("  ✗ \(testCase.name): \(error)")
            }
        }
    }
    try? FileManager.default.removeItem(at: coreTestScratchDirectoryURL)
    print("\n\(testCaseCount - failureCount) passed, \(failureCount) failed (\(testCaseCount) tests in \(testSuites.count) suites)")
    return failureCount
}

func expectEqual<Value: Equatable>(_ actualValue: Value, _ expectedValue: Value, _ context: String = "",
                                   file: StaticString = #fileID, line: UInt = #line) throws {
    guard actualValue == expectedValue else {
        throw CoreTestFailure(description: "\(file):\(line) \(context)\n      expected: \(expectedValue)\n      actual:   \(actualValue)")
    }
}

func expectTrue(_ condition: Bool, _ context: String = "", file: StaticString = #fileID, line: UInt = #line) throws {
    guard condition else { throw CoreTestFailure(description: "\(file):\(line) expected true. \(context)") }
}

func unwrapOrFail<Value>(_ optionalValue: Value?, _ context: String = "", file: StaticString = #fileID, line: UInt = #line) throws -> Value {
    guard let optionalValue else { throw CoreTestFailure(description: "\(file):\(line) unexpected nil. \(context)") }
    return optionalValue
}

func expectThrowsError(_ context: String = "", file: StaticString = #fileID, line: UInt = #line,
                       _ throwingOperation: () throws -> Void) throws -> Error {
    do {
        try throwingOperation()
    } catch {
        return error
    }
    throw CoreTestFailure(description: "\(file):\(line) expected an error to be thrown. \(context)")
}
