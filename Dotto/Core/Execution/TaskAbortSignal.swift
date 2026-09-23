import Foundation

final class TaskAbortSignal: @unchecked Sendable {
    private let stateLock = NSLock()
    private var abortWasRequested = false

    init() {}

    func abort() {
        stateLock.lock()
        abortWasRequested = true
        stateLock.unlock()
    }

    var isAborted: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return abortWasRequested
    }

    func throwIfAborted() throws {
        if isAborted { throw ActionBackendError.aborted }
    }
}
