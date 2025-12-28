//
//  RecordingsListView.swift
//  极简录音 - 录音列表视图
//

import SwiftUI
import AVFoundation

struct RecordingsListView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var transcriptionManager = TranscriptionManager.shared
    @ObservedObject private var summaryManager = SummaryManager.shared
    @State private var recordings: [Recording] = []
    @State private var selectedRecording: Recording?
    @State private var audioPlayer: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var playingRecordingId: String?
    
    // 播放进度追踪
    @State private var playbackProgress: TimeInterval = 0
    @State private var playbackDuration: TimeInterval = 0
    @State private var playbackTimer: Timer?
    @State private var isDraggingProgress = false  // 是否正在拖动进度条
    @State private var isSeeking = false  // 是否正在调整播放位置
    
    // 时间轴筛选
    @State private var selectedTimeKey: String?
    
    // 根据时间轴筛选后的录音
    private var filteredRecordings: [Recording] {
        guard let timeKey = selectedTimeKey else {
            return recordings
        }
        
        // timeKey 格式可能是:
        // - "年-月" (月份筛选)
        // - "年-月-日" (日期筛选)
        // - "年-月-日-小时" (小时筛选)
        let components = timeKey.split(separator: "-")
        
        return recordings.filter { recording in
            switch components.count {
            case 2:
                // 月份筛选: 年-月
                return recording.year == Int(components[0]) && recording.month == Int(components[1])
            case 3:
                // 日期筛选: 年-月-日
                return recording.year == Int(components[0]) && recording.month == Int(components[1]) && recording.day == Int(components[2])
            case 4:
                // 小时筛选: 年-月-日-小时
                return recording.year == Int(components[0]) && recording.month == Int(components[1]) && recording.day == Int(components[2]) && recording.hour == Int(components[3])
            default:
                return true
            }
        }
    }
    
    var body: some View {
        HStack(spacing: 0) {
            // 左侧：时间轴
            if !recordings.isEmpty {
                RecordingTimelineView(
                    recordings: recordings,
                    selectedTimeKey: $selectedTimeKey
                )
                
                Divider()
            }
            
            // 右侧：录音列表
            VStack(spacing: 0) {
                // 工具栏
                HStack {
                    Text("录音列表")
                        .font(.headline)
                    
                    // 显示筛选状态
                    if selectedTimeKey != nil {
                        Text("(\(filteredRecordings.count) 条)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    Button(action: refreshRecordings) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    
                    Button(action: openRecordingsFolder) {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                
                Divider()
                
                // 列表
                if recordings.isEmpty {
                    emptyState
                } else if filteredRecordings.isEmpty {
                    // 筛选结果为空
                    VStack(spacing: 16) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("该时段无录音")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Button("清除筛选") {
                            selectedTimeKey = nil
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    recordingsList
                }
            }
        }
        .onAppear {
            refreshRecordings()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            // 窗口获得焦点时自动刷新录音列表
            refreshRecordings()
        }
    }
    
    // MARK: - Empty State
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("暂无录音")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("使用快捷键开始录音")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Recordings List
    private var recordingsList: some View {
        List(filteredRecordings) { recording in
            RecordingRow(
                recording: recording,
                transcriptionStatus: getTranscriptionStatus(for: recording),
                summaryStatus: getSummaryStatus(for: recording),
                summary: summaryManager.getSummary(for: recording.fileName),
                isPlaying: playingRecordingId == recording.id,
                playbackProgress: Binding(
                    get: { playingRecordingId == recording.id ? playbackProgress : 0 },
                    set: { newValue in
                        if playingRecordingId == recording.id {
                            playbackProgress = newValue
                        }
                    }
                ),
                playbackDuration: playingRecordingId == recording.id ? playbackDuration : 0,
                isSeeking: $isSeeking,
                onPlay: { togglePlayback(recording) },
                onSeekFinished: { progress in
                    // 用户拖动结束后，跳转到指定位置
                    audioPlayer?.currentTime = progress
                    playbackProgress = progress
                },
                onTranscribe: { startTranscription(recording) },
                onGenerateSummary: { startSummaryGeneration(recording) },
                onDelete: { deleteTranscriptionOnly in deleteRecording(recording, transcriptionOnly: deleteTranscriptionOnly) }
            )
        }
    }
    
    // MARK: - Transcription Status
    private func getTranscriptionStatus(for recording: Recording) -> TranscriptionStatus {
        // 检查是否正在转写
        if transcriptionManager.activeTranscriptions.contains(recording.id) {
            return .transcribing
        }
        
        // 检查是否失败
        if let error = transcriptionManager.failedTranscriptions[recording.id] {
            return .failed(error)
        }
        
        // 检查是否已存在转写文件
        let mdPath = settings.transcriptionsPath.appendingPathComponent(recording.transcriptionFileName)
        if FileManager.default.fileExists(atPath: mdPath.path) {
            return .completed
        }
        
        return .pending
    }
    
    // MARK: - Actions
    private func refreshRecordings() {
        let fileManager = FileManager.default
        let recordingsPath = settings.recordingsPath
        
        guard let files = try? fileManager.contentsOfDirectory(at: recordingsPath, includingPropertiesForKeys: [.creationDateKey]) else {
            recordings = []
            return
        }
        
        recordings = files
            .filter { ["m4a", "mp3", "wav", "aac", "ogg", "flac", "wma", "aiff", "caf"].contains($0.pathExtension.lowercased()) }
            .map { Recording(url: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }
    
    private func openRecordingsFolder() {
        // 跳转到「极简录音」根目录（录音目录的上一级）
        let parentFolder = settings.recordingsPath.deletingLastPathComponent()
        NSWorkspace.shared.open(parentFolder)
    }
    
    private func togglePlayback(_ recording: Recording) {
        if playingRecordingId == recording.id {
            // 停止播放
            stopPlayback()
        } else {
            // 开始播放
            do {
                stopPlayback()
                audioPlayer = try AVAudioPlayer(contentsOf: recording.url)
                audioPlayer?.play()
                playingRecordingId = recording.id
                playbackDuration = audioPlayer?.duration ?? 0
                playbackProgress = 0
                
                // 启动定时器更新进度
                playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                    // 用户正在拖动时，不更新进度（避免覆盖用户输入）
                    guard !isSeeking else { return }
                    
                    if let player = audioPlayer {
                        playbackProgress = player.currentTime
                        // 播放结束时停止
                        if !player.isPlaying && playbackProgress >= playbackDuration - 0.1 {
                            stopPlayback()
                        }
                    }
                }
            } catch {
                print("播放失败: \(error)")
            }
        }
    }
    
    private func stopPlayback() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        audioPlayer?.stop()
        audioPlayer = nil
        playingRecordingId = nil
        playbackProgress = 0
        playbackDuration = 0
    }
    
    private func seekPlayback(to progress: TimeInterval) {
        audioPlayer?.currentTime = progress
        playbackProgress = progress
    }
    
    private func deleteRecording(_ recording: Recording, transcriptionOnly: Bool) {
        let fileManager = FileManager.default
        let transcriptionPath = settings.transcriptionsPath.appendingPathComponent(recording.transcriptionFileName)
        
        // 停止播放（如果正在播放该录音）
        if playingRecordingId == recording.id {
            stopPlayback()
        }
        
        // 删除转录文件
        if fileManager.fileExists(atPath: transcriptionPath.path) {
            try? fileManager.removeItem(at: transcriptionPath)
        }
        
        // 如果不是仅删除转录，也删除录音文件
        if !transcriptionOnly {
            try? fileManager.removeItem(at: recording.url)
        }
        
        // 刷新列表
        refreshRecordings()
    }
    
    private func startTranscription(_ recording: Recording) {
        transcriptionManager.transcribe(recording: recording)
    }
    
    // MARK: - Summary Status
    private func getSummaryStatus(for recording: Recording) -> SummaryStatus {
        // 检查是否正在生成
        if summaryManager.activeSummaries.contains(recording.id) {
            return .generating
        }
        
        // 检查是否失败
        if let error = summaryManager.failedSummaries[recording.id] {
            return .failed(error)
        }
        
        // 检查是否已有总结
        if summaryManager.getSummary(for: recording.fileName) != nil {
            return .completed
        }
        
        return .pending
    }
    
    private func startSummaryGeneration(_ recording: Recording) {
        summaryManager.generateSummary(for: recording)
    }
}

// MARK: - Recording Row
struct RecordingRow: View {
    let recording: Recording
    let transcriptionStatus: TranscriptionStatus
    let summaryStatus: SummaryStatus
    let summary: String?
    let isPlaying: Bool
    @Binding var playbackProgress: TimeInterval
    let playbackDuration: TimeInterval
    @Binding var isSeeking: Bool  // 是否正在拖动进度条
    let onPlay: () -> Void
    let onSeekFinished: (TimeInterval) -> Void  // 拖动结束后的回调
    let onTranscribe: () -> Void
    let onGenerateSummary: () -> Void
    let onDelete: (Bool) -> Void
    
    @ObservedObject private var settings = AppSettings.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 主行内容
            HStack(spacing: 10) {
                // 播放按钮
                Button(action: onPlay) {
                    Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(isPlaying ? .red : .accentColor)
                }
                .buttonStyle(.plain)
                
                // 录音信息
                VStack(alignment: .leading, spacing: 2) {
                    // 文件名（显示原始文件名，去掉扩展名）
                    Text((recording.fileName as NSString).deletingPathExtension)
                        .font(.system(.body, design: .default))
                        .lineLimit(1)
                    
                    // AI 总结（如果有）
                    if let summary = summary {
                        Text(summary)
                            .font(.caption)
                            .foregroundColor(.blue)
                            .lineLimit(1)
                    }
                    
                    // 元信息
                    Text("\(recording.formattedDuration) · \(recording.formattedFileSize)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // 操作按钮组
                actionButtons
            }
            
            // 播放进度条
            if isPlaying && playbackDuration > 0 {
                HStack(spacing: 6) {
                    Text(formatTime(playbackProgress))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                    
                    Slider(
                        value: $playbackProgress,
                        in: 0...playbackDuration,
                        onEditingChanged: { editing in
                            isSeeking = editing
                            // 拖动结束时，跳转到目标位置
                            if !editing {
                                onSeekFinished(playbackProgress)
                            }
                        }
                    )
                    .controlSize(.small)
                    
                    Text(formatTime(playbackDuration))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                        .frame(width: 36, alignment: .leading)
                }
                .padding(.leading, 34)
            }
        }
        .padding(.vertical, 6)
    }
    
    // MARK: - 操作按钮组
    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 4) {
            // 转写/查看按钮
            transcriptionButton
            
            // 更多操作（下拉菜单）
            moreActionsMenu
        }
    }
    
    // MARK: - 更多操作菜单
    @ViewBuilder
    private var moreActionsMenu: some View {
        Menu {
            // 在 Finder 中打开录音
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([recording.url])
            } label: {
                Label("显示录音文件", systemImage: "folder")
            }
            
            // 转录文件相关操作（仅转录完成后显示）
            if case .completed = transcriptionStatus {
                Button {
                    let url = settings.transcriptionsPath.appendingPathComponent(recording.transcriptionFileName)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("显示转录文件", systemImage: "doc.text")
                }
                
                Divider()
                
                // AI 总结
                if settings.isAIConfigured {
                    Button(action: onGenerateSummary) {
                        Label(summary == nil ? "生成 AI 总结" : "重新生成总结", systemImage: "sparkles")
                    }
                }
            }
            
            Divider()
            
            // 删除选项
            if case .completed = transcriptionStatus {
                Button(role: .destructive) {
                    onDelete(true)
                } label: {
                    Label("仅删除转录", systemImage: "doc.text.fill")
                }
            }
            
            Button(role: .destructive) {
                onDelete(false)
            } label: {
                Label("删除录音", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 20, height: 20)
                .rotationEffect(.degrees(90))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)  // 隐藏下拉指示器
        .frame(width: 20)
    }
    // 格式化时间
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    // 在 Finder 中定位转录文件
    private func openTranscriptionInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([transcriptionURL])
    }
    
    // 转写文件路径
    private var transcriptionURL: URL {
        settings.transcriptionsPath.appendingPathComponent(recording.transcriptionFileName)
    }
    
    // 打开转写文件
    private func openTranscription() {
        NSWorkspace.shared.open(transcriptionURL)
    }
    
    @ViewBuilder
    private var transcriptionButton: some View {
        switch transcriptionStatus {
        case .pending:
            Button("转写", action: onTranscribe)
                .buttonStyle(.bordered)
                .controlSize(.small)
            
        case .transcribing:
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.5)
                Text("转写中")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(width: 70)
            
        case .completed:
            Button(action: openTranscription) {
                Text("查看")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.green)
            
        case .failed:
            Button("重试", action: onTranscribe)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
        }
    }
}

// MARK: - Summary Status Enum
enum SummaryStatus {
    case pending
    case generating
    case completed
    case failed(Error)
}

// MARK: - Transcription Status Enum
enum TranscriptionStatus {
    case pending
    case transcribing
    case completed
    case failed(Error)
}

#Preview {
    RecordingsListView()
        .frame(width: 600, height: 400)
}
