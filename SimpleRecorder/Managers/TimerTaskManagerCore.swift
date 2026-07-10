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

private enum TimerRecordingStartResult {
    case requested
    case alreadyRecording
    case rejected
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
    private var reminderController: ReminderWindowController?

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
    }

    private func clearTriggeredOccurrence(_ occurrence: TimerTaskOccurrence) {
        triggeredTaskOccurrences.remove(occurrence)
    }

    private func isCurrentOccurrence(_ occurrence: TimerTaskOccurrence) -> Bool {
        guard let task = tasks.first(where: { $0.id == occurrence.taskID }) else { return false }
        return TimerTaskOccurrence(task: task) == occurrence
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
        var updatedTasks = tasks
        updatedTasks[index] = updatedTask
        tasks = updatedTasks
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
    func deleteTask(id: UUID) {
        tasks = tasks.filter { $0.id != id }
        clearTriggeredOccurrences(for: id)
        saveTasks()

        LogManager.shared.info("删除定时任务 | ID: \(id)")

        // 重新调度定时器
        scheduleNextTrigger()
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

        tasks = updatedTasks
        saveTasks()

        LogManager.shared.info("切换任务状态 | ID: \(id) | 启用: \(updatedTasks[index].enabled)")

        // 重新调度定时器
        scheduleNextTrigger()
    }

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
        let hasDueTask = tasks.contains { task in
            task.enabled && !isTriggered(task) && task.shouldTriggerReminder(at: now)
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

        for index in tasks.indices {
            let task = tasks[index]

            // 跳过已禁用或本轮已触发的任务
            guard task.enabled,
                !isTriggered(task),
                task.shouldTriggerReminder(at: now)
            else {
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
            markAutoStartTaskAsMissed(
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
                self.showAutoStartNotification(for: task)
                self.scheduleNextTrigger()
            case .wait:
                self.confirmAutoStartRecording(
                    for: task,
                    occurrence: occurrence,
                    remainingAttempts: remainingAttempts - 1
                )
            case .failed:
                self.markAutoStartTaskAsMissed(
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

    private func markAutoStartTaskAsMissed(
        occurrence: TimerTaskOccurrence,
        reason: String
    ) {
        guard isCurrentOccurrence(occurrence) else {
            clearTriggeredOccurrence(occurrence)
            LogManager.shared.info("自动录音失败回调对应的任务已更新，未推进新计划 | ID: \(occurrence.taskID)")
            scheduleNextTrigger()
            return
        }

        if let task = markTaskAsTriggered(taskID: occurrence.taskID) {
            LogManager.shared.warning(
                "自动录音未能启动，本次计划已跳过并推进到下一次 | ID: \(task.id) | 原因: \(reason)"
            )
        } else {
            clearTriggeredOccurrence(occurrence)
            LogManager.shared.warning(
                "自动录音未能启动，任务已不存在 | ID: \(occurrence.taskID) | 原因: \(reason)")
        }

        scheduleNextTrigger()
    }

    /// 显示自动录音通知（5秒后自动消失）
    private func showAutoStartNotification(for task: TimerTask) {
        if reminderController == nil {
            reminderController = ReminderWindowController()
        }

        reminderController?.showAutoStartNotification(for: task)
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

            refreshTaskSchedules(&loadedTasks, preservingDueTriggersAt: Date())

            // 重新赋值整个数组，触发 @Published 响应式更新
            tasks = loadedTasks

            LogManager.shared.info("加载定时任务成功 | 数量: \(tasks.count)")

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
        for index in taskList.indices {
            let oldTime = taskList[index].nextTriggerTime

            if taskList[index].enabled, taskList[index].shouldTriggerReminder(at: date) {
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
