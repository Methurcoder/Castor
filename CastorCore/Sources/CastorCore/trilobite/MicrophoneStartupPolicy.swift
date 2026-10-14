import Foundation

public nonisolated enum MicrophoneStartupPolicy {
    public enum Action: Equatable, Sendable { case enable, leaveOff }
    /// A stored explicit off wins; an unset first launch asks the OS and enables
    /// only after authorization. Repeated launches never reset a user's choice.
    public static func action(firstRunCompleted: Bool, storedEnabled: Bool?) -> Action {
        if let storedEnabled {return storedEnabled ? .enable : .leaveOff}
        return firstRunCompleted ? .leaveOff : .enable
    }
}
