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

    static var availableCases: [OutputFormat] {
        MP3Encoder.isEncodingAvailable ? allCases : [.m4a]
    }

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

class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let minimumMaxDurationMinutes = 5

    private var isNormalizingMaxDuration = false
    private var isApplyingLaunchAtLoginSystemState = false

    // MARK: - 存储路径设置
    @Published var recordingsPath: URL {
        didSet {
            // 路径切换时，停止对旧 Security-Scoped URL 的访问
            if let prev = securityScopedURL, prev != recordingsPath {
                prev.stopAccessingSecurityScopedResource()
                securityScopedURL = nil
            }
            savePath(recordingsPath, forKey: "recordingsPath")
        }
    }

    /// 跟踪当前已通过 startAccessingSecurityScopedResource 开启访问的 URL
    private var securityScopedURL: URL?

    // MARK: - 录音设置
    @Published var maxDurationHours: Int {
        didSet { normalizeAndPersistMaxDuration() }
    }

    @Published var maxDurationMinutes: Int {
        didSet { normalizeAndPersistMaxDuration() }
    }

    var maxRecordingDuration: TimeInterval {
        let rawSeconds = maxDurationHours * 3600 + maxDurationMinutes * 60
        return TimeInterval(max(rawSeconds, Self.minimumMaxDurationMinutes * 60))
    }

    // MARK: - 音频源设置
    @Published var audioSource: AudioSource {
        didSet { UserDefaults.standard.set(audioSource.rawValue, forKey: "audioSource") }
    }

    // MARK: - 输出格式设置
    @Published var outputFormat: OutputFormat {
        didSet {
            if outputFormat == .mp3 && !MP3Encoder.isEncodingAvailable {
                LogManager.shared.warning("MP3 编码不可用，保存格式已回落为 M4A")
                outputFormat = .m4a
                return
            }
            UserDefaults.standard.set(outputFormat.rawValue, forKey: "outputFormat")
        }
    }

    // MARK: - 行为设置
    @Published var launchAtLogin: Bool {
        didSet {
            guard !isApplyingLaunchAtLoginSystemState else {
                UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
                return
            }

            let requestedValue = launchAtLogin
            guard applyLaunchAtLogin(requestedValue) else {
                isApplyingLaunchAtLoginSystemState = true
                launchAtLogin = oldValue
                isApplyingLaunchAtLoginSystemState = false
                UserDefaults.standard.set(oldValue, forKey: "launchAtLogin")
                return
            }

            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
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

    /// 检测当前是否拥有”屏幕录制”权限
    static var hasScreenCapturePermission: Bool {
        if #available(macOS 13.0, *) {
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
        // 默认路径：沙盒 Documents/Recordings（与 App Sandbox 完全兼容）
        let defaultRecordingsPath =
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Recordings")

        // 加载路径设置
        // 方案1: 优先从路径字符串加载（用户主目录内的路径，不需要书签）
        if let pathString = UserDefaults.standard.string(forKey: "recordingsPath_path") {
            let url = URL(fileURLWithPath: pathString)
            self.recordingsPath = url
            LogManager.shared.debug("从路径字符串恢复 | 路径: \(url.path)")
        }
        // 方案2: 尝试从 Security-Scoped Bookmark 恢复（用于用户自定义的特殊目录）
        else if let data = UserDefaults.standard.data(forKey: "recordingsPath"),
            var isStale = Optional(false),
            let url = try? URL(
                resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
                bookmarkDataIsStale: &isStale)
        {
            // 书签解析成功，尝试获取访问权限
            let accessGranted = url.startAccessingSecurityScopedResource()
            if accessGranted || isStale == false {
                self.recordingsPath = url
                self.securityScopedURL = url  // 记录当前有效的 Security-Scoped URL
                LogManager.shared.debug("从书签恢复路径成功 | 路径: \(url.path)")
            } else {
                // 书签失效（可能因为应用签名变化），回退到默认路径
                LogManager.shared.info("书签失效，回退到默认路径 | 原路径: \(url.path)")
                self.recordingsPath = defaultRecordingsPath
                // 清除失效的书签数据
                UserDefaults.standard.removeObject(forKey: "recordingsPath")
            }
        }
        // 方案3: 使用默认路径
        else {
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
            if format == .mp3 && !MP3Encoder.isEncodingAvailable {
                self.outputFormat = .m4a
                UserDefaults.standard.set(OutputFormat.m4a.rawValue, forKey: "outputFormat")
                LogManager.shared.warning("已保存的 MP3 格式不可用，启动时回落为 M4A")
            } else {
                self.outputFormat = format
            }
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
            UserDefaults.standard.object(forKey: "preventSleepWithSchedule") as? Bool ?? false  // 新安装默认关闭；已有用户沿用原值

        normalizeAndPersistMaxDuration()
        refreshLaunchAtLoginStatus()

        // 初始刷新一次设备列表
        refreshInputDevices()

        // 确保目录存在
        try? FileManager.default.createDirectory(
            at: recordingsPath, withIntermediateDirectories: true)

        print("🔧 AppSettings 初始化完成 (精简版)")
    }

    // MARK: - Path Persistence
    private func savePath(_ url: URL, forKey key: String) {
        // 获取用户主目录（在沙盒中，homeDirectoryForCurrentUser 返回容器内的 home 路径）
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser

        // 判断路径是否在用户主目录下（这些路径不需要 Security-Scoped Bookmark）
        if url.path.hasPrefix(homeDirectory.path) {
            // 用户主目录下的路径，直接保存路径字符串即可
            UserDefaults.standard.removeObject(forKey: key)  // 清除可能存在的旧书签
            UserDefaults.standard.set(url.path, forKey: "\(key)_path")
            LogManager.shared.debug("保存路径（主目录内，无需书签）| 路径: \(url.path)")
        } else {
            // 非用户主目录的路径（如外置硬盘），需要保存 Security-Scoped Bookmark
            if let bookmarkData = try? url.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            {
                UserDefaults.standard.set(bookmarkData, forKey: key)
                UserDefaults.standard.removeObject(forKey: "\(key)_path")  // 清除可能存在的旧路径
                LogManager.shared.debug("保存路径（需要书签）| 路径: \(url.path)")
            }
        }
    }

    // MARK: - Device Management
    func refreshInputDevices() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified)

        let devices = session.devices
        var physicalDevices = [AudioInputDevice]()

        for device in devices {
            let deviceName = device.localizedName
            let deviceUID = device.uniqueID

            // 使用 Core Audio 检测设备传输类型
            let isPhysical = isPhysicalAudioDevice(uid: deviceUID)

            if isPhysical {
                physicalDevices.append(AudioInputDevice(id: deviceUID, name: deviceName))
            }
        }

        let defaultDeviceName: String
        if let defaultDevice = currentDefaultInputDeviceInfo() {
            let defaultIsCapturable = physicalDevices.contains { $0.id == defaultDevice.id }
            defaultDeviceName =
                defaultIsCapturable
                ? "系统默认（\(defaultDevice.name)）"
                : "系统默认（\(defaultDevice.name)，不可用）"
        } else {
            defaultDeviceName = "系统默认"
        }

        var newDevices = [AudioInputDevice(id: "default", name: defaultDeviceName)]
        newDevices.append(contentsOf: physicalDevices)

        // 同步更新设备列表（确保菜单栏可以立即获取）
        self.availableInputDevices = newDevices
        // 如果当前选中的设备已经不在列表中（比如拔掉了），切回默认
        if self.selectedDeviceID != "default"
            && !newDevices.contains(where: { $0.id == self.selectedDeviceID })
        {
            self.selectedDeviceID = "default"
        }
    }

    private func currentDefaultInputDeviceInfo() -> AudioInputDevice? {
        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != 0 else {
            return nil
        }

        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString?
        size = UInt32(MemoryLayout<CFString?>.size)
        let nameStatus = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &size, pointer)
        }

        guard nameStatus == noErr else {
            return nil
        }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString?
        size = UInt32(MemoryLayout<CFString?>.size)
        let uidStatus = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &size, pointer)
        }

        guard uidStatus == noErr, let uidString = uid as String? else {
            return nil
        }

        return AudioInputDevice(id: uidString, name: (name as String?) ?? uidString)
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

        var uidPointerValue = Unmanaged.passUnretained(uid as CFString).toOpaque()
        let status = withUnsafeMutablePointer(to: &uidPointerValue) { uidPointer in
            withUnsafeMutablePointer(to: &deviceID) { deviceIDPointer in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(uidPointer),
                    mInputDataSize: UInt32(MemoryLayout<UnsafeRawPointer>.size),
                    mOutputData: UnsafeMutableRawPointer(deviceIDPointer),
                    mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
                )

                var translationSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    0,
                    nil,
                    &translationSize,
                    &translation
                )
            }
        }

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

        guard transportStatus == noErr else {
            return false
        }

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

    private func normalizeAndPersistMaxDuration() {
        if isNormalizingMaxDuration {
            UserDefaults.standard.set(maxDurationHours, forKey: "maxDurationHours")
            UserDefaults.standard.set(maxDurationMinutes, forKey: "maxDurationMinutes")
            return
        }

        isNormalizingMaxDuration = true

        let clampedHours = min(max(maxDurationHours, 0), 9)
        let clampedMinutes = min(max(maxDurationMinutes, 0), 55)
        let steppedMinutes = (clampedMinutes / 5) * 5

        if maxDurationHours != clampedHours {
            maxDurationHours = clampedHours
        }
        if maxDurationMinutes != steppedMinutes {
            maxDurationMinutes = steppedMinutes
        }
        if maxDurationHours == 0 && maxDurationMinutes == 0 {
            maxDurationMinutes = Self.minimumMaxDurationMinutes
        }

        isNormalizingMaxDuration = false

        UserDefaults.standard.set(maxDurationHours, forKey: "maxDurationHours")
        UserDefaults.standard.set(maxDurationMinutes, forKey: "maxDurationMinutes")
    }

    // MARK: - 开机自启动
    func refreshLaunchAtLoginStatus() {
        if #available(macOS 13.0, *) {
            let systemEnabled = SMAppService.mainApp.status == .enabled
            guard launchAtLogin != systemEnabled else {
                UserDefaults.standard.set(systemEnabled, forKey: "launchAtLogin")
                return
            }

            isApplyingLaunchAtLoginSystemState = true
            launchAtLogin = systemEnabled
            isApplyingLaunchAtLoginSystemState = false
            UserDefaults.standard.set(systemEnabled, forKey: "launchAtLogin")
        }
    }

    @discardableResult
    private func applyLaunchAtLogin(_ enable: Bool) -> Bool {
        if #available(macOS 13.0, *) {
            do {
                if enable {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                LogManager.shared.info("开机自启动设置: \(enable ? "已启用" : "已禁用")")
                return true
            } catch {
                LogManager.shared.error("开机自启动设置失败: \(error.localizedDescription)")
                return false
            }
        }

        return false
    }
}
