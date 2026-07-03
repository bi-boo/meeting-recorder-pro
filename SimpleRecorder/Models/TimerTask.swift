//
//  TimerTask.swift
//  会议录音 Pro - 定时任务数据模型
//
//  Created by AI Assistant
//

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
    func shouldTriggerReminder(at date: Date = Date()) -> Bool {
        guard enabled, let next = nextTriggerTime else { return false }

        let leadTimeMinutes = actionType == .remind ? reminderMinutes : 0

        // 计算触发检查时间
        let triggerCheckTime = next.addingTimeInterval(-Double(leadTimeMinutes) * 60)

        // 检查当前时间是否在触发窗口内（触发检查时间 到 触发时间+1分钟）
        // 给一个1分钟的缓冲窗口防止错过
        let windowEnd = next.addingTimeInterval(60)

        if date >= triggerCheckTime && date < windowEnd {
            // 检查是否已经在本周期触发过
            if let last = lastTriggerTime {
                // 如果上次触发时间与本次触发时间差距小于触发窗口，说明已触发
                return abs(last.timeIntervalSince(next)) > Double(leadTimeMinutes + 1) * 60
            }
            return true
        }

        return false
    }
}
