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
}
