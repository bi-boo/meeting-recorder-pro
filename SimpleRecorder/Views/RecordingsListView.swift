//
//  RecordingsListView.swift
//  极简录音 - 录音列表视图
//

import SwiftUI
import AVFoundation

struct RecordingsListView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var transcriptionManager = TranscriptionManager.shared
    @State private var recordings: [Recording] = []
    @State private var selectedRecording: Recording?
    @State private var audioPlayer: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var playingRecordingId: String?
    
    var body: some View {
        VStack(spacing: 0) {
            // 工具栏
            HStack {
                Text("录音列表")
                    .font(.headline)
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
            } else {
                recordingsList
            }
        }
        .onAppear {
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
        List(recordings) { recording in
            RecordingRow(
                recording: recording,
                transcriptionStatus: getTranscriptionStatus(for: recording),
                isPlaying: playingRecordingId == recording.id,
                onPlay: { togglePlayback(recording) },
                onTranscribe: { startTranscription(recording) }
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
            .filter { ["m4a", "mp3", "wav"].contains($0.pathExtension.lowercased()) }
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
}

// MARK: - Recording Row
struct RecordingRow: View {
    let recording: Recording
    let transcriptionStatus: TranscriptionStatus
    let isPlaying: Bool
    let onPlay: () -> Void
    let onTranscribe: () -> Void
    
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
            
            // 转写按钮
            transcriptionButton
        }
        .padding(.vertical, 8)
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
            Text("已转写")
                .foregroundColor(.secondary)
                .frame(width: 90)
            
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
