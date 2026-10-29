//
//  TimerTask.swift
//  会议录音 Pro - 定时任务数据模型
//
//  Created by AI Assistant
//

import CryptoKit
import Foundation

// MARK: - 循环类型枚举

/// 定时任务的循环类型
enum RepeatType: String, Codable, CaseIterable {
    case none = "none"  // 不循环，仅触发一次
    case daily = "daily"  // 按天循环，每天触发
    case weekly = "weekly"  // 按周循环，仅在选中的星期触发

    var displayName: String {
        switch self {
        case .none: return "不循环"
        case .daily: return "每天"
        case .weekly: return "每周"
        }
    }
}

// MARK: - 定时行为类型枚举
enum TimerActionType: String, CaseIterable, Codable {
    case remind = "remind"  // 提前提醒模式
    case autoStart = "auto_start"  // 自动开始录音模式

    var displayName: String {
        switch self {
        case .remind: return "到时提醒我"
        case .autoStart: return "自动录音"
        }
    }

    var description: String {
        switch self {
        case .remind: return "提前弹窗询问是否开始录音"
        case .autoStart: return "到时间自动开始录音"
        }
    }
}

// MARK: - 自动录音启动确认

enum TimerRecordingStartObservation: Equatable {
    case idle
    case starting
    case recording
}

enum TimerRecordingStartConfirmationDecision: Equatable {
    case confirmed
    case wait
    case failed
}

struct TimerRecordingStartConfirmationPolicy {
    static let retryInterval: TimeInterval = 0.5
    static let maxAttempts = 60

    static func decision(
        for observation: TimerRecordingStartObservation,
        remainingAttempts: Int
    ) -> TimerRecordingStartConfirmationDecision {
        switch observation {
        case .recording:
            return .confirmed
        case .starting:
            return remainingAttempts > 0 ? .wait : .failed
        case .idle:
            return .failed
        }
    }
}

/// 唯一标识一个任务的某次计划，避免旧提醒回调推进编辑后的新计划。
struct TimerTaskOccurrence: Hashable {
    let taskID: UUID
    let scheduledTime: Date

    init?(task: TimerTask) {
        guard let scheduledTime = task.nextTriggerTime else { return nil }
        self.taskID = task.id
        self.scheduledTime = scheduledTime
    }
}

/// 在没有特权 helper 的前提下，只有持续阻止空闲睡眠才能保证未来计划不会因系统睡眠漏触发。
struct TimerTaskSleepPreventionPolicy {
    static func shouldPreventSleep(tasks: [TimerTask]) -> Bool {
        tasks.contains { $0.enabled && $0.nextTriggerTime != nil }
    }
}

/// 触发窗口：提醒任务保留 1 分钟缓冲；自动录音允许在计划时间后的补录期内迟到开始，
/// 避免系统睡眠或应用未运行超过 1 分钟就直接跳到下一次。
enum TimerTaskTriggerWindowPolicy {
    static let reminderGrace: TimeInterval = 60
    static let defaultAutoStartLateGraceMinutes = 10
    static let minimumAutoStartLateGraceMinutes = 1
    static let maximumAutoStartLateGraceMinutes = 30
    static let autoStartRetryInterval: TimeInterval = 15

    static func clampedAutoStartLateGraceMinutes(_ minutes: Int) -> Int {
        min(max(minutes, minimumAutoStartLateGraceMinutes), maximumAutoStartLateGraceMinutes)
    }
}

struct TimerReminderPresentationPolicy {
    static func timeout(for task: TimerTask, at date: Date = Date()) -> TimeInterval {
        let configuredTimeout = Double(task.reminderMinutes) * 60
        guard let nextTriggerTime = task.nextTriggerTime else { return configuredTimeout }
        return max(0, min(configuredTimeout, nextTriggerTime.timeIntervalSince(date)))
    }
}

enum TimerTaskScheduleValidator {
    static func hasTimeConflict(
        tasks: [TimerTask],
        hour: Int,
        minute: Int,
        excludingTaskID: UUID? = nil
    ) -> Bool {
        tasks.contains { task in
            task.id != excludingTaskID && task.hour == hour && task.minute == minute
        }
    }
}

// MARK: - 定时任务模型

/// 定时录音任务模型
struct TimerTask: Identifiable, Codable, Equatable {
    var id: UUID
    var enabled: Bool
    var daysOfWeek: [Int]  // 1=周一 ... 7=周日
    var hour: Int  // 0-23
    var minute: Int  // 0-59 (1分钟粒度，方便测试)
    var repeatType: RepeatType
    var actionType: TimerActionType  // 定时类型：提醒或自动录音
    var reminderMinutes: Int  // 提前提醒分钟数（1-10）
    var nextTriggerTime: Date?
    var lastTriggerTime: Date?
    var createdAt: Date
    var updatedAt: Date

    // MARK: - 初始化

    init(
        id: UUID = UUID(),
        enabled: Bool = true,
        daysOfWeek: [Int] = [],
        hour: Int = 9,
        minute: Int = 0,
        repeatType: RepeatType = .weekly,
        actionType: TimerActionType = .remind,
        reminderMinutes: Int = 2
    ) {
        self.id = id
        self.enabled = enabled
        self.daysOfWeek = daysOfWeek.sorted()
        self.hour = max(0, min(23, hour))
        self.minute = max(0, min(59, minute))
        self.repeatType = repeatType
        self.actionType = actionType
        self.reminderMinutes = max(1, min(10, reminderMinutes))
        self.createdAt = Date()
        self.updatedAt = Date()
        self.nextTriggerTime = nil
        self.lastTriggerTime = nil

        // 初始化时计算下一次触发时间
        calculateNextTriggerTime()
    }

    // MARK: - 显示属性

    /// 时间显示（如 "09:30"）
    var timeDisplay: String {
        return String(format: "%02d:%02d", hour, minute)
    }

    /// 星期显示（如 "周一、周三、周五"）
    var daysDisplay: String {
        if repeatType == .daily {
            return "每天"
        }

        if daysOfWeek.isEmpty {
            return "未选择"
        }

        let dayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        let selectedDays = daysOfWeek.compactMap { day -> String? in
            guard day >= 1, day <= 7 else { return nil }
            return dayNames[day - 1]
        }

        // 如果选择了全部7天
        if selectedDays.count == 7 {
            return "每天"
        }

        // 如果选择了工作日
        if daysOfWeek.sorted() == [1, 2, 3, 4, 5] {
            return "工作日"
        }

        // 如果选择了周末
        if daysOfWeek.sorted() == [6, 7] {
            return "周末"
        }

        return selectedDays.joined(separator: "、")
    }

    /// 完整描述（如 "每周 周一、周三 09:30"）
    var fullDescription: String {
        switch repeatType {
        case .none:
            if let next = nextTriggerTime {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "zh_CN")
                formatter.dateFormat = "M月d日 HH:mm"
                return "单次 \(formatter.string(from: next))"
            }
            return "单次 \(timeDisplay)"
        case .daily:
            return "每天 \(timeDisplay)"
        case .weekly:
            return "\(daysDisplay) \(timeDisplay)"
        }
    }

    /// 下次触发时间显示
    var nextTriggerDisplay: String {
        guard let next = nextTriggerTime else {
            return "未计划"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")

        let calendar = Calendar.current
        if calendar.isDateInToday(next) {
            formatter.dateFormat = "今天 HH:mm"
        } else if calendar.isDateInTomorrow(next) {
            formatter.dateFormat = "明天 HH:mm"
        } else {
            formatter.dateFormat = "M月d日 HH:mm"
        }

        return formatter.string(from: next)
    }

    // MARK: - 时间计算

    /// 计算下一次触发时间
    mutating func calculateNextTriggerTime() {
        guard enabled else {
            nextTriggerTime = nil
            return
        }

        let calendar = Calendar.current
        let now = Date()

        switch repeatType {
        case .none:
            // 单次任务：如果已触发过，则不再触发
            if lastTriggerTime != nil {
                nextTriggerTime = nil
                enabled = false
                return
            }
            // 计算最近的下一次时间点
            nextTriggerTime = calculateNextOccurrence(from: now, calendar: calendar)

        case .daily:
            // 每天触发：找到下一个该时间点
            nextTriggerTime = calculateNextOccurrence(from: now, calendar: calendar)

        case .weekly:
            // 按周触发：找到下一个符合星期的时间点
            nextTriggerTime = calculateNextWeeklyOccurrence(from: now, calendar: calendar)
        }

        updatedAt = Date()
    }

    /// 计算下一个时间点（用于 daily 和 none）
    private func calculateNextOccurrence(from date: Date, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = hour
        components.minute = minute
        components.second = 0

        guard let targetTime = calendar.date(from: components) else {
            return nil
        }

        // 如果今天的时间已过，则推到明天
        if targetTime <= date {
            return calendar.date(byAdding: .day, value: 1, to: targetTime)
        }

        return targetTime
    }

    /// 计算下一个符合星期的时间点（用于 weekly）
    private func calculateNextWeeklyOccurrence(from date: Date, calendar: Calendar) -> Date? {
        guard !daysOfWeek.isEmpty else { return nil }

        // 获取今天是周几（1=周日 ... 7=周六 → 转换为 1=周一 ... 7=周日）
        let currentWeekday = calendar.component(.weekday, from: date)
        let adjustedWeekday = currentWeekday == 1 ? 7 : currentWeekday - 1

        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = hour
        components.minute = minute
        components.second = 0

        guard let todayTarget = calendar.date(from: components) else {
            return nil
        }

        // 检查今天是否是选中的日子，且时间未过
        if daysOfWeek.contains(adjustedWeekday) && todayTarget > date {
            return todayTarget
        }

        // 查找未来7天内的下一个符合条件的日子
        for offset in 1...7 {
            let futureWeekday = ((adjustedWeekday - 1 + offset) % 7) + 1
            if daysOfWeek.contains(futureWeekday) {
                return calendar.date(byAdding: .day, value: offset, to: todayTarget)
            }
        }

        return nil
    }

    /// 触发后更新（调用此方法表示任务已触发）
    mutating func markAsTriggered() {
        let completedTriggerTime = nextTriggerTime
        lastTriggerTime = Date()

        // 重新计算下一次触发时间
        switch repeatType {
        case .none:
            // 单次任务：禁用
            enabled = false
            nextTriggerTime = nil
        case .daily, .weekly:
            // 循环任务：基于本次计划时间之后计算下一轮。
            // 提前提醒会在计划时间前触发，不能用当前时间重新计算，否则会再次指向本次计划时间。
            let calendar = Calendar.current
            let referenceDate = completedTriggerTime?.addingTimeInterval(1) ?? Date()
            switch repeatType {
            case .daily:
                nextTriggerTime = calculateNextOccurrence(from: referenceDate, calendar: calendar)
            case .weekly:
                nextTriggerTime = calculateNextWeeklyOccurrence(
                    from: referenceDate, calendar: calendar)
            case .none:
                break
            }
        }

        updatedAt = Date()
    }

    /// 检查是否应该触发（根据任务自己的定时类型和提醒时间）
    /// - Parameter autoStartLateGrace: 自动录音在计划时间之后仍允许补录的秒数
    func shouldTriggerReminder(
        at date: Date = Date(),
        autoStartLateGrace: TimeInterval = Double(
            TimerTaskTriggerWindowPolicy.defaultAutoStartLateGraceMinutes) * 60
    ) -> Bool {
        guard enabled, let next = nextTriggerTime else { return false }

        let leadTimeMinutes = actionType == .remind ? reminderMinutes : 0

        // 计算触发检查时间
        let triggerCheckTime = next.addingTimeInterval(-Double(leadTimeMinutes) * 60)
        let windowEnd = next.addingTimeInterval(
            actionType == .autoStart
                ? autoStartLateGrace : TimerTaskTriggerWindowPolicy.reminderGrace)

        guard date >= triggerCheckTime && date < windowEnd else { return false }

        // 上次触发落在本次计划的窗口内，说明本次已经处理过（含迟到补录）。
        if let last = lastTriggerTime, last >= triggerCheckTime {
            return false
        }
        return true
    }

    /// 持久化的下次触发时间必须和用户设定的时间、星期一致；
    /// 外部改写 UserDefaults 把时间挪到当前时刻时，启动时会重算而不是直接触发。
    func nextTriggerTimeMatchesSchedule(calendar: Calendar = .current) -> Bool {
        guard let next = nextTriggerTime else { return true }
        let components = calendar.dateComponents([.hour, .minute, .weekday], from: next)
        guard components.hour == hour, components.minute == minute else { return false }
        guard repeatType == .weekly, let weekday = components.weekday else { return true }
        let adjustedWeekday = weekday == 1 ? 7 : weekday - 1
        return daysOfWeek.contains(adjustedWeekday)
    }
}

// MARK: - 自动录音任务授权

/// 授权只覆盖用户在应用内设定的字段。调度器维护的 nextTriggerTime、lastTriggerTime
/// 和 updatedAt 不进入摘要，所以触发、唤醒和时间变化都不需要重写 Keychain，
/// 也不会因为两份持久化状态错开而误判为篡改。绕过应用改写时间、星期、动作或启用状态仍会使授权失效。
enum TimerTaskAuthorizationDigest {
    private struct AuthorizedFields: Encodable {
        let id: UUID
        let enabled: Bool
        let daysOfWeek: [Int]
        let hour: Int
        let minute: Int
        let repeatType: RepeatType
        let actionType: TimerActionType
        let reminderMinutes: Int
    }

    static func make(for task: TimerTask) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let fields = AuthorizedFields(
            id: task.id,
            enabled: task.enabled,
            daysOfWeek: task.daysOfWeek,
            hour: task.hour,
            minute: task.minute,
            repeatType: task.repeatType,
            actionType: task.actionType,
            reminderMinutes: task.reminderMinutes
        )
        guard let encodedFields = try? encoder.encode(fields) else { return nil }
        return Data(SHA256.hash(data: encodedFields))
    }
}

/// 读取授权记录的结果。读取失败（Keychain 暂时不可用）和没有记录必须区分：
/// 前者不能当作篡改去停用任务。
enum TimerTaskAuthorizationLookup: Equatable {
    case found(Data)
    case notFound
    case unavailable(status: Int32)
}

enum TimerTaskAuthorizationState: Equatable {
    case authorized
    case unauthorized
    case unavailable(status: Int32)
}

protocol TimerTaskAuthorizationStore: AnyObject {
    func authorizationDigest(for taskID: UUID) -> TimerTaskAuthorizationLookup
    func setAuthorizationDigest(_ digest: Data, for taskID: UUID) -> Bool
    func removeAuthorization(for taskID: UUID) -> Bool
}

struct TimerTaskAuthorizationController {
    private let store: TimerTaskAuthorizationStore

    init(store: TimerTaskAuthorizationStore) {
        self.store = store
    }

    func authorizationState(for task: TimerTask) -> TimerTaskAuthorizationState {
        guard task.actionType == .autoStart,
            let expectedDigest = TimerTaskAuthorizationDigest.make(for: task)
        else {
            return .unauthorized
        }

        switch store.authorizationDigest(for: task.id) {
        case .found(let storedDigest):
            return storedDigest == expectedDigest ? .authorized : .unauthorized
        case .notFound:
            return .unauthorized
        case .unavailable(let status):
            return .unavailable(status: status)
        }
    }

    func isAuthorizedForAutomaticRecording(_ task: TimerTask) -> Bool {
        authorizationState(for: task) == .authorized
    }

    /// 用户在应用内新增、编辑或启停任务时同步授权边界。
    /// 纯提醒任务不依赖 Keychain；从自动录音改为提醒时必须先撤销旧授权。
    func authorizeUserChange(from previousTask: TimerTask?, to task: TimerTask) -> Bool {
        if task.actionType == .autoStart {
            return synchronizeAutomaticRecordingState(task)
        }
        if previousTask?.actionType == .autoStart {
            return store.removeAuthorization(for: task.id)
        }
        return true
    }

    /// 只在应用内的用户操作后写入授权记录。
    func synchronizeAutomaticRecordingState(_ task: TimerTask) -> Bool {
        guard task.actionType == .autoStart else { return false }
        guard let digest = TimerTaskAuthorizationDigest.make(for: task) else {
            return false
        }
        return store.setAuthorizationDigest(digest, for: task.id)
    }

    func revokeAuthorization(for taskID: UUID) -> Bool {
        store.removeAuthorization(for: taskID)
    }
}
