import AVFoundation
import AppKit
import Foundation

// MARK: - 音频输入设备模型
struct AudioInputDevice: Identifiable, Equatable, Codable {
    var id: String  // UniqueID
    var name: String  // Display Name

    static let defaultDevice = AudioInputDevice(id: "default", name: "系统默认麦克风")
}

// MARK: - 音频源枚举
enum AudioSource: String, CaseIterable, Codable {
    case microphone = "microphone"  // 仅麦克风
    case systemAudio = "system_audio"  // 仅系统音频
    case both = "both"  // 同时录制

    var displayName: String {
        switch self {
        case .microphone: return "录制电脑麦克风"
        case .systemAudio: return "仅录制系统音频"
        case .both: return "麦克风与系统音频"
        }
    }

    var description: String {
        switch self {
        case .microphone: return "录制电脑麦克风输入（如人声、环境音）"
        case .systemAudio: return "录制电脑内部发出的声音（如会议、音乐）"
        case .both: return "同时录制麦克风输入和系统内部声音"
        }
    }
}

class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: - 存储路径设置
    @Published var recordingsPath: URL {
        didSet { savePath(recordingsPath, forKey: "recordingsPath") }
    }

    // MARK: - 录音设置
    @Published var maxDurationHours: Int {
        didSet { UserDefaults.standard.set(maxDurationHours, forKey: "maxDurationHours") }
    }

    @Published var maxDurationMinutes: Int {
        didSet { UserDefaults.standard.set(maxDurationMinutes, forKey: "maxDurationMinutes") }
    }

    var maxRecordingDuration: TimeInterval {
        TimeInterval(maxDurationHours * 3600 + maxDurationMinutes * 60)
    }

    // MARK: - 音频源设置
    @Published var audioSource: AudioSource {
        didSet { UserDefaults.standard.set(audioSource.rawValue, forKey: "audioSource") }
    }

    @Published var availableInputDevices: [AudioInputDevice] = [.defaultDevice]
    @Published var selectedDeviceID: String {
        didSet { UserDefaults.standard.set(selectedDeviceID, forKey: "selectedDeviceID") }
    }

    /// 检测当前系统是否支持系统音频采集（需要 macOS 13.0+）
    static var isSystemAudioSupported: Bool {
        if #available(macOS 13.0, *) {
            return true
        }
        return false
    }

    /// 检测当前是否拥有“屏幕录制”权限
    static var hasScreenCapturePermission: Bool {
        if #available(macOS 14.2, *) {
            return CGPreflightScreenCaptureAccess()
        } else if #available(macOS 13.0, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return true
    }

    /// 触发系统原生权限申请弹窗 (用于确保应用出现在系统权限列表中)
    static func requestScreenCapturePermission() {
        if #available(macOS 10.15, *) {
            // 调用此 API 如果未授权会触发系统弹窗，并将应用加入列表
            CGRequestScreenCaptureAccess()
        }
    }

    /// 打开系统设置中的屏显录制权限页面
    static func openScreenCaptureSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Initialization
    private init() {
        // 默认路径: /Users/用户名/极简录音/录音
        let realHomeDirectory = URL(fileURLWithPath: "/Users/\(NSUserName())")
        let defaultRecordingsPath =
            realHomeDirectory
            .appendingPathComponent("极简录音")
            .appendingPathComponent("录音")

        // 加载路径设置
        if let data = UserDefaults.standard.data(forKey: "recordingsPath"),
            var isStale = Optional(false),
            let url = try? URL(
                resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
                bookmarkDataIsStale: &isStale)
        {
            self.recordingsPath = url
        } else {
            self.recordingsPath = defaultRecordingsPath
        }

        // 加载录音上限设置
        self.maxDurationHours =
            UserDefaults.standard.object(forKey: "maxDurationHours") as? Int ?? 5
        self.maxDurationMinutes =
            UserDefaults.standard.object(forKey: "maxDurationMinutes") as? Int ?? 0

        // 加载音频源设置
        if let savedAudioSource = UserDefaults.standard.string(forKey: "audioSource"),
            let source = AudioSource(rawValue: savedAudioSource)
        {
            // 如果系统版本不支持，强制降级为麦克风模式
            if AppSettings.isSystemAudioSupported || source == .microphone {
                self.audioSource = source
            } else {
                self.audioSource = .microphone
            }
        } else {
            self.audioSource = .microphone  // 默认麦克风
        }

        self.selectedDeviceID =
            UserDefaults.standard.string(forKey: "selectedDeviceID") ?? "default"

        // 初始刷新一次设备列表
        refreshInputDevices()

        // 确保目录存在
        try? FileManager.default.createDirectory(
            at: recordingsPath, withIntermediateDirectories: true)

        print("🔧 AppSettings 初始化完成 (精简版)")
    }

    // MARK: - Path Persistence
    private func savePath(_ url: URL, forKey key: String) {
        if let bookmarkData = try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        {
            UserDefaults.standard.set(bookmarkData, forKey: key)
        }
    }

    // MARK: - Device Management
    func refreshInputDevices() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified)

        let devices = session.devices
        var newDevices = [AudioInputDevice.defaultDevice]

        for device in devices {
            newDevices.append(AudioInputDevice(id: device.uniqueID, name: device.localizedName))
        }

        DispatchQueue.main.async {
            self.availableInputDevices = newDevices
            // 如果当前选中的设备已经不在列表中（比如拔掉了），切回默认
            if self.selectedDeviceID != "default"
                && !newDevices.contains(where: { $0.id == self.selectedDeviceID })
            {
                self.selectedDeviceID = "default"
            }
        }
    }
}
