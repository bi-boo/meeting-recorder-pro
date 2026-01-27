//
//  TimerTaskManager.swift
//  极简录音 - 定时任务调度管理器
//
//  Created by AI Assistant
//

import AppKit
import Combine
import Foundation
import IOKit.pwr_mgt

// MARK: - 定时任务管理器

/// 定时任务调度管理器（单例模式）
/// 负责任务的 CRUD、持久化存储和调度触发
class TimerTaskManager: ObservableObject {
    static let shared = TimerTaskManager()

    // MARK: - 发布属性

    @Published var tasks: [TimerTask] = []

    // MARK: - 私有属性

    private var schedulerTimer: Timer?
    private let storageKey = "timerTasks"
    private var reminderController: ReminderWindowController?

    // 防止同一任务重复触发的集合
    private var triggeredTaskIDs: Set<UUID> = []

    // 睡眠防止断言 ID
    private var sleepAssertionID: IOPMAssertionID = 0

    // MARK: - 初始化

    private init() {
        loadTasks()
        setupTimeChangeObserver()
        setupScheduleSettingsObserver()

        LogManager.shared.info("TimerTaskManager 初始化完成 | 任务数量: \(tasks.count)")
    }

    // MARK: - CRUD 操作

    /// 添加任务
    func addTask(_ task: TimerTask) {
        var newTask = task
        newTask.calculateNextTriggerTime()
        tasks.append(newTask)
        saveTasks()

        LogManager.shared.info(
            "添加定时任务 | ID: \(task.id) | 时间: \(task.timeDisplay) | 循环: \(task.repeatType.displayName)"
        )
    }

    /// 更新任务
    func updateTask(_ task: TimerTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else {
            LogManager.shared.warning("更新任务失败，未找到任务 | ID: \(task.id)")
            return
        }

        var updatedTask = task
        updatedTask.updatedAt = Date()

        // 如果用户重新启用了任务，清除上次触发时间，让单次任务可以重新使用
        if updatedTask.enabled {
            updatedTask.lastTriggerTime = nil
        }

        updatedTask.calculateNextTriggerTime()
        tasks[index] = updatedTask
        saveTasks()

        // 移除触发记录，允许重新触发
        triggeredTaskIDs.remove(task.id)

        LogManager.shared.info("更新定时任务 | ID: \(task.id) | 时间: \(task.timeDisplay)")
    }

    /// 删除任务
    func deleteTask(id: UUID) {
        tasks.removeAll { $0.id == id }
        triggeredTaskIDs.remove(id)
        saveTasks()

        LogManager.shared.info("删除定时任务 | ID: \(id)")
    }

    /// 切换任务启用状态
    func toggleTaskEnabled(id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }

        tasks[index].enabled.toggle()
        tasks[index].updatedAt = Date()

        if tasks[index].enabled {
            // 清除上次触发时间，让单次任务可以重新使用
            tasks[index].lastTriggerTime = nil
            tasks[index].calculateNextTriggerTime()
            triggeredTaskIDs.remove(id)
        } else {
            tasks[index].nextTriggerTime = nil
        }

        saveTasks()

        LogManager.shared.info("切换任务状态 | ID: \(id) | 启用: \(tasks[index].enabled)")
    }

    // MARK: - 调度器

    /// 启动调度器
    func startScheduler() {
        stopScheduler()

        // 每30秒检查一次（提高响应精度）
        schedulerTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) {
            [weak self] _ in
            self?.checkAndTriggerReminders()
        }

        // 立即执行一次检查
        checkAndTriggerReminders()

        // 检查并更新睡眠防止状态
        updateSleepPreventionState()

        LogManager.shared.info("定时任务调度器已启动")
    }

    /// 停止调度器
    func stopScheduler() {
        schedulerTimer?.invalidate()
        schedulerTimer = nil
        releaseSleepPrevention()

        LogManager.shared.info("定时任务调度器已停止")
    }

    /// 检查并触发提醒或自动录音
    func checkAndTriggerReminders() {
        let now = Date()
        let settings = AppSettings.shared

        for index in tasks.indices {
            let task = tasks[index]

            // 跳过已禁用或本轮已触发的任务
            guard task.enabled,
                !triggeredTaskIDs.contains(task.id),
                task.shouldTriggerReminder(at: now)
            else {
                continue
            }

            // 标记为已触发
            triggeredTaskIDs.insert(task.id)

            if task.actionType == .autoStart {
                // 自动录音模式：直接开始录音并显示通知弹窗
                LogManager.shared.info("自动启动录音 | ID: \(task.id) | 时间: \(task.timeDisplay)")

                DispatchQueue.main.async { [weak self] in
                    self?.handleAutoStartRecording(task: task)
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
    private func handleAutoStartRecording(task: TimerTask) {
        // 标记任务为已触发
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index].markAsTriggered()
            saveTasks()
        }

        // 启动录音
        let recorderManager = AudioRecorderManager.shared
        if !recorderManager.isRecording {
            recorderManager.startRecording()
            LogManager.shared.info("定时任务自动启动录音 | ID: \(task.id)")

            // 显示自动消失的通知弹窗
            showAutoStartNotification(for: task)
        } else {
            LogManager.shared.warning("录音已在进行中，跳过自动启动")
        }
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
        if reminderController == nil {
            reminderController = ReminderWindowController()
        }

        reminderController?.showReminder(
            for: task,
            onIgnore: { [weak self] in
                self?.handleIgnore(taskID: task.id)
            },
            onStartRecording: { [weak self] in
                self?.handleStartRecording(taskID: task.id)
            }
        )
    }

    /// 处理忽略
    private func handleIgnore(taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }

        // 标记为已触发，更新下次时间
        tasks[index].markAsTriggered()
        saveTasks()

        LogManager.shared.info("用户忽略定时提醒 | ID: \(taskID)")
    }

    /// 处理开始录音
    private func handleStartRecording(taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }

        // 标记为已触发
        tasks[index].markAsTriggered()
        saveTasks()

        // 启动录音
        let recorderManager = AudioRecorderManager.shared
        if !recorderManager.isRecording {
            recorderManager.startRecording()
            LogManager.shared.info("定时任务启动录音 | ID: \(taskID)")
        } else {
            LogManager.shared.warning("录音已在进行中，跳过定时启动")
        }
    }

    /// 清理过期的触发记录
    private func cleanupTriggeredRecords() {
        let now = Date()

        triggeredTaskIDs = triggeredTaskIDs.filter { taskID in
            guard let task = tasks.first(where: { $0.id == taskID }),
                let nextTime = task.nextTriggerTime
            else {
                return false
            }
            // 保留5分钟窗口内的记录
            return now.timeIntervalSince(nextTime) < 5 * 60
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

            // 重新计算所有任务的下次触发时间
            // 使用临时数组更新后再赋值，确保触发 @Published 通知
            for index in loadedTasks.indices {
                let oldTime = loadedTasks[index].nextTriggerTime
                loadedTasks[index].calculateNextTriggerTime()
                let newTime = loadedTasks[index].nextTriggerTime

                // 记录时间变化日志，便于调试
                if oldTime != newTime {
                    LogManager.shared.info(
                        "任务时间更新 | ID: \(loadedTasks[index].id.uuidString.prefix(8)) | "
                            + "旧时间: \(oldTime?.description ?? "nil") | "
                            + "新时间: \(newTime?.description ?? "nil")"
                    )
                }
            }

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
        for index in updatedTasks.indices {
            updatedTasks[index].calculateNextTriggerTime()
        }
        tasks = updatedTasks

        // 清空触发记录，重新检查
        triggeredTaskIDs.removeAll()
        saveTasks()
        checkAndTriggerReminders()
    }

    @objc private func handleWakeFromSleep() {
        LogManager.shared.info("系统从休眠恢复，检查定时任务")

        // 使用临时数组更新后重新赋值，触发 @Published 通知
        var updatedTasks = tasks
        for index in updatedTasks.indices {
            updatedTasks[index].calculateNextTriggerTime()
        }
        tasks = updatedTasks

        triggeredTaskIDs.removeAll()
        saveTasks()
        checkAndTriggerReminders()
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
    }

    /// 更新睡眠防止状态
    func updateSleepPreventionState() {
        let settings = AppSettings.shared
        let hasEnabledTasks = tasks.contains { $0.enabled }

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

        let reason = "有已启用的定时录音计划，保持系统唤醒以确保计划触发。" as CFString
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
