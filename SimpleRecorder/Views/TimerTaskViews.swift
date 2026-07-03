//
//  TimerTaskViews.swift
//  会议录音 Pro - 定时任务设置视图
//
//  Created by AI Assistant
//

import SwiftUI

// MARK: - 定时计划列表视图

struct TimerTaskListView: View {
    @ObservedObject private var manager = TimerTaskManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var showingAddSheet = false
    @State private var editingTask: TimerTask? = nil

    /// 按绝对时间 (0-24点) 排序的任务列表
    private var sortedTasks: [TimerTask] {
        manager.tasks.sorted { task1, task2 in
            if task1.hour != task2.hour {
                return task1.hour < task2.hour
            }
            return task1.minute < task2.minute
        }
    }

    /// 最大允许的定时计划数量
    private let maxTaskCount = 6

    /// 是否已达到上限
    private var isAtLimit: Bool {
        manager.tasks.count >= maxTaskCount
    }

    var body: some View {
        Form {
            Section {
                if manager.tasks.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "clock.badge.plus")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)

                        Text("还没有定时计划")
                            .font(.headline)

                        Text("添加一个计划，到点自动开始录音")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Button(action: { showingAddSheet = true }) {
                            Label("添加定时计划", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                } else {
                    // 任务列表（按时间早晚排序）
                    ForEach(sortedTasks) { task in
                        TimerTaskRow(task: task)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editingTask = task
                            }
                    }
                    .onDelete(perform: deleteTasks)

                    // 添加按钮（达到上限时禁用）
                    VStack(alignment: .leading, spacing: 4) {
                        Button(action: { showingAddSheet = true }) {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundColor(isAtLimit ? .secondary : .green)
                                Text("添加定时计划")
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isAtLimit)

                        if isAtLimit {
                            Text("最多添加 \(maxTaskCount) 个计划")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.leading, 4)
                        }
                    }
                }
            } header: {
                Text("定时录音计划")
                    .padding(.bottom, 4)
            } footer: {
                Text("定时计划需要电脑处于唤醒状态且应用在后台运行时触发")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // 开机与唤醒开关
            Section {
                Toggle("开机自动启动", isOn: $settings.launchAtLogin)
                    .tint(.green)

                // 录音期间保持唤醒：始终开启且不可修改（仅作为信息展示）
                Toggle("录音期间，保持电脑唤醒", isOn: .constant(true))
                    .tint(.green)
                    .disabled(true)

                Toggle("有启用的定时计划时，保持电脑唤醒", isOn: $settings.preventSleepWithSchedule)
                    .tint(.green)
            } header: {
                Text("开机与唤醒")
                    .padding(.bottom, 4)
            } footer: {
                Text("「录音期间保持唤醒」为强制设置，确保录音完整性，无法关闭")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, SettingsWindowLayout.contentTopPadding)
        .sheet(isPresented: $showingAddSheet) {
            TimerTaskEditView(mode: .add)
        }
        .sheet(item: $editingTask) { task in
            TimerTaskEditView(mode: .edit(task))
        }
    }

    private func deleteTasks(at offsets: IndexSet) {
        for index in offsets {
            let task = sortedTasks[index]
            manager.deleteTask(id: task.id)
        }
    }
}

// MARK: - 任务行视图

struct TimerTaskRow: View {
    let task: TimerTask
    @ObservedObject private var manager = TimerTaskManager.shared

    /// 提醒方式描述（简短版）
    private var triggerModeDescription: String {
        if task.actionType == .autoStart {
            return "自动录音"
        } else {
            return "提前 \(task.reminderMinutes) 分钟提醒"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // 时间显示
            Text(task.timeDisplay)
                .font(.system(size: 24, weight: .medium, design: .monospaced))
                .foregroundColor(task.enabled ? .primary : .secondary)

            Spacer()

            // 右侧信息组
            VStack(alignment: .trailing, spacing: 3) {
                // 下次触发时间
                if task.enabled, task.nextTriggerTime != nil {
                    Text(task.nextTriggerDisplay)
                        .font(.subheadline)
                        .foregroundColor(.orange)
                }

                // 循环方式 + 触发方式
                HStack(spacing: 4) {
                    Text(task.repeatType == .none ? "单次" : task.daysDisplay)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("-")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(triggerModeDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // 编辑入口指示
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)

            // 启用开关
            Toggle(
                "启用",
                isOn: Binding(
                    get: { task.enabled },
                    set: { _ in manager.toggleTaskEnabled(id: task.id) }
                )
            )
            .labelsHidden()
            .tint(.green)
            .accessibilityLabel("启用 \(task.timeDisplay)")
        }
        .padding(.vertical, 6)
        .opacity(task.enabled ? 1 : 0.6)
    }
}

// MARK: - 任务编辑视图

enum TimerTaskEditMode: Identifiable {
    case add
    case edit(TimerTask)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let task): return task.id.uuidString
        }
    }

    var title: String {
        switch self {
        case .add: return "添加定时计划"
        case .edit: return "编辑定时计划"
        }
    }

    var existingTask: TimerTask? {
        switch self {
        case .add: return nil
        case .edit(let task): return task
        }
    }
}

struct TimerTaskEditView: View {
    let mode: TimerTaskEditMode
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var manager = TimerTaskManager.shared

    @State private var enabled: Bool = true
    @State private var selectedDays: Set<Int> = [1, 2, 3, 4, 5]  // 默认工作日
    @State private var hour: Int = 9
    @State private var minute: Int = 0
    @State private var repeatType: RepeatType = .none
    @State private var actionType: TimerActionType = .autoStart
    @State private var reminderMinutes: Int = 2
    @State private var showConflictAlert: Bool = false
    @State private var showMissingDaysAlert: Bool = false

    // 1分钟粒度的分钟选项（方便测试）
    private let minuteOptions = stride(from: 0, to: 60, by: 1).map { $0 }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)

                Spacer()

                Text(mode.title)
                    .font(.headline)

                Spacer()

                Button("保存") { saveTask() }
                    .buttonStyle(.plain)
                    .foregroundColor(.blue)
                    .fontWeight(.semibold)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            Form {
                // 时间选择
                Section("时间") {
                    HStack(spacing: 16) {
                        Picker("小时", selection: $hour) {
                            ForEach(0..<24, id: \.self) { h in
                                Text(String(format: "%02d", h)).tag(h)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 80)

                        Text(":")
                            .font(.title2)
                            .foregroundColor(.secondary)

                        Picker("分钟", selection: $minute) {
                            ForEach(minuteOptions, id: \.self) { m in
                                Text(String(format: "%02d", m)).tag(m)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 80)
                    }
                    .frame(maxWidth: .infinity)
                }

                // 循环类型
                Section("重复") {
                    Picker("循环类型", selection: $repeatType) {
                        ForEach(RepeatType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // 星期选择（仅 weekly 模式显示）
                if repeatType == .weekly {
                    Section("选择星期") {
                        DaysOfWeekPicker(selectedDays: $selectedDays)
                    }
                }

                // 录音方式
                Section("录音方式") {
                    Picker("定时类型", selection: $actionType) {
                        ForEach(TimerActionType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)

                    if actionType == .remind {
                        Picker("提醒时间", selection: $reminderMinutes) {
                            ForEach(1...10, id: \.self) { min in
                                Text("\(min) 分钟").tag(min)
                            }
                        }

                        Text("到达时间前，弹出提示询问是否开始录音")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("到达时间后自动开始录音")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // 启用开关
                Section {
                    Toggle("启用此计划", isOn: $enabled)
                        .tint(.green)
                }

                // 删除按钮（仅编辑模式显示）
                if case .edit = mode {
                    Section {
                        Button(action: { deleteTask() }) {
                            HStack {
                                Spacer()
                                Text("删除此计划")
                                    .foregroundColor(.red)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 400, height: 520)
        .onAppear {
            loadExistingTask()
        }
        .alert("时间冲突", isPresented: $showConflictAlert) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(String(format: "%02d:%02d 已有定时计划，请换一个时间。", hour, minute))
        }
        .alert("请选择星期", isPresented: $showMissingDaysAlert) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("每周重复至少需要选择一天。")
        }
    }

    private func loadExistingTask() {
        guard let task = mode.existingTask else { return }

        enabled = task.enabled
        selectedDays = Set(task.daysOfWeek)
        hour = task.hour
        minute = task.minute
        repeatType = task.repeatType
        actionType = task.actionType
        reminderMinutes = task.reminderMinutes
    }

    private func saveTask() {
        if repeatType == .weekly && selectedDays.isEmpty {
            showMissingDaysAlert = true
            return
        }

        // 检查时间冲突（相同时间点不允许重复）
        let existingTaskID = mode.existingTask?.id
        let hasConflict = manager.tasks.contains { task in
            task.id != existingTaskID && task.hour == hour && task.minute == minute
        }

        if hasConflict {
            showConflictAlert = true
            return
        }

        // 构建任务
        var task: TimerTask

        if let existing = mode.existingTask {
            task = existing
            task.enabled = enabled
            task.daysOfWeek = Array(selectedDays).sorted()
            task.hour = hour
            task.minute = minute
            task.repeatType = repeatType
            task.actionType = actionType
            task.reminderMinutes = reminderMinutes
            task.updatedAt = Date()

            manager.updateTask(task)
        } else {
            task = TimerTask(
                enabled: enabled,
                daysOfWeek: Array(selectedDays).sorted(),
                hour: hour,
                minute: minute,
                repeatType: repeatType,
                actionType: actionType,
                reminderMinutes: reminderMinutes
            )

            manager.addTask(task)
        }

        dismiss()
    }

    private func deleteTask() {
        // 仅在编辑模式下有效
        guard let task = mode.existingTask else { return }
        manager.deleteTask(id: task.id)
        dismiss()
    }
}

// MARK: - 星期选择器

struct DaysOfWeekPicker: View {
    @Binding var selectedDays: Set<Int>

    private let days = [
        (1, "一"),
        (2, "二"),
        (3, "三"),
        (4, "四"),
        (5, "五"),
        (6, "六"),
        (7, "日"),
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(days, id: \.0) { day, name in
                DayButton(
                    name: name,
                    isSelected: selectedDays.contains(day),
                    action: { toggleDay(day) }
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func toggleDay(_ day: Int) {
        if selectedDays.contains(day) {
            selectedDays.remove(day)
        } else {
            selectedDays.insert(day)
        }
    }
}

struct DayButton: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void

    private var accessibilityName: String {
        let mapping: [String: String] = [
            "一": "星期一", "二": "星期二", "三": "星期三",
            "四": "星期四", "五": "星期五", "六": "星期六", "日": "星期日"
        ]
        return mapping[name] ?? name
    }

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(isSelected ? Color.blue : Color.secondary.opacity(0.2))
                )
                .foregroundColor(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSelected ? "\(accessibilityName)，已选" : accessibilityName)
    }
}

// MARK: - 预览

#if DEBUG
    struct TimerTaskListView_Previews: PreviewProvider {
        static var previews: some View {
            TimerTaskListView()
                .frame(width: 560, height: 500)
        }
    }

    struct TimerTaskEditView_Previews: PreviewProvider {
        static var previews: some View {
            TimerTaskEditView(mode: .add)
        }
    }
#endif
