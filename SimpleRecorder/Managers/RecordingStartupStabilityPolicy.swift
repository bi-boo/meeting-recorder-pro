import CoreAudio
import Foundation

/// 判断麦克风采集是否走独立采集链路，而不是 AVAudioEngine 的输入节点。
enum RecordingInputRoutePolicy {
    /// 蓝牙和 AirPlay 输出与另一输入设备并用时，需要避开 AVAudioEngine 的隐式聚合设备。
    static func requiresIndependentCapture(outputTransportType: UInt32?) -> Bool {
        guard let outputTransportType else { return false }
        return outputTransportType == kAudioDeviceTransportTypeBluetooth
            || outputTransportType == kAudioDeviceTransportTypeBluetoothLE
            || outputTransportType == kAudioDeviceTransportTypeAirPlay
    }

    /// AVAudioEngine 输入节点只能采集系统默认输入。录音设备不是系统默认输入时
    /// （手动选择或自动替代），必须独立采集，应用不通过修改系统默认输入来迁就引擎。
    static func requiresIndependentCapture(
        outputTransportType: UInt32?,
        inputFollowsSystemDefault: Bool
    ) -> Bool {
        !inputFollowsSystemDefault
            || requiresIndependentCapture(outputTransportType: outputTransportType)
    }
}

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
