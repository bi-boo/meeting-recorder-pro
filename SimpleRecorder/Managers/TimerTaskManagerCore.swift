//
//  TimerTaskManagerCore.swift
//  会议录音 Pro - 定时任务调度管理器
//
//  Created by AI Assistant
//

import AppKit
import Combine
import Foundation
import IOKit.pwr_mgt
import Security

private enum TimerRecordingStartResult {
    case requested
    case alreadyRecording
    case rejected
}

private final class KeychainTimerTaskAuthorizationStore: TimerTaskAuthorizationStore {
    private let service = "com.meetingrecorderpro.app.timer-task-authorization.v1"

    func authorizationDigest(for taskID: UUID) -> TimerTaskAuthorizationLookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: taskID),
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let digest = result as? Data else { return .notFound }
            return .found(digest)
        case errSecItemNotFound:
            return .notFound
        default:
            LogManager.shared.warning(
                "读取定时任务授权失败 | ID: \(taskID) | 错误码: \(status)"
            )
            return .unavailable(status: status)
        }
    }

    func setAuthorizationDigest(_ digest: Data, for taskID: UUID) -> Bool {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: taskID),
            kSecAttrSynchronizable as String: false,
        ]
        let update: [String: Any] = [kSecValueData as String: digest]

        var status = SecItemUpdate(lookup as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = lookup
            item[kSecValueData as String] = digest
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)

            // 并发创建时可能已由另一次操作写入，此时改为更新。
            if status == errSecDuplicateItem {
                status = SecItemUpdate(lookup as CFDictionary, update as CFDictionary)
            }
        }

        guard status == errSecSuccess else {
            LogManager.shared.warning(
                "保存定时任务授权失败 | ID: \(taskID) | 错误码: \(status)"
            )
            return false
        }
        return true
    }

    func removeAuthorization(for taskID: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: taskID),
            kSecAttrSynchronizable as String: false,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            LogManager.shared.warning(
                "删除定时任务授权失败 | ID: \(taskID) | 错误码: \(status)"
            )
            return false
        }
        return true
    }

    private func account(for taskID: UUID) -> String {
        taskID.uuidString.lowercased()
    }
}

// MARK: - 定时任务管理器

/// 定时任务调度管理器（单例模式）
/// 负责任务的 CRUD、持久化存储和调度触发
class TimerTaskManager: ObservableObject {
    static let shared = TimerTaskManager()

    // MARK: - 发布属性

    @Published var tasks: [TimerTask] = []

    // MARK: - 私有属性

    private var precisionTimer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(
        label: "com.meetingrecorder.timerqueue", qos: .userInitiated)
    private let storageKey = "timerTasks"
    private let taskAuthorization = TimerTaskAuthorizationController(
        store: KeychainTimerTaskAuthorizationStore()
    )
    private var reminderController: ReminderWindowController?

    /// 授权记录与保存的计划不一致而被暂停的自动录音任务；用户在应用内重新启用后清除。
    @Published private(set) var tasksNeedingReauthorization: Set<UUID> = []
    private var pendingReauthorizationNoticeCount = 0

    // 自动录音启动失败后在补录期内的重试计时，按计划去重。
    private var autoStartRetryWorkItems: [TimerTaskOccurrence: DispatchWorkItem] = [:]

    private var autoStartLateGrace: TimeInterval {
        Double(AppSettings.shared.timerAutoStartLateGraceMinutes) * 60
    }

#if QA_AUTOMATION
    private var qaAutomaticRecordingAuthorizationDigests: [UUID: Data] = [:]
#endif

    // 按“任务 + 本次计划时间”去重，编辑任务后不会让旧回调阻塞或推进新计划。
    private var triggeredTaskOccurrences: Set<TimerTaskOccurrence> = []

    // 睡眠防止断言 ID
    private var sleepAssertionID: IOPMAssertionID = 0

    private func isTriggered(_ task: TimerTask) -> Bool {
        guard let occurrence = TimerTaskOccurrence(task: task) else { return false }
        return triggeredTaskOccurrences.contains(occurrence)
    }

    private func clearTriggeredOccurrences(for taskID: UUID) {
        triggeredTaskOccurrences = triggeredTaskOccurrences.filter { $0.taskID != taskID }
        for (occurrence, workItem) in autoStartRetryWorkItems where occurrence.taskID == taskID {
            workItem.cancel()
            autoStartRetryWorkItems.removeValue(forKey: occurrence)
        }
    }

    private func clearTriggeredOccurrence(_ occurrence: TimerTaskOccurrence) {
        triggeredTaskOccurrences.remove(occurrence)
        autoStartRetryWorkItems.removeValue(forKey: occurrence)?.cancel()
    }

    private func isCurrentOccurrence(_ occurrence: TimerTaskOccurrence) -> Bool {
        guard let task = tasks.first(where: { $0.id == occurrence.taskID }) else { return false }
        return TimerTaskOccurrence(task: task) == occurrence
    }

    private func automaticRecordingAuthorizationState(_ task: TimerTask) -> TimerTaskAuthorizationState {
#if QA_AUTOMATION
        if QAAutomationRunner.isActive,
            let expectedDigest = TimerTaskAuthorizationDigest.make(for: task),
            qaAutomaticRecordingAuthorizationDigests[task.id] == expectedDigest
        {
            return .authorized
        }
#endif
        return taskAuthorization.authorizationState(for: task)
    }

    /// 授权记录与保存的计划不一致时按失败关闭处理：暂停任务、撤销旧记录，并提示用户重新确认。
    private func disableUnauthorizedAutomaticRecordingTask(id: UUID, reason: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
            tasks[index].actionType == .autoStart
        else {
            return
        }

        var updatedTasks = tasks
        updatedTasks[index].enabled = false
        updatedTasks[index].nextTriggerTime = nil
        updatedTasks[index].updatedAt = Date()
        tasks = updatedTasks
        clearTriggeredOccurrences(for: id)
        _ = taskAuthorization.revokeAuthorization(for: id)
        tasksNeedingReauthorization.insert(id)
        saveTasks()

        LogManager.shared.warning(
            "已暂停未获授权的自动录音任务，等待用户重新确认 | ID: \(id) | 原因: \(reason)"
        )
        showReauthorizationNotice(count: 1)
    }

    private func showReauthorizationNotice(count: Int) {
        guard count > 0 else { return }
        if reminderController == nil {
            reminderController = ReminderWindowController()
        }
        reminderController?.showTimerTasksNeedReauthorizationNotification(count: count)
    }

    // MARK: - 初始化

    private init() {
        loadTasks()
        setupTimeChangeObserver()
        setupScheduleSettingsObserver()

        LogManager.shared.info("TimerTaskManager 初始化完成 | 任务数量: \(tasks.count)")
    }

    // MARK: - CRUD 操作

    /// 添加任务
    @discardableResult
    func addTask(_ task: TimerTask) -> Bool {
        var newTask = task
        guard !hasTimeConflict(hour: newTask.hour, minute: newTask.minute, excludingTaskID: newTask.id) else {
            LogManager.shared.warning("添加定时任务失败，时间冲突 | 时间: \(newTask.timeDisplay)")
            return false
        }

        newTask.calculateNextTriggerTime()
        guard taskAuthorization.authorizeUserChange(from: nil, to: newTask) else {
            LogManager.shared.warning("添加定时任务失败，无法保存授权 | ID: \(newTask.id)")
            return false
        }
        tasks = tasks + [newTask]
        saveTasks()

        LogManager.shared.info(
            "添加定时任务 | ID: \(task.id) | 时间: \(task.timeDisplay) | 循环: \(task.repeatType.displayName)"
        )

        // 重新调度定时器
        scheduleNextTrigger()
        return true
    }

    /// 更新任务
    @discardableResult
    func updateTask(_ task: TimerTask) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else {
            LogManager.shared.warning("更新任务失败，未找到任务 | ID: \(task.id)")
            return false
        }

        guard !hasTimeConflict(hour: task.hour, minute: task.minute, excludingTaskID: task.id) else {
            LogManager.shared.warning("更新定时任务失败，时间冲突 | ID: \(task.id) | 时间: \(task.timeDisplay)")
            return false
        }

        var updatedTask = task
        updatedTask.updatedAt = Date()

        // 如果用户重新启用了任务，清除上次触发时间，让单次任务可以重新使用
        if updatedTask.enabled {
            updatedTask.lastTriggerTime = nil
        }

        updatedTask.calculateNextTriggerTime()
        guard taskAuthorization.authorizeUserChange(from: tasks[index], to: updatedTask) else {
            LogManager.shared.warning("更新定时任务失败，无法保存授权 | ID: \(updatedTask.id)")
            return false
        }
        var updatedTasks = tasks
        updatedTasks[index] = updatedTask
        tasks = updatedTasks
        tasksNeedingReauthorization.remove(task.id)
        saveTasks()

        // 移除触发记录，允许重新触发
        clearTriggeredOccurrences(for: task.id)

        LogManager.shared.info("更新定时任务 | ID: \(task.id) | 时间: \(task.timeDisplay)")

        // 重新调度定时器
        scheduleNextTrigger()
        return true
    }

    func hasTimeConflict(hour: Int, minute: Int, excludingTaskID: UUID? = nil) -> Bool {
        TimerTaskScheduleValidator.hasTimeConflict(
            tasks: tasks,
            hour: hour,
            minute: minute,
            excludingTaskID: excludingTaskID
        )
    }

    /// 删除任务
    @discardableResult
    func deleteTask(id: UUID) -> Bool {
        guard let existingTask = tasks.first(where: { $0.id == id }) else { return false }
        guard existingTask.actionType != .autoStart
            || taskAuthorization.revokeAuthorization(for: id)
        else {
            LogManager.shared.warning("删除定时任务失败，无法撤销授权 | ID: \(id)")
            return false
        }
        tasks = tasks.filter { $0.id != id }
        clearTriggeredOccurrences(for: id)
        tasksNeedingReauthorization.remove(id)
        saveTasks()

        LogManager.shared.info("删除定时任务 | ID: \(id)")

        // 重新调度定时器
        scheduleNextTrigger()
        return true
    }

    /// 切换任务启用状态
    func toggleTaskEnabled(id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }

        var updatedTasks = tasks
        updatedTasks[index].enabled.toggle()
        updatedTasks[index].updatedAt = Date()

        if updatedTasks[index].enabled {
            // 清除上次触发时间，让单次任务可以重新使用
            updatedTasks[index].lastTriggerTime = nil
            updatedTasks[index].calculateNextTriggerTime()
            clearTriggeredOccurrences(for: id)
        } else {
            updatedTasks[index].nextTriggerTime = nil
        }

        guard taskAuthorization.authorizeUserChange(
            from: tasks[index],
            to: updatedTasks[index]
        ) else {
            LogManager.shared.warning("切换定时任务失败，无法保存授权 | ID: \(id)")
            return
        }
        tasks = updatedTasks
        tasksNeedingReauthorization.remove(id)
        saveTasks()

        LogManager.shared.info("切换任务状态 | ID: \(id) | 启用: \(updatedTasks[index].enabled)")

        // 重新调度定时器
        scheduleNextTrigger()
    }

#if QA_AUTOMATION
    /// QA 产物中的临时授权只存在于当前进程，不写入 Keychain 或用户偏好。
    func authorizeAutomaticRecordingForQAAutomation(_ task: TimerTask) -> Bool {
        guard QAAutomationRunner.isActive,
            task.actionType == .autoStart,
            let digest = TimerTaskAuthorizationDigest.make(for: task)
        else {
            return false
        }
        qaAutomaticRecordingAuthorizationDigests[task.id] = digest
        return true
    }

    func revokeAutomaticRecordingForQAAutomation(taskID: UUID) {
        qaAutomaticRecordingAuthorizationDigests.removeValue(forKey: taskID)
    }
#endif

    // MARK: - 调度器（精准时间触发）

    /// 启动调度器
    func startScheduler() {
        stopScheduler()

        // 立即检查是否有需要触发的任务（处理应用启动时已过期的任务）
        checkAndTriggerReminders()

        // 调度下一个精准触发
        scheduleNextTrigger()

        // 检查并更新睡眠防止状态
        updateSleepPreventionState()

        LogManager.shared.info("定时任务调度器已启动（精准触发模式）")

        // 启动时发现的授权不一致在这里提示，init 阶段窗口还不能显示。
        let noticeCount = pendingReauthorizationNoticeCount
        pendingReauthorizationNoticeCount = 0
        showReauthorizationNotice(count: noticeCount)
    }

    /// 停止调度器
    func stopScheduler() {
        precisionTimer?.cancel()
        precisionTimer = nil
        releaseSleepPrevention()

        LogManager.shared.info("定时任务调度器已停止")
    }

    /// 计算下一个最近的任务触发时间，并设置精准定时器
    private func scheduleNextTrigger() {
        // 取消现有的定时器
        precisionTimer?.cancel()
        precisionTimer = nil

        let now = Date()
        updateSleepPreventionState()

        // 如果某个任务已经进入触发窗口，立即检查，避免因为睡眠/启动延迟漏触发。
        let lateGrace = autoStartLateGrace
        let hasDueTask = tasks.contains { task in
            task.enabled && !isTriggered(task)
                && task.shouldTriggerReminder(at: now, autoStartLateGrace: lateGrace)
        }

        if hasDueTask {
            LogManager.shared.info("检测到已到触发窗口的定时任务，立即检查")
            DispatchQueue.main.async { [weak self] in
                self?.checkAndTriggerReminders()
                self?.scheduleNextTrigger()
            }
            return
        }

        // 找出所有启用且未触发的任务中，最近的下一个实际检查时间。
        // 提醒模式需要提前 reminderMinutes 分钟触发，自动录音则在计划时间触发。
        let nextActionDate =
            tasks
                .filter { $0.enabled && !isTriggered($0) }
            .compactMap { scheduledCheckTime(for: $0) }
            .filter { $0 > now }
            .min()

        guard let targetDate = nextActionDate else {
            LogManager.shared.info("没有待触发的定时任务")
            return
        }

        let interval = targetDate.timeIntervalSince(now)

        // 安全检查：如果间隔太小或为负，立即触发
        if interval <= 0 {
            LogManager.shared.info("下一个任务已到时间，立即触发")
            DispatchQueue.main.async { [weak self] in
                self?.checkAndTriggerReminders()
                self?.scheduleNextTrigger()
            }
            return
        }

        // 格式化时间用于日志
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let targetTimeStr = formatter.string(from: targetDate)

        LogManager.shared.info(
            "设置精准触发 | 目标时间: \(targetTimeStr) | 距离: \(String(format: "%.1f", interval))秒")

        // 创建精准定时器
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + interval, leeway: .milliseconds(100))

        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                self?.checkAndTriggerReminders()
                self?.updateSleepPreventionState()
                // 触发后重新调度下一个任务
                self?.scheduleNextTrigger()
            }
        }

        timer.resume()
        precisionTimer = timer
    }

    /// 返回任务应该被调度器唤醒检查的时间。
    private func scheduledCheckTime(for task: TimerTask) -> Date? {
        guard let next = task.nextTriggerTime else { return nil }

        let leadTimeMinutes = task.actionType == .remind ? task.reminderMinutes : 0
        return next.addingTimeInterval(-Double(leadTimeMinutes) * 60)
    }

    /// 检查并触发提醒或自动录音
    func checkAndTriggerReminders() {
        let now = Date()
        let lateGrace = autoStartLateGrace

        for index in tasks.indices {
            let task = tasks[index]

            // 跳过已禁用或本轮已触发的任务
            guard task.enabled,
                !isTriggered(task),
                task.shouldTriggerReminder(at: now, autoStartLateGrace: lateGrace)
            else {
                continue
            }

            if task.actionType == .autoStart,
                automaticRecordingAuthorizationState(task) == .unauthorized
            {
                disableUnauthorizedAutomaticRecordingTask(
                    id: task.id,
                    reason: "触发前授权校验失败"
                )
                continue
            }

            // 标记本次计划为已触发；任务后续被编辑时，新计划仍可独立触发。
            guard let occurrence = TimerTaskOccurrence(task: task) else { continue }
            triggeredTaskOccurrences.insert(occurrence)

            if task.actionType == .autoStart {
                // 自动录音模式：直接开始录音并显示通知弹窗
                LogManager.shared.info("自动启动录音 | ID: \(task.id) | 时间: \(task.timeDisplay)")

                DispatchQueue.main.async { [weak self] in
                    self?.handleAutoStartRecording(task: task, occurrence: occurrence)
                }
            } else {
                // 提醒模式：显示提醒弹窗
                LogManager.shared.info("触发定时提醒 | ID: \(task.id) | 时间: \(task.timeDisplay)")

                DispatchQueue.main.async { [weak self] in
                    self?.showReminder(for: task)
                }
            }
        }

        // 清理过期的触发记录（已过触发时间且超过5分钟）
        cleanupTriggeredRecords()
    }

    /// 自动开始录音
    private func handleAutoStartRecording(task: TimerTask, occurrence: TimerTaskOccurrence) {
        guard isCurrentOccurrence(occurrence) else {
            clearTriggeredOccurrence(occurrence)
            LogManager.shared.info("自动录音触发前任务已更新，丢弃旧计划 | ID: \(task.id)")
            scheduleNextTrigger()
            return
        }
        guard let currentTask = tasks.first(where: { $0.id == occurrence.taskID }) else {
            clearTriggeredOccurrence(occurrence)
            scheduleNextTrigger()
            return
        }
        switch automaticRecordingAuthorizationState(currentTask) {
        case .authorized:
            break
        case .unauthorized:
            disableUnauthorizedAutomaticRecordingTask(
                id: occurrence.taskID,
                reason: "录音启动前授权校验失败"
            )
            scheduleNextTrigger()
            return
        case .unavailable(let status):
            // Keychain 暂时读不到不等于篡改：不停用任务，按启动失败在补录期内重试。
            handleAutoStartFailure(
                occurrence: occurrence,
                reason: "无法读取自动录音授权记录（错误码 \(status)）"
            )
            return
        }
        let startResult = startRecordingForTimerTask(taskID: task.id, taskDisplay: task.timeDisplay)

        switch startResult {
        case .requested:
            confirmAutoStartRecording(for: task, occurrence: occurrence)
        case .alreadyRecording:
            guard isCurrentOccurrence(occurrence) else {
                clearTriggeredOccurrence(occurrence)
                scheduleNextTrigger()
                return
            }
            markTaskAsTriggered(taskID: occurrence.taskID)
            scheduleNextTrigger()
        case .rejected:
            handleAutoStartFailure(
                occurrence: occurrence,
                reason: "录音启动请求被拒绝"
            )
        }
    }

    /// 定时任务触发时启动录音；若当前正在录音，本次任务直接跳过。
    private func startRecordingForTimerTask(
        taskID: UUID,
        taskDisplay: String
    ) -> TimerRecordingStartResult {
        let recorderManager = AudioRecorderManager.shared

        if recorderManager.recordingState == .starting {
            LogManager.shared.info("录音启动仍在处理中，继续等待 | 任务: \(taskDisplay)")
            return .requested
        }

        if recorderManager.recordingState == .stopping {
            LogManager.shared.info("上一段录音正在保存，稍后重试定时启动 | 任务: \(taskDisplay)")
            return .rejected
        }

        if recorderManager.isRecording {
            LogManager.shared.info("已在录音中，跳过本次定时启动 | 任务: \(taskDisplay)")
            return .alreadyRecording
        }

        guard recorderManager.startRecording() else {
            LogManager.shared.warning("定时任务启动录音失败 | ID: \(taskID)")
            return .rejected
        }

        LogManager.shared.info("定时任务启动录音 | ID: \(taskID)")
        return .requested
    }

    /// 只有在录音真正开始后才显示通知。
    /// 系统音频启动和首次授权都是异步路径，必须给启动过程足够时间完成。
    private func confirmAutoStartRecording(
        for task: TimerTask,
        occurrence: TimerTaskOccurrence,
        remainingAttempts: Int = TimerRecordingStartConfirmationPolicy.maxAttempts
    ) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + TimerRecordingStartConfirmationPolicy.retryInterval
        ) { [weak self] in
            guard let self = self else { return }
            guard self.isCurrentOccurrence(occurrence) else {
                self.clearTriggeredOccurrence(occurrence)
                LogManager.shared.info("自动录音启动确认对应的任务已更新，丢弃旧计划 | ID: \(task.id)")
                self.scheduleNextTrigger()
                return
            }

            switch TimerRecordingStartConfirmationPolicy.decision(
                for: self.currentRecordingStartObservation(),
                remainingAttempts: remainingAttempts
            ) {
            case .confirmed:
                _ = self.markTaskAsTriggered(taskID: occurrence.taskID)
                let lateSeconds = Date().timeIntervalSince(occurrence.scheduledTime)
                let lateMinutes = lateSeconds >= 60 ? Int(lateSeconds / 60) : 0
                if lateMinutes > 0 {
                    LogManager.shared.warning(
                        "自动录音迟到开始 | ID: \(task.id) | 迟到: \(lateMinutes) 分钟")
                }
                self.showAutoStartNotification(for: task, lateMinutes: lateMinutes)
                self.scheduleNextTrigger()
            case .wait:
                self.confirmAutoStartRecording(
                    for: task,
                    occurrence: occurrence,
                    remainingAttempts: remainingAttempts - 1
                )
            case .failed:
                self.handleAutoStartFailure(
                    occurrence: occurrence,
                    reason: "等待录音进入 recording 超时"
                )
            }
        }
    }

    private func currentRecordingStartObservation() -> TimerRecordingStartObservation {
        switch AudioRecorderManager.shared.recordingState {
        case .idle:
            return .idle
        case .starting:
            return .starting
        case .recording, .paused, .stopping:
            return .recording
        }
    }

    /// 自动录音启动失败：补录期内每隔固定间隔重试；补录期结束才推进到下一次并提示用户。
    private func handleAutoStartFailure(
        occurrence: TimerTaskOccurrence,
        reason: String
    ) {
        guard isCurrentOccurrence(occurrence) else {
            clearTriggeredOccurrence(occurrence)
            LogManager.shared.info("自动录音失败回调对应的任务已更新，未推进新计划 | ID: \(occurrence.taskID)")
            scheduleNextTrigger()
            return
        }

        let retryAt = Date().addingTimeInterval(TimerTaskTriggerWindowPolicy.autoStartRetryInterval)
        let windowEnd = occurrence.scheduledTime.addingTimeInterval(autoStartLateGrace)
        if retryAt < windowEnd {
            LogManager.shared.warning(
                "自动录音未能启动，\(Int(TimerTaskTriggerWindowPolicy.autoStartRetryInterval)) 秒后重试 | ID: \(occurrence.taskID) | 原因: \(reason)"
            )
            scheduleAutoStartRetry(occurrence: occurrence)
            return
        }

        if let task = markTaskAsTriggered(taskID: occurrence.taskID) {
            LogManager.shared.error(
                "自动录音在补录期内始终未能启动，本次计划已跳过并推进到下一次 | ID: \(task.id) | 原因: \(reason)"
            )
            if reminderController == nil {
                reminderController = ReminderWindowController()
            }
            reminderController?.showRecordingStartFailedNotification(
                message: "定时计划 \(task.timeDisplay) 的自动录音未能开始，本次已跳过。原因：\(reason)")
        } else {
            clearTriggeredOccurrence(occurrence)
            LogManager.shared.warning(
                "自动录音未能启动，任务已不存在 | ID: \(occurrence.taskID) | 原因: \(reason)")
        }

        scheduleNextTrigger()
    }

    private func scheduleAutoStartRetry(occurrence: TimerTaskOccurrence) {
        autoStartRetryWorkItems[occurrence]?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.autoStartRetryWorkItems.removeValue(forKey: occurrence)
            guard self.isCurrentOccurrence(occurrence),
                let task = self.tasks.first(where: { $0.id == occurrence.taskID })
            else {
                self.clearTriggeredOccurrence(occurrence)
                return
            }
            self.handleAutoStartRecording(task: task, occurrence: occurrence)
        }
        autoStartRetryWorkItems[occurrence] = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + TimerTaskTriggerWindowPolicy.autoStartRetryInterval,
            execute: workItem
        )
    }

    /// 显示自动录音通知（5秒后自动消失）；迟到补录时写明迟到了多久
    private func showAutoStartNotification(for task: TimerTask, lateMinutes: Int) {
        if reminderController == nil {
            reminderController = ReminderWindowController()
        }

        reminderController?.showAutoStartNotification(for: task, lateMinutes: lateMinutes)
    }

    /// 显示提醒弹窗
    private func showReminder(for task: TimerTask) {
        guard let occurrence = TimerTaskOccurrence(task: task) else { return }
        if reminderController == nil {
            reminderController = ReminderWindowController()
        }

        reminderController?.showReminder(
            for: task,
            onIgnore: { [weak self] in
                self?.handleIgnore(occurrence: occurrence)
            },
            onStartRecording: { [weak self] in
                self?.handleStartRecording(occurrence: occurrence)
            }
        )
    }

    /// 处理忽略
    private func handleIgnore(occurrence: TimerTaskOccurrence) {
        guard isCurrentOccurrence(occurrence) else {
            clearTriggeredOccurrence(occurrence)
            LogManager.shared.info("忽略已失效的旧定时提醒 | ID: \(occurrence.taskID)")
            scheduleNextTrigger()
            return
        }
        guard markTaskAsTriggered(taskID: occurrence.taskID) != nil else { return }

        LogManager.shared.info("用户忽略定时提醒 | ID: \(occurrence.taskID)")
        scheduleNextTrigger()
    }

    /// 处理开始录音
    private func handleStartRecording(occurrence: TimerTaskOccurrence) {
        guard isCurrentOccurrence(occurrence) else {
            clearTriggeredOccurrence(occurrence)
            LogManager.shared.info("忽略已失效旧提醒的启动操作 | ID: \(occurrence.taskID)")
            scheduleNextTrigger()
            return
        }
        let taskID = occurrence.taskID
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        let taskDisplay = tasks[index].timeDisplay

        let startResult = startRecordingForTimerTask(taskID: taskID, taskDisplay: taskDisplay)

        switch startResult {
        case .requested:
            confirmReminderStartRecording(occurrence: occurrence)
        case .alreadyRecording:
            _ = markTaskAsTriggered(taskID: taskID)
            scheduleNextTrigger()
        case .rejected:
            LogManager.shared.warning("用户点击开始录音但启动失败，任务保留为未完成 | ID: \(taskID)")
            clearTriggeredOccurrences(for: taskID)
            scheduleNextTrigger()
        }
    }

    /// 提醒窗口的“开始录音”也可能走首次授权或系统音频的异步启动路径。
    /// 只在录音真正进入 recording 后才完成计划；失败时释放触发标记，让用户在窗口期内重试。
    private func confirmReminderStartRecording(
        occurrence: TimerTaskOccurrence,
        remainingAttempts: Int = TimerRecordingStartConfirmationPolicy.maxAttempts
    ) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + TimerRecordingStartConfirmationPolicy.retryInterval
        ) { [weak self] in
            guard let self = self else { return }
            guard self.isCurrentOccurrence(occurrence) else {
                self.clearTriggeredOccurrence(occurrence)
                LogManager.shared.info("录音启动确认对应的提醒已失效 | ID: \(occurrence.taskID)")
                self.scheduleNextTrigger()
                return
            }

            switch TimerRecordingStartConfirmationPolicy.decision(
                for: self.currentRecordingStartObservation(),
                remainingAttempts: remainingAttempts
            ) {
            case .confirmed:
                _ = self.markTaskAsTriggered(taskID: occurrence.taskID)
                self.scheduleNextTrigger()
            case .wait:
                self.confirmReminderStartRecording(
                    occurrence: occurrence,
                    remainingAttempts: remainingAttempts - 1
                )
            case .failed:
                self.clearTriggeredOccurrences(for: occurrence.taskID)
                LogManager.shared.warning(
                    "用户点击开始录音后未能进入 recording，任务未完成 | ID: \(occurrence.taskID)"
                )
                self.scheduleNextTrigger()
            }
        }
    }

    @discardableResult
    private func markTaskAsTriggered(taskID: UUID) -> TimerTask? {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return nil }

        var updatedTasks = tasks
        updatedTasks[index].markAsTriggered()
        let updatedTask = updatedTasks[index]
        tasks = updatedTasks
        clearTriggeredOccurrences(for: taskID)
        saveTasks()
        return updatedTask
    }

    /// 清理过期的触发记录
    private func cleanupTriggeredRecords() {
        let now = Date()

        triggeredTaskOccurrences = triggeredTaskOccurrences.filter { occurrence in
            guard let task = tasks.first(where: { $0.id == occurrence.taskID }),
                TimerTaskOccurrence(task: task) == occurrence
            else {
                return false
            }
            // 保留5分钟窗口内的记录
            return now.timeIntervalSince(occurrence.scheduledTime) < 5 * 60
        }
    }

    // MARK: - 持久化

    /// 加载任务
    private func loadTasks() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            tasks = []
            return
        }

        do {
            let decoder = JSONDecoder()
            var loadedTasks = try decoder.decode([TimerTask].self, from: data)
            var needingReauthorization: Set<UUID> = []
            var disabledUnapprovedTaskCount = 0
            var unavailableAuthorizationCount = 0

            for index in loadedTasks.indices {
                guard loadedTasks[index].actionType == .autoStart else { continue }

                // 保存的触发时间和用户设定不一致，说明不是应用自己写的，重算而不是沿用。
                if !loadedTasks[index].nextTriggerTimeMatchesSchedule() {
                    LogManager.shared.warning(
                        "自动录音任务的下次触发时间与计划不一致，已重算 | ID: \(loadedTasks[index].id)")
                    loadedTasks[index].nextTriggerTime = nil
                }

                switch taskAuthorization.authorizationState(for: loadedTasks[index]) {
                case .authorized:
                    continue
                case .unavailable:
                    // Keychain 读取失败不是篡改，保留任务；触发时会再次校验。
                    unavailableAuthorizationCount += 1
                case .unauthorized:
                    guard loadedTasks[index].enabled else {
                        // 应用内停用的任务仍有授权记录；没有记录的停用任务需要用户重新启用。
                        needingReauthorization.insert(loadedTasks[index].id)
                        continue
                    }
                    loadedTasks[index].enabled = false
                    loadedTasks[index].nextTriggerTime = nil
                    loadedTasks[index].updatedAt = Date()
                    _ = taskAuthorization.revokeAuthorization(for: loadedTasks[index].id)
                    needingReauthorization.insert(loadedTasks[index].id)
                    disabledUnapprovedTaskCount += 1
                }
            }

            refreshTaskSchedules(&loadedTasks, preservingDueTriggersAt: Date())

            // 重新赋值整个数组，触发 @Published 响应式更新
            tasks = loadedTasks
            tasksNeedingReauthorization = needingReauthorization
            pendingReauthorizationNoticeCount = disabledUnapprovedTaskCount

            LogManager.shared.info("加载定时任务成功 | 数量: \(tasks.count)")
            if disabledUnapprovedTaskCount > 0 {
                LogManager.shared.warning(
                    "授权记录与计划不一致的自动录音任务已暂停 | 数量: \(disabledUnapprovedTaskCount) | 需在应用内重新启用"
                )
            }
            if unavailableAuthorizationCount > 0 {
                LogManager.shared.warning(
                    "启动时无法读取自动录音授权记录，任务保留，触发时重新校验 | 数量: \(unavailableAuthorizationCount)"
                )
            }

            // 保存更新后的触发时间到持久化存储
            saveTasks()
        } catch {
            LogManager.shared.error("加载定时任务失败 | 错误: \(error.localizedDescription)")
            tasks = []
        }
    }

    /// 保存任务
    private func saveTasks() {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(tasks)
            UserDefaults.standard.set(data, forKey: storageKey)

            // 保存后更新睡眠防止状态
            updateSleepPreventionState()
        } catch {
            LogManager.shared.error("保存定时任务失败 | 错误: \(error.localizedDescription)")
        }
    }

    /// 刷新任务时间，但保留当前仍处于触发窗口内的任务，避免启动/唤醒时漏掉刚到点的计划。
    private func refreshTaskSchedules(
        _ taskList: inout [TimerTask],
        preservingDueTriggersAt date: Date
    ) {
        let lateGrace = autoStartLateGrace
        for index in taskList.indices {
            let oldTime = taskList[index].nextTriggerTime

            if taskList[index].enabled,
                taskList[index].shouldTriggerReminder(at: date, autoStartLateGrace: lateGrace)
            {
                LogManager.shared.info(
                    "保留待触发任务时间 | ID: \(taskList[index].id.uuidString.prefix(8)) | "
                        + "时间: \(oldTime?.description ?? "nil")"
                )
                continue
            }

            taskList[index].calculateNextTriggerTime()
            let newTime = taskList[index].nextTriggerTime

            if oldTime != newTime {
                LogManager.shared.info(
                    "任务时间更新 | ID: \(taskList[index].id.uuidString.prefix(8)) | "
                        + "旧时间: \(oldTime?.description ?? "nil") | "
                        + "新时间: \(newTime?.description ?? "nil")"
                )
            }
        }
    }

    // MARK: - 时间变化监听

    /// 设置时间变化监听
    private func setupTimeChangeObserver() {
        // 监听系统时间显著变化（时区切换、手动调整等）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTimeChange),
            name: .NSSystemClockDidChange,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTimeChange),
            name: .NSSystemTimeZoneDidChange,
            object: nil
        )

        // 监听系统从休眠恢复
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWakeFromSleep),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func handleTimeChange() {
        LogManager.shared.info("检测到系统时间变化，重新计算所有任务触发时间")

        // 使用临时数组更新后重新赋值，触发 @Published 通知
        var updatedTasks = tasks
        refreshTaskSchedules(&updatedTasks, preservingDueTriggersAt: Date())
        tasks = updatedTasks

        saveTasks()
        checkAndTriggerReminders()
        scheduleNextTrigger()
    }

    @objc private func handleWakeFromSleep() {
        LogManager.shared.info("系统从休眠恢复，检查定时任务")

        // 使用临时数组更新后重新赋值，触发 @Published 通知
        var updatedTasks = tasks
        refreshTaskSchedules(&updatedTasks, preservingDueTriggersAt: Date())
        tasks = updatedTasks

        saveTasks()
        checkAndTriggerReminders()
        scheduleNextTrigger()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        releaseSleepPrevention()
    }

    // MARK: - 睡眠控制

    /// 设置变化监听
    private func setupScheduleSettingsObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScheduleSettingsChanged),
            name: .scheduleSettingsChanged,
            object: nil
        )
    }

    @objc private func handleScheduleSettingsChanged() {
        updateSleepPreventionState()
        scheduleNextTrigger()
    }

    /// 更新睡眠防止状态
    func updateSleepPreventionState() {
        let settings = AppSettings.shared
        let hasEnabledTasks = TimerTaskSleepPreventionPolicy.shouldPreventSleep(tasks: tasks)

        if settings.preventSleepWithSchedule && hasEnabledTasks {
            setupSleepPrevention()
        } else {
            releaseSleepPrevention()
        }
    }

    /// 开启防止休眠断言
    private func setupSleepPrevention() {
        // 已经有断言时不重复创建
        guard sleepAssertionID == 0 else { return }

        let reason = "存在已启用的定时录音计划，保持系统唤醒以确保准点触发。" as CFString
        let result = IOPMAssertionCreateWithDescription(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            "MeetingRecorderProScheduledTask" as CFString,
            reason,
            nil,
            nil,
            0,
            nil,
            &sleepAssertionID
        )

        if result == kIOReturnSuccess {
            LogManager.shared.info("已开启定时计划防休眠断言")
        } else {
            LogManager.shared.warning("开启定时计划防休眠断言失败 | 错误码: \(result)")
        }
    }

    /// 释放防止休眠断言
    private func releaseSleepPrevention() {
        guard sleepAssertionID != 0 else { return }

        let result = IOPMAssertionRelease(sleepAssertionID)
        if result == kIOReturnSuccess {
            LogManager.shared.info("已释放定时计划防休眠断言")
            sleepAssertionID = 0
        } else {
            LogManager.shared.warning("释放定时计划防休眠断言失败 | 错误码: \(result)")
        }
    }
}
