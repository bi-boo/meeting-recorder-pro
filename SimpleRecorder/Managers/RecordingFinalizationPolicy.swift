import Foundation

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
