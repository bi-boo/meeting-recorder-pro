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

    var body: some View {
        Form {
            Section {
                if manager.tasks.isEmpty {
                    // 空状态
                    VStack(spacing: 12) {
                        Image(systemName: "clock.badge.questionmark")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("暂无定时计划")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("点击下方按钮添加您的第一个定时录音计划")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
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
                }

                // 添加按钮
                Button(action: { showingAddSheet = true }) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.green)
                        Text("添加定时计划")
                    }
                }
                .buttonStyle(.plain)
            } header: {
                Text("定时录音计划")
                    .padding(.bottom, 4)
            } footer: {
                Label("应用需保持运行状态才能触发", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingAddSheet) {
            TimerTaskEditView(mode: .add)
        }
        .sheet(item: $editingTask) { task in
            TimerTaskEditView(mode: .edit(task))
        }
    }

    private func deleteTasks(at offsets: IndexSet) {
        for index in offsets {
            let task = manager.tasks[index]
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
            return "提前\(task.reminderMinutes)分钟"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // 时间显示
            VStack(alignment: .leading, spacing: 4) {
                Text(task.timeDisplay)
                    .font(.system(size: 20, weight: .medium, design: .monospaced))

                // 循环方式 + 提醒方式（同一行）
                HStack(spacing: 6) {
                    Text(task.fullDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("·")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(triggerModeDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(3)
                }
            }

            Spacer()

            // 下次触发时间
            if task.enabled, task.nextTriggerTime != nil {
                Text(task.nextTriggerDisplay)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(6)
            }

            // 启用开关
            Toggle(
                "",
                isOn: Binding(
                    get: { task.enabled },
                    set: { _ in manager.toggleTaskEnabled(id: task.id) }
                )
            )
            .labelsHidden()
            .tint(.green)
        }
        .padding(.vertical, 4)
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
    @State private var repeatType: RepeatType = .weekly
    @State private var actionType: TimerActionType = .remind
    @State private var reminderMinutes: Int = 2

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

                // 定时类型
                Section("触发方式") {
                    Picker("定时类型", selection: $actionType) {
                        ForEach(TimerActionType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)

                    if actionType == .remind {
                        Picker("提前提醒", selection: $reminderMinutes) {
                            ForEach(1...10, id: \.self) { min in
                                Text("\(min) 分钟").tag(min)
                            }
                        }

                        Text("到达时间前弹窗询问是否开始录音")
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
        HStack(spacing: 8) {
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

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(isSelected ? Color.blue : Color.secondary.opacity(0.2))
                )
                .foregroundColor(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
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
