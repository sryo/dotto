import Foundation

enum ChecklistItemExecutionPath: String, Sendable {
    case replay, agent
    /// Replay started the item and the agent finished it after a step failed.
    case replayFallback = "replay_fallback"
}

struct TaskRunMetrics: Equatable, Sendable {
    var modelCallCount = 0
    var inputTokenCount = 0
    var outputTokenCount = 0
    var cacheReadInputTokenCount = 0
    var itemsCompletedByReplay = 0
    var itemsCompletedByAgent = 0
    var replayFallbacksToAgent = 0
    /// Kept apart from agent items so the per-agent-item averages (and the savings estimate) only use items the
    /// agent did from scratch.
    var itemsCompletedAfterReplayFallback = 0
    var modelCallsDuringReplayFallbackItems = 0
    var secondsSpentInReplayFallbackItems: Double = 0
    var modelCallsDuringAgentItems = 0
    var secondsSpentInReplayedItems: Double = 0
    var secondsSpentInAgentItems: Double = 0
    /// From Routine.modelCallsUsedWhenLearned; used when this task has no agent items of its own to average.
    var baselineModelCallsPerAgentItem: Double?

    var estimatedModelCallsSavedByReplay: Int {
        let modelCallsPerAgentItem = itemsCompletedByAgent > 0
            ? Double(modelCallsDuringAgentItems) / Double(itemsCompletedByAgent)
            : (baselineModelCallsPerAgentItem ?? 0)
        return Int((Double(itemsCompletedByReplay) * modelCallsPerAgentItem).rounded())
    }

    /// e.g. "12 replayed · ~70 model calls saved · 3.1 s vs 28 s per item"; nil when nothing was replayed.
    var summaryLine: String? {
        guard itemsCompletedByReplay > 0 else { return nil }
        var summaryParts = ["\(itemsCompletedByReplay) replayed"]
        if estimatedModelCallsSavedByReplay > 0 {
            summaryParts.append("~\(estimatedModelCallsSavedByReplay) model calls saved")
        }
        if itemsCompletedByAgent > 0 {
            let secondsPerReplayedItem = secondsSpentInReplayedItems / Double(itemsCompletedByReplay)
            let secondsPerAgentItem = secondsSpentInAgentItems / Double(itemsCompletedByAgent)
            summaryParts.append("\(Self.formattedSeconds(secondsPerReplayedItem)) vs \(Self.formattedSeconds(secondsPerAgentItem)) per item")
        }
        return summaryParts.joined(separator: " · ")
    }

    private static func formattedSeconds(_ seconds: Double) -> String {
        seconds < 10 ? String(format: "%.1f s", seconds) : "\(Int(seconds.rounded())) s"
    }
}

final class TaskRunMetricsAccumulator: @unchecked Sendable {
    private let stateLock = NSLock()
    private var metrics: TaskRunMetrics

    init(baselineModelCallsPerAgentItem: Double? = nil) {
        metrics = TaskRunMetrics(baselineModelCallsPerAgentItem: baselineModelCallsPerAgentItem)
    }

    var currentMetrics: TaskRunMetrics { stateLock.withLock { metrics } }

    func recordModelCall(usage: ClaudeUsage) {
        stateLock.withLock {
            metrics.modelCallCount += 1
            metrics.inputTokenCount += usage.inputTokens
            metrics.outputTokenCount += usage.outputTokens
            metrics.cacheReadInputTokenCount += usage.cacheReadInputTokens ?? 0
        }
    }

    /// `modelCallsUsed` and `durationSeconds` cover every attempt at the item, not just the one that completed it.
    func recordCompletedItem(path: ChecklistItemExecutionPath, modelCallsUsed: Int, durationSeconds: Double) {
        stateLock.withLock {
            switch path {
            case .replay:
                metrics.itemsCompletedByReplay += 1
                metrics.secondsSpentInReplayedItems += durationSeconds
            case .agent:
                metrics.itemsCompletedByAgent += 1
                metrics.modelCallsDuringAgentItems += modelCallsUsed
                metrics.secondsSpentInAgentItems += durationSeconds
            case .replayFallback:
                metrics.itemsCompletedAfterReplayFallback += 1
                metrics.modelCallsDuringReplayFallbackItems += modelCallsUsed
                metrics.secondsSpentInReplayFallbackItems += durationSeconds
            }
        }
    }

    func recordReplayFallback() {
        stateLock.withLock { metrics.replayFallbacksToAgent += 1 }
    }
}
