import Foundation

let taskRunMetricsTestSuite = CoreTestSuite(name: "TaskRunMetrics", testCases: [
    CoreTestCase(name: "the metered transport counts calls and tokens and passes responses through") {
        let scriptedResponse = try ConversationFixtures.response(stopReason: "end_turn", blocks: [#"{"type":"text","text":"ok"}"#])
        let underlyingTransport = ScriptedClaudeTransport(replies: [.response(scriptedResponse), .response(scriptedResponse)])
        let metricsAccumulator = TaskRunMetricsAccumulator()
        let meteredTransport = MeteredClaudeTransport(wrapping: underlyingTransport, metricsAccumulator: metricsAccumulator)
        let request = PromptLibrary.makeExecutorRequest(conversationMessages: [])
        for _ in 0..<2 {
            try expectEqual(try await meteredTransport.sendMessagesRequest(request, onProgress: { _ in }), scriptedResponse)
        }
        let metrics = metricsAccumulator.currentMetrics
        try expectEqual(metrics.modelCallCount, 2)
        try expectEqual(metrics.inputTokenCount, 200)
        try expectEqual(metrics.outputTokenCount, 40)
        try expectEqual(metrics.cacheReadInputTokenCount, 160)
        try expectEqual(underlyingTransport.recordedRequests.count, 2)
    },
    CoreTestCase(name: "saved calls use this task's agent average, else the routine's baseline") {
        let metricsAccumulator = TaskRunMetricsAccumulator(baselineModelCallsPerAgentItem: 9)
        metricsAccumulator.recordCompletedItem(path: .replay, modelCallsUsed: 0, durationSeconds: 3)
        metricsAccumulator.recordCompletedItem(path: .replay, modelCallsUsed: 0, durationSeconds: 3.2)
        try expectEqual(metricsAccumulator.currentMetrics.estimatedModelCallsSavedByReplay, 18)
        try expectEqual(metricsAccumulator.currentMetrics.summaryLine, "2 replayed · ~18 model calls saved")

        metricsAccumulator.recordCompletedItem(path: .agent, modelCallsUsed: 6, durationSeconds: 28)
        metricsAccumulator.recordReplayFallback()
        let metrics = metricsAccumulator.currentMetrics
        try expectEqual(metrics.estimatedModelCallsSavedByReplay, 12)
        try expectEqual(metrics.replayFallbacksToAgent, 1)
        try expectEqual(metrics.summaryLine, "2 replayed · ~12 model calls saved · 3.1 s vs 28 s per item")
    },
    CoreTestCase(name: "summaryLine is nil when nothing was replayed; no baseline saves nothing") {
        let metricsAccumulator = TaskRunMetricsAccumulator()
        metricsAccumulator.recordCompletedItem(path: .agent, modelCallsUsed: 5, durationSeconds: 20)
        try expectEqual(metricsAccumulator.currentMetrics.summaryLine, nil)
        try expectEqual(TaskRunMetrics(itemsCompletedByReplay: 3).estimatedModelCallsSavedByReplay, 0)
        try expectEqual(TaskRunMetrics(itemsCompletedByReplay: 3).summaryLine, "3 replayed")
    },
    CoreTestCase(name: "items finished by the agent after a replay fallback are counted apart from agent items") {
        let metricsAccumulator = TaskRunMetricsAccumulator()
        metricsAccumulator.recordCompletedItem(path: .agent, modelCallsUsed: 6, durationSeconds: 20)
        metricsAccumulator.recordCompletedItem(path: .replayFallback, modelCallsUsed: 2, durationSeconds: 9)
        metricsAccumulator.recordCompletedItem(path: .replay, modelCallsUsed: 0, durationSeconds: 3)
        let metrics = metricsAccumulator.currentMetrics
        try expectEqual(metrics.itemsCompletedByAgent, 1)
        try expectEqual(metrics.modelCallsDuringAgentItems, 6)
        try expectEqual(metrics.itemsCompletedAfterReplayFallback, 1)
        try expectEqual(metrics.modelCallsDuringReplayFallbackItems, 2)
        try expectEqual(metrics.secondsSpentInReplayFallbackItems, 9)
        try expectEqual(metrics.estimatedModelCallsSavedByReplay, 6)
    },
])
