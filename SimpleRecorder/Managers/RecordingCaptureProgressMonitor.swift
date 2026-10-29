import Foundation

/// 以单调时钟分别观察渲染帧、独立麦克风输入帧和系统声音采集帧；静音采样仍算正常输入。
/// 系统声音源节点在没有数据时会填静音，混音帧照常增长，所以系统声音必须单独计数。
struct RecordingCaptureProgressMonitor {
    enum StalledSource: String {
        case renderedAudio = "录音渲染"
        case microphone = "独立麦克风输入"
        case systemAudio = "系统声音采集"
    }

    private struct Progress {
        var frames: Int64
        var lastProgressAt: TimeInterval

        mutating func isStalled(frames newFrames: Int64, now: TimeInterval, timeout: TimeInterval) -> Bool {
            if newFrames != frames {
                frames = newFrames
                lastProgressAt = now
            }
            return now - lastProgressAt >= timeout
        }
    }

    private let timeout: TimeInterval = 8
    private let startupGracePeriod: TimeInterval = 6
    private var rendered = Progress(frames: 0, lastProgressAt: 0)
    private var microphone: Progress?
    private var systemAudio: Progress?

    mutating func reset(
        renderedFrames: Int64,
        microphoneFrames: Int64?,
        systemAudioFrames: Int64? = nil,
        now: TimeInterval
    ) {
        rendered = Progress(frames: renderedFrames, lastProgressAt: now + startupGracePeriod)
        microphone = microphoneFrames.map {
            Progress(frames: $0, lastProgressAt: now + startupGracePeriod)
        }
        systemAudio = systemAudioFrames.map {
            Progress(frames: $0, lastProgressAt: now + startupGracePeriod)
        }
    }

    mutating func stalledSource(
        renderedFrames: Int64,
        microphoneFrames: Int64?,
        systemAudioFrames: Int64? = nil,
        now: TimeInterval
    ) -> StalledSource? {
        let renderStalled = rendered.isStalled(frames: renderedFrames, now: now, timeout: timeout)
        var microphoneStalled = false
        if let microphoneFrames {
            microphoneStalled = microphone?.isStalled(
                frames: microphoneFrames, now: now, timeout: timeout) ?? false
        }
        var systemAudioStalled = false
        if let systemAudioFrames {
            systemAudioStalled = systemAudio?.isStalled(
                frames: systemAudioFrames, now: now, timeout: timeout) ?? false
        }
        if microphoneStalled { return .microphone }
        if systemAudioStalled { return .systemAudio }
        return renderStalled ? .renderedAudio : nil
    }
}
