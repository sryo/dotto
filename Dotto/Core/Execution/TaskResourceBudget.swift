import Foundation

struct TaskCeilingReachedError: Error, Equatable {
    enum Ceiling: Equatable { case wallClock, modelTurns, inputTokens }
    var ceiling: Ceiling
    var userFacingDescription: String
}

/// Task-wide hard ceilings shared by every Claude conversation of one task (planning, compiling a taught routine
/// and every item of the run), so a looping or runaway task stops with a clear reason instead of burning time and
/// tokens until the per-conversation limits add up.
final class TaskResourceBudget: @unchecked Sendable {
    private let safetyLimits: SafetyLimits
    private let currentDate: () -> Date
    private let stateLock = NSLock()
    private var modelTurnsUsedSoFar = 0
    private var inputTokensUsedSoFar = 0
    /// The wall clock starts with the run, not with planning: the time the user spends reviewing the checklist or
    /// teaching the first item is theirs, and planning and compiling have their own small turn limits.
    private var runStartDate: Date?

    init(safetyLimits: SafetyLimits, currentDate: @escaping () -> Date = Date.init) {
        self.safetyLimits = safetyLimits
        self.currentDate = currentDate
    }

    var modelTurnsUsed: Int { stateLock.withLock { modelTurnsUsedSoFar } }
    var inputTokensUsed: Int { stateLock.withLock { inputTokensUsedSoFar } }

    func startRunWallClock() {
        let runStartDate = currentDate()
        stateLock.withLock { self.runStartDate = runStartDate }
    }

    func recordModelTurn(usage: ClaudeUsage) {
        stateLock.withLock {
            modelTurnsUsedSoFar += 1
            inputTokensUsedSoFar += usage.inputTokens + (usage.cacheReadInputTokens ?? 0) + (usage.cacheCreationInputTokens ?? 0)
        }
    }

    func throwIfExhausted() throws {
        if let runStartDate = stateLock.withLock({ runStartDate }),
           currentDate().timeIntervalSince(runStartDate) >= safetyLimits.maximumTaskWallClockSeconds {
            let limitInMinutes = Int((safetyLimits.maximumTaskWallClockSeconds / 60).rounded())
            throw TaskCeilingReachedError(ceiling: .wallClock,
                                          userFacingDescription: "the task ran for its \(limitInMinutes)-minute limit")
        }
        if modelTurnsUsed >= safetyLimits.maximumModelTurnsPerTask {
            throw TaskCeilingReachedError(ceiling: .modelTurns,
                                          userFacingDescription: "the task used its limit of \(safetyLimits.maximumModelTurnsPerTask) Claude turns")
        }
        if inputTokensUsed >= safetyLimits.maximumInputTokensPerTask {
            throw TaskCeilingReachedError(ceiling: .inputTokens,
                                          userFacingDescription: "the task used its limit of \(safetyLimits.maximumInputTokensPerTask) input tokens")
        }
    }
}
