import Foundation

enum ClaudeModelConfiguration {
    static let plannerModelIdentifier = "claude-opus-5-5"
    static let executorModelIdentifier = "claude-sonnet-5"
    /// Opus 5.5's own default, which Anthropic measures above Opus 5 at high. At high, one 23-item plan spent 3,937
    /// output tokens (thinking included) and 113 s in the turn that wrote it; effort is what bounds the thinking.
    static let plannerEffort = "medium"
    static let executorEffort = "medium"
    /// The routine compiler runs once per demonstration on the planner model, where quality matters more than cost.
    static let routineCompilerEffort = "medium"
    static let maximumOutputTokens = 16000
}
