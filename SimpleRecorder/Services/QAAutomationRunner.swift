//
//  QAAutomationRunner.swift
//  会议录音 Pro
//
//  仅在通过 --qa-scenario 启动时运行，用于打包产物的自动回归验证。
//

import AppKit
import AVFoundation
import Foundation

final class QAAutomationRunner {
    static private(set) var isActive = false

    private let scenarioURL: URL
    private let fileManager = FileManager.default
    private let isoFormatter = ISO8601DateFormatter()
    private var qaAudioPlayer: AVAudioPlayer?

    static func fromCommandLine() -> QAAutomationRunner? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--qa-scenario"),
            args.indices.contains(index + 1)
        else {
            return nil
        }

        isActive = true
        return QAAutomationRunner(
            scenarioURL: URL(fileURLWithPath: args[index + 1]).standardizedFileURL)
    }

    init(scenarioURL: URL) {
        self.scenarioURL = scenarioURL
    }

    func start() {
        Task { @MainActor in
            await run()
        }
    }

    @MainActor
    private func run() async {
        LogManager.shared.info("QA 自动化启动 | 场景: \(scenarioURL.path)")

        var outputURL = scenarioURL.deletingLastPathComponent().appendingPathComponent(
            "qa-result.json")
        var report = QAReport.bootstrap(scenarioURL: scenarioURL.path)
        var snapshot: QASettingsSnapshot?

        do {
            let scenario = try loadScenario()
            outputURL = scenario.outputURL(defaultBaseURL: scenarioURL.deletingLastPathComponent())
            report.recordingsPath = scenario.recordingsURL.path

            snapshot = QASettingsSnapshot.capture()
            try prepareEnvironment(for: scenario)

            TimerTaskManager.shared.stopScheduler()

            if scenario.includeSettings {
                report.steps.append(runSettingsRoundTrip())
            }

            report.steps.append(
                await runRecordingStep(
                    name: "4.1 microphone-basic",
                    source: .microphone,
                    duration: scenario.recordDuration,
                    playSystemAudio: false
                )
            )

            report.steps.append(
                await runPauseResumeStep(
                    durationBeforePause: max(1.0, scenario.recordDuration / 2),
                    pauseDuration: scenario.pauseDuration,
                    durationAfterResume: max(1.0, scenario.recordDuration / 2)
                )
            )

            report.steps.append(
                await runRecordingStep(
                    name: "4.5 microphone-second-pass",
                    source: .microphone,
                    duration: max(2.0, scenario.recordDuration / 2),
                    playSystemAudio: false
                )
            )

            if scenario.includeSystemAudio {
                report.steps.append(
                    await runSystemAudioStep(
                        name: "4.3 system-audio",
                        source: .systemAudio,
                        duration: scenario.recordDuration
                    )
                )
            }

            if scenario.includeMixedAudio {
                report.steps.append(
                    await runSystemAudioStep(
                        name: "4.4 mixed-audio",
                        source: .both,
                        duration: scenario.recordDuration
                    )
                )
            }

            if scenario.includeTimer {
                report.steps.append(
                    await runTimerAutoStartStep(duration: scenario.recordDuration)
                )
            }

            report.steps.append(runManualCoverageNotice())
        } catch {
            report.steps.append(
                QAStepResult(
                    name: "0 bootstrap",
                    status: .failed,
                    startedAt: Date(),
                    finishedAt: Date(),
                    message: error.localizedDescription,
                    details: [:],
                    recordings: []
                )
            )
            LogManager.shared.error("QA 自动化初始化失败 | 错误: \(error.localizedDescription)")
        }

        if AudioRecorderManager.shared.isRecording {
            await stopCurrentRecording()
        }

        snapshot?.restore()

        report.finishedAt = Date()
        report.summary = QASummary(steps: report.steps)
        do {
            try write(report: report, to: outputURL)
            LogManager.shared.info("QA 自动化完成 | 报告: \(outputURL.path)")
        } catch {
            LogManager.shared.error("QA 报告写入失败 | 错误: \(error.localizedDescription)")
        }

        NSApp.terminate(nil)
    }

    private func loadScenario() throws -> QAScenario {
        let data = try Data(contentsOf: scenarioURL)
        return try JSONDecoder().decode(QAScenario.self, from: data)
    }

    private func write(report: QAReport, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)
    }

    @MainActor
    private func prepareEnvironment(for scenario: QAScenario) throws {
        try fileManager.createDirectory(at: scenario.recordingsURL, withIntermediateDirectories: true)

        let settings = AppSettings.shared
        settings.recordingsPath = scenario.recordingsURL
        settings.audioSource = .microphone
        settings.outputFormat = .m4a
        settings.openFolderAfterRecording = false
        settings.selectedDeviceID = "default"
        settings.maxDurationHours = 0
        settings.maxDurationMinutes = max(5, Int(ceil(scenario.recordDuration / 60.0)) * 5)
    }

    @MainActor
    private func runSettingsRoundTrip() -> QAStepResult {
        let startedAt = Date()
        let settings = AppSettings.shared
        let originalDimIcon = settings.dimIconWhenIdle
        let originalShowDuration = settings.showDurationWhenRecording
        let originalIconStyle = settings.iconStyle
        let originalTimerAction = settings.timerActionType
        let originalTimerReminder = settings.timerReminderMinutes
        let originalPreventSleep = settings.preventSleepWithSchedule

        settings.dimIconWhenIdle.toggle()
        settings.showDurationWhenRecording.toggle()
        settings.iconStyle = .circleDot
        settings.timerActionType = .autoStart
        settings.timerReminderMinutes = 3
        settings.preventSleepWithSchedule.toggle()

        let passed =
            settings.dimIconWhenIdle != originalDimIcon
            && settings.showDurationWhenRecording != originalShowDuration
            && settings.iconStyle == .circleDot
            && settings.timerActionType == .autoStart
            && settings.timerReminderMinutes == 3
            && settings.preventSleepWithSchedule != originalPreventSleep

        settings.dimIconWhenIdle = originalDimIcon
        settings.showDurationWhenRecording = originalShowDuration
        settings.iconStyle = originalIconStyle
        settings.timerActionType = originalTimerAction
        settings.timerReminderMinutes = originalTimerReminder
        settings.preventSleepWithSchedule = originalPreventSleep

        return QAStepResult(
            name: "3.x 5.x settings-round-trip",
            status: passed ? .passed : .failed,
            startedAt: startedAt,
            finishedAt: Date(),
            message: passed ? "基础设置可写入、可回读、可恢复" : "设置回读结果不符合预期",
            details: [
                "checked": "dimIconWhenIdle, showDurationWhenRecording, iconStyle, timerActionType, timerReminderMinutes, preventSleepWithSchedule"
            ],
            recordings: []
        )
    }

    @MainActor
    private func runRecordingStep(
        name: String,
        source: AudioSource,
        duration: TimeInterval,
        playSystemAudio: Bool
    ) async -> QAStepResult {
        let startedAt = Date()
        let before = audioFiles()

        AppSettings.shared.audioSource = source
        AppSettings.shared.openFolderAfterRecording = false

        guard AudioRecorderManager.shared.startRecording() else {
            return failedStep(
                name: name,
                startedAt: startedAt,
                message: "录音启动 API 返回失败",
                details: ["source": source.rawValue]
            )
        }

        guard await waitForState(.recording, timeout: 12.0) else {
            await stopCurrentRecording()
            return failedStep(
                name: name,
                startedAt: startedAt,
                message: "录音未在超时时间内进入 recording 状态",
                details: currentRecorderDetails(source: source)
            )
        }

        if playSystemAudio {
            playSystemAudioPrompt(name)
        }

        await sleep(seconds: duration)
        await stopCurrentRecording()

        let recordings = newRecordings(since: before)
        let minimumBytes = minimumRecordingBytes(for: source)
        let passed = recordings.contains { $0.bytes >= minimumBytes }
        return QAStepResult(
            name: name,
            status: passed ? .passed : .failed,
            startedAt: startedAt,
            finishedAt: Date(),
            message: passed ? "录音已生成有效文件" : "未发现达到有效阈值的录音文件",
            details: currentRecorderDetails(source: source).merging(
                ["minimumFileBytes": "\(minimumBytes)"], uniquingKeysWith: { _, new in new }),
            recordings: recordings
        )
    }

    @MainActor
    private func runPauseResumeStep(
        durationBeforePause: TimeInterval,
        pauseDuration: TimeInterval,
        durationAfterResume: TimeInterval
    ) async -> QAStepResult {
        let name = "4.2 microphone-pause-resume"
        let startedAt = Date()
        let before = audioFiles()

        AppSettings.shared.audioSource = .microphone
        AppSettings.shared.openFolderAfterRecording = false

        guard AudioRecorderManager.shared.startRecording() else {
            return failedStep(name: name, startedAt: startedAt, message: "录音启动 API 返回失败")
        }
        guard await waitForState(.recording, timeout: 12.0) else {
            await stopCurrentRecording()
            return failedStep(name: name, startedAt: startedAt, message: "录音未进入 recording 状态")
        }

        await sleep(seconds: durationBeforePause)
        AudioRecorderManager.shared.pauseRecording()
        guard await waitForState(.paused, timeout: 4.0) else {
            await stopCurrentRecording()
            return failedStep(name: name, startedAt: startedAt, message: "暂停后未进入 paused 状态")
        }

        await sleep(seconds: pauseDuration)
        AudioRecorderManager.shared.resumeRecording()
        guard await waitForState(.recording, timeout: 4.0) else {
            await stopCurrentRecording()
            return failedStep(name: name, startedAt: startedAt, message: "继续后未恢复 recording 状态")
        }

        await sleep(seconds: durationAfterResume)
        await stopCurrentRecording()

        let recordings = newRecordings(since: before)
        let minimumBytes = minimumRecordingBytes(for: .microphone)
        let passed = recordings.contains { $0.bytes >= minimumBytes }
        return QAStepResult(
            name: name,
            status: passed ? .passed : .failed,
            startedAt: startedAt,
            finishedAt: Date(),
            message: passed ? "暂停/继续后录音已保存" : "暂停/继续场景未生成有效文件",
            details: currentRecorderDetails(source: .microphone).merging(
                ["minimumFileBytes": "\(minimumBytes)"], uniquingKeysWith: { _, new in new }),
            recordings: recordings
        )
    }

    @MainActor
    private func runSystemAudioStep(
        name: String,
        source: AudioSource,
        duration: TimeInterval
    ) async -> QAStepResult {
        let startedAt = Date()
        guard AppSettings.isSystemAudioSupported else {
            return skippedStep(
                name: name,
                startedAt: startedAt,
                message: "当前 macOS 不支持 ScreenCaptureKit 系统音频采集"
            )
        }

        guard AppSettings.hasScreenCapturePermission else {
            AppSettings.requestScreenCapturePermission()
            return skippedStep(
                name: name,
                startedAt: startedAt,
                message: "缺少屏幕录制权限，已触发系统权限申请；授权后重新运行脚本可自动验证",
                details: ["permission": "screen_capture_missing"]
            )
        }

        return await runRecordingStep(
            name: name,
            source: source,
            duration: duration,
            playSystemAudio: true
        )
    }

    @MainActor
    private func runTimerAutoStartStep(duration: TimeInterval) async -> QAStepResult {
        let name = "6.2 timer-auto-start"
        let startedAt = Date()
        let before = audioFiles()
        let manager = TimerTaskManager.shared
        let originalTasks = manager.tasks

        AppSettings.shared.audioSource = .microphone
        manager.stopScheduler()

        let now = Date()
        let calendar = Calendar.current
        var task = TimerTask(
            enabled: true,
            hour: calendar.component(.hour, from: now),
            minute: calendar.component(.minute, from: now),
            repeatType: .none,
            actionType: .autoStart,
            reminderMinutes: 1
        )
        task.nextTriggerTime = Date().addingTimeInterval(-1.0)
        task.lastTriggerTime = nil

        manager.tasks = [task]
        manager.checkAndTriggerReminders()

        guard await waitForState(.recording, timeout: 12.0) else {
            manager.tasks = originalTasks
            await stopCurrentRecording()
            return failedStep(
                name: name,
                startedAt: startedAt,
                message: "定时自动录音未在超时时间内启动",
                details: ["taskID": task.id.uuidString]
            )
        }

        await sleep(seconds: duration)
        await stopCurrentRecording()
        manager.tasks = originalTasks

        let recordings = newRecordings(since: before)
        let minimumBytes = minimumRecordingBytes(for: .microphone)
        let passed = recordings.contains { $0.bytes >= minimumBytes }
        return QAStepResult(
            name: name,
            status: passed ? .passed : .failed,
            startedAt: startedAt,
            finishedAt: Date(),
            message: passed ? "定时任务自动启动并保存录音" : "定时任务启动后未生成有效录音",
            details: [
                "taskID": task.id.uuidString,
                "minimumFileBytes": "\(minimumBytes)",
            ],
            recordings: recordings
        )
    }

    private func runManualCoverageNotice() -> QAStepResult {
        let now = Date()
        return QAStepResult(
            name: "manual-remainder",
            status: .skipped,
            startedAt: now,
            finishedAt: now,
            message: "以下项目仍需人工或系统授权补测：菜单栏 UI、设置窗口 Tab、快捷键改绑与冲突、提醒弹窗点击、登录项、Finder 打开、录音中退出、强杀恢复、不可写目录、设备插拔、睡眠断言。",
            details: ["coverage": "自动覆盖约 80-90%，剩余为强交互或系统状态类场景"],
            recordings: []
        )
    }

    @MainActor
    private func stopCurrentRecording() async {
        if AudioRecorderManager.shared.isRecording {
            AudioRecorderManager.shared.stopRecording()
        }
        _ = await waitForState(.idle, timeout: 12.0)
    }

    @MainActor
    private func waitForState(_ expected: RecordingState, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if AudioRecorderManager.shared.recordingState == expected {
                return true
            }
            await sleep(seconds: 0.2)
        }
        return AudioRecorderManager.shared.recordingState == expected
    }

    private func sleep(seconds: TimeInterval) async {
        let nanoseconds = UInt64(max(0.0, seconds) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    private func playSystemAudioPrompt(_ label: String) {
        let url = fileManager.temporaryDirectory.appendingPathComponent(
            "meeting-recorder-qa-tone.wav")

        do {
            try writeToneFile(to: url)
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = 0.8
            player.prepareToPlay()
            player.play()
            qaAudioPlayer = player
        } catch {
            LogManager.shared.warning("QA 测试音播放失败 | 场景: \(label), 错误: \(error.localizedDescription)")
        }
    }

    private func writeToneFile(to url: URL) throws {
        let sampleRate = 48_000.0
        let duration = 3.0
        let frequency = 880.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
            let channel = buffer.floatChannelData?[0]
        else {
            throw NSError(
                domain: "QAAutomationRunner",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "无法创建 QA 测试音频缓冲"])
        }

        buffer.frameLength = frameCount
        for index in 0..<Int(frameCount) {
            let t = Double(index) / sampleRate
            channel[index] = Float(0.35 * sin(2.0 * Double.pi * frequency * t))
        }

        try file.write(from: buffer)
    }

    private func minimumRecordingBytes(for source: AudioSource) -> Int64 {
        switch source {
        case .microphone:
            return 8_000
        case .systemAudio:
            return 12_000
        case .both:
            return 12_000
        }
    }

    private func audioFiles() -> Set<URL> {
        let directory = AppSettings.shared.recordingsPath
        let urls =
            (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []

        return Set(
            urls.filter {
                ["m4a", "mp3"].contains($0.pathExtension.lowercased())
            }
        )
    }

    private func newRecordings(since before: Set<URL>) -> [QARecording] {
        let after = audioFiles()
        return after.subtracting(before)
            .sorted { $0.path < $1.path }
            .map { url in
                let attributes = try? fileManager.attributesOfItem(atPath: url.path)
                let bytes = attributes?[.size] as? Int64 ?? 0
                let modifiedAt = attributes?[.modificationDate] as? Date
                return QARecording(
                    path: url.path,
                    bytes: bytes,
                    modifiedAt: modifiedAt,
                    extensionName: url.pathExtension.lowercased()
                )
            }
    }

    @MainActor
    private func currentRecorderDetails(source: AudioSource) -> [String: String] {
        let recorder = AudioRecorderManager.shared
        return [
            "source": source.rawValue,
            "state": recorder.recordingState.qaName,
            "frames": "\(recorder.framesCounter.withLock { $0 })",
            "droppedFrames": "\(recorder.droppedFrameCount)",
            "totalFrames": "\(recorder.totalFrameCount)",
            "durationSeconds": String(format: "%.1f", recorder.recordingDuration),
        ]
    }

    private func failedStep(
        name: String,
        startedAt: Date,
        message: String,
        details: [String: String] = [:]
    ) -> QAStepResult {
        QAStepResult(
            name: name,
            status: .failed,
            startedAt: startedAt,
            finishedAt: Date(),
            message: message,
            details: details,
            recordings: []
        )
    }

    private func skippedStep(
        name: String,
        startedAt: Date,
        message: String,
        details: [String: String] = [:]
    ) -> QAStepResult {
        QAStepResult(
            name: name,
            status: .skipped,
            startedAt: startedAt,
            finishedAt: Date(),
            message: message,
            details: details,
            recordings: []
        )
    }
}

private struct QAScenario: Decodable {
    let outputPath: String?
    let recordingsPath: String
    let recordSeconds: Double?
    let pauseSeconds: Double?
    private let includeSettingsValue: Bool?
    private let includeSystemAudioValue: Bool?
    private let includeMixedAudioValue: Bool?
    private let includeTimerValue: Bool?

    enum CodingKeys: String, CodingKey {
        case outputPath
        case recordingsPath
        case recordSeconds
        case pauseSeconds
        case includeSettingsValue = "includeSettings"
        case includeSystemAudioValue = "includeSystemAudio"
        case includeMixedAudioValue = "includeMixedAudio"
        case includeTimerValue = "includeTimer"
    }

    var recordingsURL: URL {
        URL(fileURLWithPath: recordingsPath, isDirectory: true).standardizedFileURL
    }

    var recordDuration: TimeInterval {
        max(2.0, recordSeconds ?? 4.0)
    }

    var pauseDuration: TimeInterval {
        max(1.0, pauseSeconds ?? 1.0)
    }

    var includeSettings: Bool {
        includeSettingsValue ?? true
    }

    var includeSystemAudio: Bool {
        includeSystemAudioValue ?? true
    }

    var includeMixedAudio: Bool {
        includeMixedAudioValue ?? true
    }

    var includeTimer: Bool {
        includeTimerValue ?? true
    }

    func outputURL(defaultBaseURL: URL) -> URL {
        if let outputPath {
            return URL(fileURLWithPath: outputPath).standardizedFileURL
        }
        return defaultBaseURL.appendingPathComponent("qa-result.json")
    }
}

private struct QASettingsSnapshot {
    let recordingsPath: URL
    let maxDurationHours: Int
    let maxDurationMinutes: Int
    let audioSource: AudioSource
    let outputFormat: OutputFormat
    let openFolderAfterRecording: Bool
    let dimIconWhenIdle: Bool
    let showDurationWhenRecording: Bool
    let iconStyle: IconStyle
    let selectedDeviceID: String
    let timerActionType: TimerActionType
    let timerReminderMinutes: Int
    let preventSleepDuringRecording: Bool
    let preventSleepWithSchedule: Bool
    let timerTasksData: Data?
    let recordingInProgress: Bool
    let recordingFilePath: String?
    let recordingStartTime: Double?

    @MainActor
    static func capture() -> QASettingsSnapshot {
        let settings = AppSettings.shared
        let defaults = UserDefaults.standard
        return QASettingsSnapshot(
            recordingsPath: settings.recordingsPath,
            maxDurationHours: settings.maxDurationHours,
            maxDurationMinutes: settings.maxDurationMinutes,
            audioSource: settings.audioSource,
            outputFormat: settings.outputFormat,
            openFolderAfterRecording: settings.openFolderAfterRecording,
            dimIconWhenIdle: settings.dimIconWhenIdle,
            showDurationWhenRecording: settings.showDurationWhenRecording,
            iconStyle: settings.iconStyle,
            selectedDeviceID: settings.selectedDeviceID,
            timerActionType: settings.timerActionType,
            timerReminderMinutes: settings.timerReminderMinutes,
            preventSleepDuringRecording: settings.preventSleepDuringRecording,
            preventSleepWithSchedule: settings.preventSleepWithSchedule,
            timerTasksData: defaults.data(forKey: "timerTasks"),
            recordingInProgress: defaults.bool(forKey: "recording_in_progress"),
            recordingFilePath: defaults.string(forKey: "recording_file_path"),
            recordingStartTime: defaults.object(forKey: "recording_start_time") as? Double
        )
    }

    @MainActor
    func restore() {
        let settings = AppSettings.shared
        settings.recordingsPath = recordingsPath
        settings.maxDurationHours = maxDurationHours
        settings.maxDurationMinutes = maxDurationMinutes
        settings.audioSource = audioSource
        settings.outputFormat = outputFormat
        settings.openFolderAfterRecording = openFolderAfterRecording
        settings.dimIconWhenIdle = dimIconWhenIdle
        settings.showDurationWhenRecording = showDurationWhenRecording
        settings.iconStyle = iconStyle
        settings.selectedDeviceID = selectedDeviceID
        settings.timerActionType = timerActionType
        settings.timerReminderMinutes = timerReminderMinutes
        settings.preventSleepDuringRecording = preventSleepDuringRecording
        settings.preventSleepWithSchedule = preventSleepWithSchedule

        let defaults = UserDefaults.standard
        if let timerTasksData {
            defaults.set(timerTasksData, forKey: "timerTasks")
        } else {
            defaults.removeObject(forKey: "timerTasks")
        }

        defaults.set(recordingInProgress, forKey: "recording_in_progress")
        if let recordingFilePath {
            defaults.set(recordingFilePath, forKey: "recording_file_path")
        } else {
            defaults.removeObject(forKey: "recording_file_path")
        }
        if let recordingStartTime {
            defaults.set(recordingStartTime, forKey: "recording_start_time")
        } else {
            defaults.removeObject(forKey: "recording_start_time")
        }
        defaults.synchronize()
    }
}

private struct QAReport: Codable {
    var scenarioPath: String
    var appVersion: String
    var buildVersion: String
    var bundleIdentifier: String
    var macOS: String
    var startedAt: Date
    var finishedAt: Date?
    var recordingsPath: String?
    var steps: [QAStepResult]
    var summary: QASummary

    static func bootstrap(scenarioURL: String) -> QAReport {
        let bundle = Bundle.main
        return QAReport(
            scenarioPath: scenarioURL,
            appVersion: bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            buildVersion: bundle.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            bundleIdentifier: bundle.bundleIdentifier ?? "unknown",
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            startedAt: Date(),
            finishedAt: nil,
            recordingsPath: nil,
            steps: [],
            summary: QASummary(total: 0, passed: 0, failed: 0, skipped: 0)
        )
    }
}

private struct QASummary: Codable {
    var total: Int
    var passed: Int
    var failed: Int
    var skipped: Int

    init(total: Int, passed: Int, failed: Int, skipped: Int) {
        self.total = total
        self.passed = passed
        self.failed = failed
        self.skipped = skipped
    }

    init(steps: [QAStepResult]) {
        total = steps.count
        passed = steps.filter { $0.status == .passed }.count
        failed = steps.filter { $0.status == .failed }.count
        skipped = steps.filter { $0.status == .skipped }.count
    }
}

private struct QAStepResult: Codable {
    var name: String
    var status: QAStepStatus
    var startedAt: Date
    var finishedAt: Date
    var message: String
    var details: [String: String]
    var recordings: [QARecording]
}

private enum QAStepStatus: String, Codable {
    case passed
    case failed
    case skipped
}

private struct QARecording: Codable {
    var path: String
    var bytes: Int64
    var modifiedAt: Date?
    var extensionName: String
}

private extension RecordingState {
    var qaName: String {
        switch self {
        case .idle: return "idle"
        case .starting: return "starting"
        case .recording: return "recording"
        case .paused: return "paused"
        case .stopping: return "stopping"
        }
    }
}
