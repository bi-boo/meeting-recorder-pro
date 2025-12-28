//
//  AudioRecorderManager.swift
//  极简录音 - 录音管理器
//

import Foundation
import AVFoundation
import AppKit

class AudioRecorderManager: NSObject, ObservableObject {
    static let shared = AudioRecorderManager()
    
    @Published var isRecording = false
    @Published var currentRecordingURL: URL?
    @Published var recordingDuration: TimeInterval = 0
    
    private var audioRecorder: AVAudioRecorder?
    private var recordingTimer: Timer?
    
    private override init() {
        super.init()
    }
    
    // MARK: - Recording Control
    func startRecording() {
        // 检查麦克风权限
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                if granted {
                    DispatchQueue.main.async {
                        self?.beginRecording()
                    }
                }
            }
        case .denied, .restricted:
            print("麦克风权限被拒绝")
            showMicrophonePermissionAlert()
        @unknown default:
            break
        }
    }
    
    private func beginRecording() {
        let recordingsPath = AppSettings.shared.recordingsPath
        
        // 确保录音目录存在
        try? FileManager.default.createDirectory(at: recordingsPath, withIntermediateDirectories: true)
        
        // 生成文件名
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let fileName = "录音_\(dateFormatter.string(from: Date())).m4a"
        let fileURL = recordingsPath.appendingPathComponent(fileName)
        
        // 录音设置
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.record()
            
            currentRecordingURL = fileURL
            isRecording = true
            recordingDuration = 0
            
            // 开始计时
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.recordingDuration += 1
            }
            
            NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
            print("开始录音: \(fileURL.path)")
            
        } catch {
            print("录音启动失败: \(error.localizedDescription)")
        }
    }
    
    func stopRecording() {
        audioRecorder?.stop()
        audioRecorder = nil
        
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        isRecording = false
        NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
        
        if let url = currentRecordingURL {
            print("录音已保存: \(url.path)")
            // 打开录音文件所在文件夹并选中文件
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        
        currentRecordingURL = nil
    }
    
    // MARK: - Permission Alert
    private func showMicrophonePermissionAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "需要麦克风权限"
            alert.informativeText = "请在系统设置中允许极简录音访问麦克风"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "取消")
            
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
    
    // MARK: - Helpers
    func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - AVAudioRecorderDelegate
extension AudioRecorderManager: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            print("录音未成功完成")
        }
    }
    
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        if let error = error {
            print("录音编码错误: \(error.localizedDescription)")
        }
    }
}
