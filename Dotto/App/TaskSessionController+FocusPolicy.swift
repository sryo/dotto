import Foundation

extension TaskSessionController {
    private static let taskFocusPolicyDefaultsKey = "dottoTaskFocusPolicy"

    var canChangeTaskFocusPolicy: Bool {
        switch sessionState {
        case .idle, .finished, .failed, .aborted: return true
        default: return false
        }
    }

    func loadTaskFocusPolicy() {
        if let storedValue = UserDefaults.standard.string(forKey: Self.taskFocusPolicyDefaultsKey),
           let storedPolicy = TaskFocusPolicy(rawValue: storedValue) {
            taskFocusPolicy = storedPolicy
        }
        currentTaskFocusPolicy = taskFocusPolicy
    }

    func updateTaskFocusPolicy(_ policy: TaskFocusPolicy) {
        guard canChangeTaskFocusPolicy else { return }
        taskFocusPolicy = policy
        currentTaskFocusPolicy = policy
        UserDefaults.standard.set(policy.rawValue, forKey: Self.taskFocusPolicyDefaultsKey)
    }
}
