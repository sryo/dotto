import Foundation

struct BoundedProcessResult: Equatable, Sendable {
    var exitStatus: Int32
    var standardOutputData: Data
    var standardErrorData: Data
    var timedOut: Bool
    var wasStopped: Bool
}

enum BoundedProcessRunnerError: Error, Equatable, LocalizedError {
    case couldNotLaunch(String)

    var errorDescription: String? {
        switch self {
        case .couldNotLaunch(let launchFailureDescription): return "Dotto couldn't start the helper: \(launchFailureDescription)"
        }
    }
}

/// Runs one of two fixed system tools as a child process: an argument array (never a shell), a minimal environment,
/// capped output, a hard deadline, and Stop. The child is spawned (posix_spawn) as the leader of its own process group,
/// and on Stop or timeout the whole group gets SIGTERM, then SIGKILL a second later, so neither a hung script nor
/// anything it started can keep running or wedge Dotto (invariant 10).
enum BoundedProcessRunner {
    static let osascriptExecutablePath = "/usr/bin/osascript"
    static let shortcutsExecutablePath = "/usr/bin/shortcuts"
    static let allowedExecutablePaths: Set<String> = [osascriptExecutablePath, shortcutsExecutablePath]
    static let abortPollIntervalNanoseconds: UInt64 = 100_000_000
    static let killGraceSeconds: TimeInterval = 1
    /// After the process exits, how long to wait for its pipes to drain before giving up on the rest.
    static let pipeDrainGraceSeconds: TimeInterval = 1

    static func run(executablePath: String, arguments: [String], standardInputData: Data?, workingDirectoryURL: URL,
                    timeoutSeconds: TimeInterval, abortSignal: TaskAbortSignal,
                    standardOutputByteLimit: Int, standardErrorByteLimit: Int) async throws -> BoundedProcessResult {
        precondition(allowedExecutablePaths.contains(executablePath), "BoundedProcessRunner only runs osascript and shortcuts")
        try abortSignal.throwIfAborted()

        let standardInputPipe = try makePipe()
        let standardOutputPipe = try makePipe()
        let standardErrorPipe = try makePipe()
        let spawnedProcessIdentifier: pid_t
        do {
            spawnedProcessIdentifier = try spawnInOwnProcessGroup(
                executablePath: executablePath, arguments: arguments, workingDirectoryPath: workingDirectoryURL.path,
                standardInputReadDescriptor: standardInputData == nil ? nil : standardInputPipe.readDescriptor,
                standardOutputWriteDescriptor: standardOutputPipe.writeDescriptor,
                standardErrorWriteDescriptor: standardErrorPipe.writeDescriptor)
        } catch {
            for descriptor in [standardInputPipe.readDescriptor, standardInputPipe.writeDescriptor, standardOutputPipe.readDescriptor,
                               standardOutputPipe.writeDescriptor, standardErrorPipe.readDescriptor, standardErrorPipe.writeDescriptor] {
                close(descriptor)
            }
            throw error
        }
        // The child holds its own copies; the parent keeps only its ends, so end-of-file arrives when the child exits.
        close(standardInputPipe.readDescriptor)
        close(standardOutputPipe.writeDescriptor)
        close(standardErrorPipe.writeDescriptor)

        let processExitState = ProcessExitState()
        DispatchQueue.global(qos: .utility).async {
            var waitStatus: Int32 = 0
            var waitResult: pid_t
            repeat { waitResult = waitpid(spawnedProcessIdentifier, &waitStatus, 0) } while waitResult == -1 && errno == EINTR
            processExitState.markExited(terminationStatus: terminationStatus(fromWaitStatus: waitStatus))
        }

        let standardOutputCollector = CappedPipeCollector(byteLimit: standardOutputByteLimit)
        let standardErrorCollector = CappedPipeCollector(byteLimit: standardErrorByteLimit)
        standardOutputCollector.startDraining(FileHandle(fileDescriptor: standardOutputPipe.readDescriptor, closeOnDealloc: true))
        standardErrorCollector.startDraining(FileHandle(fileDescriptor: standardErrorPipe.readDescriptor, closeOnDealloc: true))
        let standardInputHandle = FileHandle(fileDescriptor: standardInputPipe.writeDescriptor, closeOnDealloc: true)
        if let standardInputData {
            // Written on a background queue: a script larger than the pipe buffer would otherwise block until the
            // child reads it. A child that exits early closes its end, and the write fails quietly (SIGPIPE is ignored
            // for the write by F_SETNOSIGPIPE).
            _ = fcntl(standardInputPipe.writeDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global(qos: .userInitiated).async {
                try? standardInputHandle.write(contentsOf: standardInputData)
                try? standardInputHandle.close()
            }
        } else {
            try? standardInputHandle.close()
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var timedOut = false
        var wasStopped = false
        while !processExitState.hasExited {
            if abortSignal.isAborted { wasStopped = true; break }
            if Date() >= deadline { timedOut = true; break }
            try? await Task.sleep(nanoseconds: abortPollIntervalNanoseconds)
        }
        if timedOut || wasStopped {
            await terminateProcessGroup(ledBy: spawnedProcessIdentifier, processExitState: processExitState)
        }
        await waitUntil(deadline: Date().addingTimeInterval(pipeDrainGraceSeconds)) {
            standardOutputCollector.isFinished && standardErrorCollector.isFinished
        }
        return BoundedProcessResult(
            exitStatus: processExitState.terminationStatus ?? -1,
            standardOutputData: standardOutputCollector.collectedData,
            standardErrorData: standardErrorCollector.collectedData,
            timedOut: timedOut, wasStopped: wasStopped)
    }

    private struct PipeDescriptors {
        var readDescriptor: Int32
        var writeDescriptor: Int32
    }

    private static func makePipe() throws -> PipeDescriptors {
        var pipeDescriptors: [Int32] = [-1, -1]
        guard pipe(&pipeDescriptors) == 0 else {
            throw BoundedProcessRunnerError.couldNotLaunch(String(cString: strerror(errno)))
        }
        return PipeDescriptors(readDescriptor: pipeDescriptors[0], writeDescriptor: pipeDescriptors[1])
    }

    /// posix_spawn with the child as the leader of a new process group (POSIX_SPAWN_SETPGROUP, group 0 = its own pid),
    /// default signal handling, an empty signal mask, and every descriptor closed except the three standard ones
    /// (POSIX_SPAWN_CLOEXEC_DEFAULT), so it inherits nothing else of Dotto's.
    private static func spawnInOwnProcessGroup(executablePath: String, arguments: [String], workingDirectoryPath: String,
                                               standardInputReadDescriptor: Int32?, standardOutputWriteDescriptor: Int32,
                                               standardErrorWriteDescriptor: Int32) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        if let standardInputReadDescriptor {
            posix_spawn_file_actions_adddup2(&fileActions, standardInputReadDescriptor, STDIN_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&fileActions, standardOutputWriteDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, standardErrorWriteDescriptor, STDERR_FILENO)
        posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectoryPath)

        var spawnAttributes: posix_spawnattr_t?
        posix_spawnattr_init(&spawnAttributes)
        defer { posix_spawnattr_destroy(&spawnAttributes) }
        posix_spawnattr_setflags(&spawnAttributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                         | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&spawnAttributes, 0)
        var emptySignalSet = sigset_t()
        sigemptyset(&emptySignalSet)
        posix_spawnattr_setsigmask(&spawnAttributes, &emptySignalSet)
        var defaultedSignalSet = sigset_t()
        sigemptyset(&defaultedSignalSet)
        for defaultedSignal in [SIGPIPE, SIGTERM, SIGINT, SIGHUP] { sigaddset(&defaultedSignalSet, defaultedSignal) }
        posix_spawnattr_setsigdefault(&spawnAttributes, &defaultedSignalSet)

        let environmentEntries = ["LANG=" + (ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8")]
        let argumentVector = ([executablePath] + arguments).map { strdup($0) } + [nil]
        let environmentVector = environmentEntries.map { strdup($0) } + [nil]
        defer {
            for argumentPointer in argumentVector { free(argumentPointer) }
            for environmentPointer in environmentVector { free(environmentPointer) }
        }
        var spawnedProcessIdentifier: pid_t = 0
        let spawnResult = posix_spawn(&spawnedProcessIdentifier, executablePath, &fileActions, &spawnAttributes,
                                      argumentVector, environmentVector)
        guard spawnResult == 0 else {
            throw BoundedProcessRunnerError.couldNotLaunch(String(cString: strerror(spawnResult)))
        }
        return spawnedProcessIdentifier
    }

    /// The exit code for a normal exit, else the signal's number (what Foundation's Process reports).
    private static func terminationStatus(fromWaitStatus waitStatus: Int32) -> Int32 {
        let signalBits = waitStatus & 0x7f
        return signalBits == 0 ? (waitStatus >> 8) & 0xff : signalBits
    }

    /// SIGTERM to the whole group, then SIGKILL to it after a grace second. The group id is the leader's pid; once the
    /// group is empty, kill fails harmlessly with ESRCH.
    private static func terminateProcessGroup(ledBy processIdentifier: pid_t, processExitState: ProcessExitState) async {
        guard processIdentifier > 0 else { return }
        kill(-processIdentifier, SIGTERM)
        await waitUntil(deadline: Date().addingTimeInterval(killGraceSeconds)) { processExitState.hasExited }
        kill(-processIdentifier, SIGKILL)
        await waitUntil(deadline: Date().addingTimeInterval(killGraceSeconds)) { processExitState.hasExited }
    }

    private static func waitUntil(deadline: Date, condition: () -> Bool) async {
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

private final class ProcessExitState: @unchecked Sendable {
    private let stateLock = NSLock()
    private var recordedTerminationStatus: Int32?

    func markExited(terminationStatus: Int32) { stateLock.withLock { recordedTerminationStatus = terminationStatus } }
    var hasExited: Bool { stateLock.withLock { recordedTerminationStatus != nil } }
    var terminationStatus: Int32? { stateLock.withLock { recordedTerminationStatus } }
}

/// Reads a pipe to its end on a background queue, keeping at most `byteLimit` bytes and discarding the rest, so the
/// child never blocks on a full pipe and a chatty script can't grow Dotto's memory.
private final class CappedPipeCollector: @unchecked Sendable {
    private let stateLock = NSLock()
    private let byteLimit: Int
    private var bufferedData = Data()
    private var reachedEndOfFile = false

    init(byteLimit: Int) { self.byteLimit = byteLimit }

    var collectedData: Data { stateLock.withLock { bufferedData } }
    var isFinished: Bool { stateLock.withLock { reachedEndOfFile } }

    func startDraining(_ readingHandle: FileHandle) {
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let chunkData = readingHandle.availableData
                if chunkData.isEmpty { break }
                stateLock.withLock {
                    let remainingCapacity = byteLimit - bufferedData.count
                    if remainingCapacity > 0 { bufferedData.append(chunkData.prefix(remainingCapacity)) }
                }
            }
            stateLock.withLock { reachedEndOfFile = true }
        }
    }
}
