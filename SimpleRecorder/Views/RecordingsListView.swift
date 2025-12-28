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
    
    // 时间轴筛选
    @State private var selectedTimeKey: String?
    
    // 根据时间轴筛选后的录音
    private var filteredRecordings: [Recording] {
        guard let timeKey = selectedTimeKey else {
            return recordings
        }
        // timeKey 格式: "年-月-日-小时"
        return recordings.filter { recording in
            let recordingKey = "\(recording.year)-\(recording.month)-\(recording.day)-\(recording.hour)"
            return recordingKey == timeKey
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
                onPlay: { togglePlayback(recording) },
                onTranscribe: { startTranscription(recording) },
                onGenerateSummary: { startSummaryGeneration(recording) }
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
        NSWorkspace.shared.open(settings.recordingsPath)
    }
    
    private func togglePlayback(_ recording: Recording) {
        if playingRecordingId == recording.id {
            // 停止播放
            audioPlayer?.stop()
            audioPlayer = nil
            playingRecordingId = nil
        } else {
            // 开始播放
            do {
                audioPlayer?.stop()
                audioPlayer = try AVAudioPlayer(contentsOf: recording.url)
                audioPlayer?.play()
                playingRecordingId = recording.id
            } catch {
                print("播放失败: \(error)")
            }
        }
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
    let onPlay: () -> Void
    let onTranscribe: () -> Void
    let onGenerateSummary: () -> Void
    
    @ObservedObject private var settings = AppSettings.shared
    
    var body: some View {
        HStack(spacing: 12) {
            // 播放按钮
            Button(action: onPlay) {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundColor(isPlaying ? .red : .accentColor)
            }
            .buttonStyle(.plain)
            
            // 录音信息
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.fileName)
                    .font(.system(.body, design: .default))
                    .lineLimit(1)
                
                // AI 总结显示
                if let summary = summary {
                    HStack(spacing: 4) {
                        Image(systemName: "text.quote")
                            .font(.caption)
                            .foregroundColor(.blue)
                        Text(summary)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }
                }
                
                HStack(spacing: 8) {
                    Text(recording.formattedDate)
                    Text("·")
                    Text(recording.formattedDuration)
                    Text("·")
                    Text(recording.formattedFileSize)
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // 操作按钮组
            HStack(spacing: 8) {
                // 打开文件夹按钮
                Button(action: { openInFinder() }) {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
                .help("在 Finder 中打开")
                
                // 总结按钮/状态（仅转写完成后显示）
                if case .completed = transcriptionStatus {
                    summaryButton
                }
                
                // 转写按钮/状态
                transcriptionButton
            }
        }
        .padding(.vertical, 8)
    }
    
    // 在 Finder 中打开并选中文件
    private func openInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([recording.url])
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
            Button("转写") {
                onTranscribe()
            }
            .buttonStyle(.bordered)
            
        case .transcribing:
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.6)
                Text("转写中...")
                    .foregroundColor(.secondary)
            }
            .frame(width: 90)
            
        case .completed:
            // 已转写：显示查看按钮
            Button(action: openTranscription) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                    Text("查看")
                }
            }
            .buttonStyle(.bordered)
            .tint(.green)
            
        case .failed(let error):
            VStack(alignment: .trailing, spacing: 2) {
                Button(action: onTranscribe) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text("重试")
                    }
                }
                .buttonStyle(.bordered)
                .tint(.red)
                
                Text(error.localizedDescription)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(2)
                    .frame(maxWidth: 150)
            }
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

// MARK: - Summary Button Extension
extension RecordingRow {
    @ViewBuilder
    var summaryButton: some View {
        switch summaryStatus {
        case .pending:
            // 未生成总结：显示生成按钮
            if settings.isAIConfigured {
                Button(action: onGenerateSummary) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                        Text("总结")
                    }
                }
                .buttonStyle(.bordered)
                .tint(.blue)
            }
            
        case .generating:
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.6)
                Text("生成中...")
                    .foregroundColor(.secondary)
            }
            .frame(width: 80)
            
        case .completed:
            // 已有总结：显示重新生成按钮
            if settings.isAIConfigured {
                Button(action: onGenerateSummary) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help("重新生成总结")
            }
            
        case .failed(let error):
            VStack(alignment: .trailing, spacing: 2) {
                Button(action: onGenerateSummary) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("重试")
                    }
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                
                Text(error.localizedDescription)
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .lineLimit(2)
                    .frame(maxWidth: 120)
            }
        }
    }
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
