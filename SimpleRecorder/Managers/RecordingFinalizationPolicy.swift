import Foundation

/// 在主线程管理所有并行输出任务。退出必须等到最后一个任务结束。
final class RecordingOutputFinalizer {
    private var pendingCount = 0
    private var completions: [() -> Void] = []
    var onPendingChanged: ((Bool) -> Void)?
    var isPending: Bool { pendingCount > 0 }

    func begin() {
        pendingCount += 1
        if pendingCount == 1 { onPendingChanged?(true) }
    }

    @discardableResult
    func finish() -> Bool {
        guard pendingCount > 0 else { return false }
        pendingCount -= 1
        guard pendingCount == 0 else { return true }
        let waiting = completions
        completions.removeAll()
        onPendingChanged?(false)
        // 状态观察者可能同步登记新任务；重新经过等待门禁，不能提前通知退出。
        waiting.forEach { wait(completion: $0) }
        return true
    }

    func wait(completion: @escaping () -> Void) {
        if isPending {
            completions.append(completion)
        } else {
            completion()
        }
    }
}

/// 异常中断后的自动续录节奏：先给设备路由留出稳定时间，再逐次拉长间隔。
/// 时长上限到达属于用户设定的正常停止，不走这条路径。
enum RecordingAutomaticRestartPolicy {
    static let delays: [TimeInterval] = [2, 5, 10]

    /// 第 attempt 次（从 1 开始）尝试前应等待的秒数；超过次数上限返回 nil。
    static func delay(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 1, attempt <= delays.count else { return nil }
        return delays[attempt - 1]
    }
}

enum RecordingPermissionPolicy {
    static func requiresMicrophonePermission(isSystemAudioOnly: Bool) -> Bool {
        !isSystemAudioOnly
    }
}

/// 崩溃恢复标记的清理门禁。保持为纯逻辑，供 App 与独立测试 target 共同编译。
enum RecordingFinalizationPolicy {
    static func shouldClearRecoveryState(
        writerCompleted: Bool,
        mediaValidationSucceeded: Bool,
        finalFileExists: Bool
    ) -> Bool {
        writerCompleted && mediaValidationSucceeded && finalFileExists
    }

    static func canApplyInterruptedRecovery(
        expectedPath: String,
        recordingStateIsIdle: Bool,
        markerIsActive: Bool,
        currentMarkerPath: String?
    ) -> Bool {
        recordingStateIsIdle && markerIsActive && currentMarkerPath == expectedPath
    }

    /// MP3 源文件删除门禁。编码器成功不代表最终文件完整；
    /// 只有最终 MP3 通过媒体验证且仍然存在时，才允许删除源 M4A。
    static func shouldRemoveSourceAfterMP3Finalization(
        encoderSucceeded: Bool,
        mediaValidationSucceeded: Bool,
        finalFileExists: Bool
    ) -> Bool {
        encoderSucceeded && mediaValidationSucceeded && finalFileExists
    }
}

/// CoreAudio 的默认输入设备回调可能先于设备信息完成刷新。
/// 只有录音设备与当前默认输入设备都可解析，且 ID 确实不同时，才能判定为真实切换。
enum RecordingInputDeviceChangePolicy {
    static func shouldInterruptRecording(
        recordingDeviceID: String?,
        currentDefaultInputDeviceID: String?
    ) -> Bool {
        guard let recordingDeviceID,
            recordingDeviceID != "default",
            let currentDefaultInputDeviceID
        else {
            return false
        }

        return recordingDeviceID != currentDefaultInputDeviceID
    }
}
