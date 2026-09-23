import Foundation

enum TaskStopReason: Equatable, Sendable {
    case allItemsProcessed, userAborted, tooManyConsecutiveFailures, taskActionLimitReached
    case taskCeilingReached(String)
    case unrecoverableError(String)
}

struct TaskRunSummary: Equatable, Sendable {
    var completedItemCount: Int
    var failedItemCount: Int
    var needsUserItemCount: Int
    var skippedItemCount: Int
    var stopReason: TaskStopReason

    static func summarize(checklist: Checklist, stopReason: TaskStopReason) -> TaskRunSummary {
        func countOfItems(withRunStatus runStatus: ChecklistItemRunStatus) -> Int {
            checklist.items.filter { $0.runStatus == runStatus }.count
        }
        return TaskRunSummary(completedItemCount: countOfItems(withRunStatus: .completed),
                              failedItemCount: countOfItems(withRunStatus: .failed),
                              needsUserItemCount: countOfItems(withRunStatus: .needsUser),
                              skippedItemCount: countOfItems(withRunStatus: .skipped),
                              stopReason: stopReason)
    }
}

enum TaskIdentifierFactory {
    /// e.g. "20260922-153012-ab12cd" — sortable, filesystem-safe, used as the audit log file name.
    static func makeTaskIdentifier(now: Date, randomSuffix: String) -> String {
        let timestampFormatter = DateFormatter()
        timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
        timestampFormatter.calendar = Calendar(identifier: .gregorian)
        timestampFormatter.timeZone = TimeZone.current
        timestampFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let filesystemSafeSuffix = randomSuffix.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return "\(timestampFormatter.string(from: now))-\(filesystemSafeSuffix)"
    }
}
