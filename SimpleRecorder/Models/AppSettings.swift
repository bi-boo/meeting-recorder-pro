import AVFoundation
import AppKit
import CoreAudio
import Foundation
import ScreenCaptureKit
import ServiceManagement

// MARK: - 音频输入设备模型
struct AudioInputDevice: Identifiable, Equatable, Codable {
    var id: String  // UniqueID
    var name: String  // Display Name

    static let defaultDevice = AudioInputDevice(id: "default", name: "系统默认")
}

// MARK: - 音频源枚举
enum AudioSource: String, CaseIterable, Codable {
    case microphone = "microphone"  // 仅麦克风
    case systemAudio = "system_audio"  // 仅系统音频
    case both = "both"  // 同时录制

    var displayName: String {
        switch self {
        case .microphone: return "仅麦克风"
        case .systemAudio: return "仅系统声音"
        case .both: return "麦克风 + 系统声音"
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

// MARK: - 输出格式枚举
enum OutputFormat: String, CaseIterable, Codable {
    case m4a = "m4a"
    case mp3 = "mp3"

    var displayName: String {
        switch self {
        case .m4a: return "M4A"
        case .mp3: return "MP3"
        }
    }
}

// MARK: - 图标样式枚举
enum IconStyle: String, CaseIterable, Codable {
    case microphone = "microphone"  // 麦克风
    case circleDot = "circle_dot"  // 圆圈点
    case waveform = "waveform"  // 波形图

    var displayName: String {
        switch self {
        case .microphone: return "麦克风"
        case .circleDot: return "指示点"
        case .waveform: return "波形图"
        }
    }

    var symbolName: String {
        switch self {
        case .microphone: return "mic.fill"
        case .circleDot: return "record.circle"
        case .waveform: return "waveform"
        }
    }
}

// MARK: - 定时行为类型枚举
enum TimerActionType: String, CaseIterable, Codable {
    case remind = "remind"  // 提前提醒模式
    case autoStart = "auto_start"  // 自动开始录音模式

    var displayName: String {
        switch self {
        case .remind: return "提前提醒"
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

    // MARK: - 输出格式设置
    @Published var outputFormat: OutputFormat {
        didSet { UserDefaults.standard.set(outputFormat.rawValue, forKey: "outputFormat") }
    }

    // MARK: - 行为设置
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            updateLaunchAtLogin(launchAtLogin)
        }
    }

    @Published var openFolderAfterRecording: Bool {
        didSet {
            UserDefaults.standard.set(openFolderAfterRecording, forKey: "openFolderAfterRecording")
        }
    }

    @Published var dimIconWhenIdle: Bool {
        didSet {
            UserDefaults.standard.set(dimIconWhenIdle, forKey: "dimIconWhenIdle")
            NotificationCenter.default.post(name: .iconStyleChanged, object: nil)
        }
    }

    @Published var showDurationWhenRecording: Bool {
        didSet {
            UserDefaults.standard.set(
                showDurationWhenRecording, forKey: "showDurationWhenRecording")
            NotificationCenter.default.post(name: .iconStyleChanged, object: nil)
        }
    }

    @Published var iconStyle: IconStyle {
        didSet {
            UserDefaults.standard.set(iconStyle.rawValue, forKey: "iconStyle")
            NotificationCenter.default.post(name: .iconStyleChanged, object: nil)
        }
    }

    @Published var availableInputDevices: [AudioInputDevice] = [.defaultDevice]
    @Published var selectedDeviceID: String {
        didSet { UserDefaults.standard.set(selectedDeviceID, forKey: "selectedDeviceID") }
    }

    // MARK: - 定时录音设置
    @Published var timerActionType: TimerActionType {
        didSet { UserDefaults.standard.set(timerActionType.rawValue, forKey: "timerActionType") }
    }

    @Published var timerReminderMinutes: Int {
        didSet { UserDefaults.standard.set(timerReminderMinutes, forKey: "timerReminderMinutes") }
    }

    // MARK: - 睡眠控制设置
    @Published var preventSleepDuringRecording: Bool {
        didSet {
            UserDefaults.standard.set(
                preventSleepDuringRecording, forKey: "preventSleepDuringRecording")
        }
    }

    @Published var preventSleepWithSchedule: Bool {
        didSet {
            UserDefaults.standard.set(preventSleepWithSchedule, forKey: "preventSleepWithSchedule")
            // 发送通知让 TimerTaskManager 更新睡眠状态
            NotificationCenter.default.post(name: .scheduleSettingsChanged, object: nil)
        }
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
        if #available(macOS 14.2, *) {
            // macOS 14.2+ 推荐先尝试触发内容获取
            triggerScreenCapturePermissionCheck()
            CGRequestScreenCaptureAccess()
        } else if #available(macOS 10.15, *) {
            // 旧版本直接调用此 API
            CGRequestScreenCaptureAccess()
        }
    }

    /// 【核心优化】主动触发 ScreenCaptureKit 的资源获取
    /// 这会强制系统发现应用需要“屏幕录制”权限，从而将其加入权限列表，而不仅仅是弹窗
    static func triggerScreenCapturePermissionCheck() {
        if #available(macOS 13.0, *) {
            // 获取可共享内容是一个轻量操作，但在未授权时会触发系统记录该应用
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) {
                _, error in
                if let error = error {
                    LogManager.shared.debug(
                        "ScreenCaptureKit 权限预检触发结果: \(error.localizedDescription)")
                } else {
                    LogManager.shared.debug("ScreenCaptureKit 权限预检触发成功")
                }
            }
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
        // 默认路径: /Users/用户名/会议录音 Pro
        let realHomeDirectory = URL(fileURLWithPath: "/Users/\(NSUserName())")
        let defaultRecordingsPath =
            realHomeDirectory
            .appendingPathComponent("会议录音 Pro")

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
            UserDefaults.standard.object(forKey: "maxDurationHours") as? Int ?? 3
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

        // 加载输出格式设置
        if let savedFormat = UserDefaults.standard.string(forKey: "outputFormat"),
            let format = OutputFormat(rawValue: savedFormat)
        {
            self.outputFormat = format
        } else {
            self.outputFormat = .m4a  // 默认 M4A
        }

        // 加载行为设置
        self.launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
        self.openFolderAfterRecording =
            UserDefaults.standard.object(forKey: "openFolderAfterRecording") as? Bool ?? true  // 默认开启
        self.dimIconWhenIdle = UserDefaults.standard.bool(forKey: "dimIconWhenIdle")
        self.showDurationWhenRecording =
            UserDefaults.standard.object(forKey: "showDurationWhenRecording") as? Bool ?? true  // 默认开启

        // 加载图标样式设置
        if let savedIconStyle = UserDefaults.standard.string(forKey: "iconStyle"),
            let style = IconStyle(rawValue: savedIconStyle)
        {
            self.iconStyle = style
        } else {
            self.iconStyle = .microphone  // 默认麦克风
        }

        // 加载定时录音设置
        if let savedTimerAction = UserDefaults.standard.string(forKey: "timerActionType"),
            let actionType = TimerActionType(rawValue: savedTimerAction)
        {
            self.timerActionType = actionType
        } else {
            self.timerActionType = .remind  // 默认提前提醒模式
        }
        self.timerReminderMinutes =
            UserDefaults.standard.object(forKey: "timerReminderMinutes") as? Int ?? 2  // 默认2分钟

        // 加载睡眠控制设置
        self.preventSleepDuringRecording =
            UserDefaults.standard.object(forKey: "preventSleepDuringRecording") as? Bool ?? true  // 默认开启
        self.preventSleepWithSchedule =
            UserDefaults.standard.object(forKey: "preventSleepWithSchedule") as? Bool ?? true  // 默认开启

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
            let deviceName = device.localizedName
            let deviceUID = device.uniqueID

            // 使用 Core Audio 检测设备传输类型
            let isPhysical = isPhysicalAudioDevice(uid: deviceUID)

            if isPhysical {
                newDevices.append(AudioInputDevice(id: deviceUID, name: deviceName))
            }
        }

        // 同步更新设备列表（确保菜单栏可以立即获取）
        self.availableInputDevices = newDevices
        // 如果当前选中的设备已经不在列表中（比如拔掉了），切回默认
        if self.selectedDeviceID != "default"
            && !newDevices.contains(where: { $0.id == self.selectedDeviceID })
        {
            self.selectedDeviceID = "default"
        }
    }

    /// 使用 Core Audio 检测设备是否为物理设备
    private func isPhysicalAudioDevice(uid: String) -> Bool {
        var deviceID: AudioDeviceID = 0
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

        // 通过 UID 获取 AudioDeviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var cfUID: CFString = uid as CFString
        var translation = AudioValueTranslation(
            mInputData: &cfUID,
            mInputDataSize: UInt32(MemoryLayout<CFString>.size),
            mOutputData: &deviceID,
            mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        var translationSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &translationSize,
            &translation
        )

        guard status == noErr, deviceID != 0 else {
            return false
        }

        // 获取传输类型
        var transportType: UInt32 = 0
        propertySize = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType

        let transportStatus = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &transportType
        )

        // 获取传输类型字符串用于调试
        let transportTypeStr = String(
            format: "%c%c%c%c",
            (transportType >> 24) & 0xFF,
            (transportType >> 16) & 0xFF,
            (transportType >> 8) & 0xFF,
            transportType & 0xFF
        )
        LogManager.shared.debug("设备传输类型检测 | 类型码: \(transportTypeStr) (\(transportType))")

        // 物理设备类型
        let physicalTransportTypes: [UInt32] = [
            kAudioDeviceTransportTypeBuiltIn,  // 内置
            kAudioDeviceTransportTypeUSB,  // USB
            kAudioDeviceTransportTypeBluetooth,  // 蓝牙
            kAudioDeviceTransportTypeBluetoothLE,  // 蓝牙低功耗
            kAudioDeviceTransportTypeFireWire,  // FireWire
            kAudioDeviceTransportTypeThunderbolt,  // 雷电
            kAudioDeviceTransportTypePCI,  // PCI
            kAudioDeviceTransportTypeHDMI,  // HDMI
            kAudioDeviceTransportTypeDisplayPort,  // DisplayPort
            kAudioDeviceTransportTypeAirPlay,  // AirPlay
            kAudioDeviceTransportTypeAVB,  // AVB
            kAudioDeviceTransportTypeContinuityCaptureWired,  // 连续互通（有线）
            kAudioDeviceTransportTypeContinuityCaptureWireless,  // 连续互通（无线）
        ]

        return physicalTransportTypes.contains(transportType)
    }

    // MARK: - 开机自启动
    private func updateLaunchAtLogin(_ enable: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enable {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                LogManager.shared.info("开机自启动设置: \(enable ? "已启用" : "已禁用")")
            } catch {
                LogManager.shared.error("开机自启动设置失败: \(error.localizedDescription)")
            }
        }
    }
}
