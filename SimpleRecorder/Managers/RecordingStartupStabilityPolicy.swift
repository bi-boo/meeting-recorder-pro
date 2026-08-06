import Foundation

enum RecordingStartupStabilityAction: Equatable {
    case finalize
    case wait
    case rebuild
    case fail
}

/// 录音启动阶段的稳定性门禁。只根据当前真实状态做决定，
/// 不把 AVAudioEngine 配置变化通知的次数当作失败条件。
enum RecordingStartupStabilityPolicy {
    static func inputDeviceIsStable(
        activeInputDeviceID: String?,
        currentDefaultInputDeviceID: String?
    ) -> Bool {
        guard let activeInputDeviceID, activeInputDeviceID != "default" else { return true }
        return activeInputDeviceID == currentDefaultInputDeviceID
    }

    static func action(
        engineIsRunning: Bool,
        inputConfigurationIsStable: Bool,
        hasObservedAudioFrames: Bool,
        minimumObservationReached: Bool,
        deadlineReached: Bool
    ) -> RecordingStartupStabilityAction {
        if engineIsRunning && inputConfigurationIsStable && hasObservedAudioFrames
            && minimumObservationReached
        {
            return .finalize
        }

        if deadlineReached {
            return .fail
        }

        if engineIsRunning && inputConfigurationIsStable {
            return .wait
        }

        return .rebuild
    }
}
