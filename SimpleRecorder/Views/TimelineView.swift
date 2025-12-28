//
//  TimelineView.swift
//  极简录音 - 时间轴视图
//

import SwiftUI

// MARK: - 时间轴数据结构

/// 年节点
struct YearNode: Identifiable {
    let id: Int
    var year: Int { id }
    var months: [MonthNode]
    var recordingCount: Int {
        months.reduce(0) { $0 + $1.recordingCount }
    }
}

/// 月节点
struct MonthNode: Identifiable {
    var id: String { "\(year)-\(month)" }
    let year: Int
    let month: Int
    var days: [DayNode]
    var recordingCount: Int {
        days.reduce(0) { $0 + $1.recordingCount }
    }
}

/// 日节点
struct DayNode: Identifiable {
    var id: String { "\(year)-\(month)-\(day)" }
    let year: Int
    let month: Int
    let day: Int
    var hours: [HourNode]
    var recordingCount: Int {
        hours.reduce(0) { $0 + $1.recordings.count }
    }
}

/// 小时节点
struct HourNode: Identifiable {
    var id: String { "\(year)-\(month)-\(day)-\(hour)" }
    let year: Int
    let month: Int
    let day: Int
    let hour: Int
    var recordings: [Recording]
}

// MARK: - 时间轴视图

struct RecordingTimelineView: View {
    let recordings: [Recording]
    @Binding var selectedTimeKey: String?
    
    @State private var expandedYears: Set<Int> = []
    @State private var expandedMonths: Set<String> = []
    @State private var expandedDays: Set<String> = []
    
    private var yearNodes: [YearNode] {
        buildTimelineTree()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题
            HStack {
                Text("时间轴")
                    .font(.headline)
                Spacer()
                
                // 清除筛选按钮
                if selectedTimeKey != nil {
                    Button(action: { selectedTimeKey = nil }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清除筛选")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // 时间轴列表
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(yearNodes) { yearNode in
                        YearRow(
                            node: yearNode,
                            isExpanded: expandedYears.contains(yearNode.year),
                            expandedMonths: $expandedMonths,
                            expandedDays: $expandedDays,
                            selectedTimeKey: $selectedTimeKey,
                            onToggle: { toggleYear(yearNode.year) }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(minWidth: 140, maxWidth: 180)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            // 默认展开最近的年份
            if let latestYear = yearNodes.first?.year {
                expandedYears.insert(latestYear)
                // 也展开最近的月份
                if let latestMonth = yearNodes.first?.months.first {
                    expandedMonths.insert(latestMonth.id)
                    // 也展开最近的日期
                    if let latestDay = latestMonth.days.first {
                        expandedDays.insert(latestDay.id)
                    }
                }
            }
        }
    }
    
    // MARK: - 构建时间轴树
    private func buildTimelineTree() -> [YearNode] {
        var yearDict: [Int: YearNode] = [:]
        
        for recording in recordings {
            let year = recording.year
            let month = recording.month
            let day = recording.day
            let hour = recording.hour
            
            // 确保年节点存在
            if yearDict[year] == nil {
                yearDict[year] = YearNode(id: year, months: [])
            }
            
            // 查找或创建月节点
            if let monthIndex = yearDict[year]!.months.firstIndex(where: { $0.month == month }) {
                // 查找或创建日节点
                if let dayIndex = yearDict[year]!.months[monthIndex].days.firstIndex(where: { $0.day == day }) {
                    // 查找或创建小时节点
                    if let hourIndex = yearDict[year]!.months[monthIndex].days[dayIndex].hours.firstIndex(where: { $0.hour == hour }) {
                        yearDict[year]!.months[monthIndex].days[dayIndex].hours[hourIndex].recordings.append(recording)
                    } else {
                        let hourNode = HourNode(year: year, month: month, day: day, hour: hour, recordings: [recording])
                        yearDict[year]!.months[monthIndex].days[dayIndex].hours.append(hourNode)
                        yearDict[year]!.months[monthIndex].days[dayIndex].hours.sort { $0.hour > $1.hour }
                    }
                } else {
                    let hourNode = HourNode(year: year, month: month, day: day, hour: hour, recordings: [recording])
                    let dayNode = DayNode(year: year, month: month, day: day, hours: [hourNode])
                    yearDict[year]!.months[monthIndex].days.append(dayNode)
                    yearDict[year]!.months[monthIndex].days.sort { $0.day > $1.day }
                }
            } else {
                let hourNode = HourNode(year: year, month: month, day: day, hour: hour, recordings: [recording])
                let dayNode = DayNode(year: year, month: month, day: day, hours: [hourNode])
                let monthNode = MonthNode(year: year, month: month, days: [dayNode])
                yearDict[year]!.months.append(monthNode)
                yearDict[year]!.months.sort { $0.month > $1.month }
            }
        }
        
        // 按年份降序排列
        return yearDict.values.sorted { $0.year > $1.year }
    }
    
    private func toggleYear(_ year: Int) {
        if expandedYears.contains(year) {
            expandedYears.remove(year)
        } else {
            expandedYears.insert(year)
        }
    }
}

// MARK: - 年份行

struct YearRow: View {
    let node: YearNode
    let isExpanded: Bool
    @Binding var expandedMonths: Set<String>
    @Binding var expandedDays: Set<String>
    @Binding var selectedTimeKey: String?
    let onToggle: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 年份标题
            Button(action: onToggle) {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(width: 12)
                    
                    Text("\(node.year) 年")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    
                    Spacer()
                    
                    Text("\(node.recordingCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(8)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            // 展开的月份
            if isExpanded {
                ForEach(node.months) { monthNode in
                    MonthRow(
                        node: monthNode,
                        isExpanded: expandedMonths.contains(monthNode.id),
                        expandedDays: $expandedDays,
                        selectedTimeKey: $selectedTimeKey,
                        onToggle: { toggleMonth(monthNode.id) }
                    )
                }
            }
        }
    }
    
    private func toggleMonth(_ id: String) {
        if expandedMonths.contains(id) {
            expandedMonths.remove(id)
        } else {
            expandedMonths.insert(id)
        }
    }
}

// MARK: - 月份行

struct MonthRow: View {
    let node: MonthNode
    let isExpanded: Bool
    @Binding var expandedDays: Set<String>
    @Binding var selectedTimeKey: String?
    let onToggle: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 月份标题
            Button(action: onToggle) {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(width: 12)
                    
                    Text("\(node.month) 月")
                        .font(.subheadline)
                    
                    Spacer()
                    
                    Text("\(node.recordingCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.leading, 20)
                .padding(.trailing, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            // 展开的日期
            if isExpanded {
                ForEach(node.days) { dayNode in
                    DayRow(
                        node: dayNode,
                        isExpanded: expandedDays.contains(dayNode.id),
                        selectedTimeKey: $selectedTimeKey,
                        onToggle: { toggleDay(dayNode.id) }
                    )
                }
            }
        }
    }
    
    private func toggleDay(_ id: String) {
        if expandedDays.contains(id) {
            expandedDays.remove(id)
        } else {
            expandedDays.insert(id)
        }
    }
}

// MARK: - 日期行

struct DayRow: View {
    let node: DayNode
    let isExpanded: Bool
    @Binding var selectedTimeKey: String?
    let onToggle: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 日期标题
            Button(action: onToggle) {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(width: 12)
                    
                    Text("\(node.day) 日")
                        .font(.subheadline)
                    
                    Spacer()
                    
                    Text("\(node.recordingCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.leading, 36)
                .padding(.trailing, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            // 展开的小时
            if isExpanded {
                ForEach(node.hours) { hourNode in
                    HourRow(
                        node: hourNode,
                        isSelected: selectedTimeKey == hourNode.id,
                        onSelect: { selectedTimeKey = hourNode.id }
                    )
                }
            }
        }
    }
}

// MARK: - 小时行

struct HourRow: View {
    let node: HourNode
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundColor(isSelected ? .white : .accentColor)
                    .frame(width: 12)
                
                Text(String(format: "%02d:00", node.hour))
                    .font(.system(.caption, design: .monospaced))
                
                Spacer()
                
                Text("\(node.recordings.count)")
                    .font(.caption2)
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
            }
            .padding(.leading, 52)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor : Color.clear)
            .cornerRadius(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    RecordingTimelineView(
        recordings: [],
        selectedTimeKey: .constant(nil)
    )
    .frame(width: 160, height: 400)
}
