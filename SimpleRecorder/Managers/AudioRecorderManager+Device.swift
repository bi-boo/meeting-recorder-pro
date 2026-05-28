//
//  AudioRecorderManager+Device.swift
//  极简录音 - 设备监听与激活
//
//  职责范围：
//  - CoreAudio 设备变更监听（耳机插拔、设备列表变化）
//  - AVAudioEngine 配置变更监听
//  - 音频设备变更/移除/引擎配置变更的处理回调
//  - 通过 AVCaptureSession 激活指定的输入设备（用于支持 iPhone 连续互通麦克风）
//  - 设置系统默认输入设备
//

import AVFoundation
import CoreAudio
import Foundation

extension AudioRecorderManager {

    // MARK: - 监听器注册

    /// 设置 Core Audio 设备变更监听器
    func setupAudioHardwareListeners() {
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleAudioDeviceChange()
        }
        defaultInputListener = defaultBlock
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputPropertyAddress,
            DispatchQueue.main,
            defaultBlock
        )

        let deviceListBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleAudioDeviceListChange()
        }
        deviceListListener = deviceListBlock
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &deviceListPropertyAddress,
            DispatchQueue.main,
            deviceListBlock
        )

        LogManager.shared.info("已注册音频设备变更监听器")
    }

    /// 移除 Core Audio 设备变更监听器
    func removeAudioHardwareListeners() {
        if let listener = defaultInputListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultInputPropertyAddress,
                DispatchQueue.main,
                listener
            )
            defaultInputListener = nil
        }

        if let listener = deviceListListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &deviceListPropertyAddress,
                DispatchQueue.main,
                listener
            )
            deviceListListener = nil
        }
    }

    /// 设置 AVAudioEngine 配置变更监听
    func setupEngineConfigurationChangeListener() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioEngineConfigChange),
            name: .AVAudioEngineConfigurationChange,
            object: nil
        )
        LogManager.shared.info("已注册 AVAudioEngine 配置变更监听器")
    }

    // MARK: - 设备变更处理

    /// 处理音频设备变更（如插拔耳机）
    func handleAudioDeviceChange() {
        // 只有在录音中且使用麦克风时才需要检查
        guard recordingState == .recording, currentAudioSource != .systemAudio else { return }

        LogManager.shared.warning("检测到音频设备变更，结束当前录音以避免静音续录")
        AppSettings.shared.refreshInputDevices()
        handleRecordingInterruption(reason: .deviceChanged)
    }

    /// 处理设备列表变更（设备被移除）
    func handleAudioDeviceListChange() {
        // 只有在录音中且使用麦克风时才需要检查
        guard recordingState == .recording, currentAudioSource != .systemAudio else { return }
        guard let deviceID = recordingDeviceID, deviceID != "default" else { return }

        AppSettings.shared.refreshInputDevices()

        // 检查当前使用的设备是否还在列表中
        let availableDevices = AppSettings.shared.availableInputDevices
        let deviceStillExists = availableDevices.contains { $0.id == deviceID }

        if !deviceStillExists {
            let deviceName = recordingDeviceName ?? "未知设备"
            LogManager.shared.error("录音使用的设备已断开 | 设备: \(deviceName)")
            handleRecordingInterruption(reason: .deviceRemoved(deviceName: deviceName))
        }
    }

    /// 处理 AVAudioEngine 配置变更
    @objc func handleAudioEngineConfigChange(_ notification: Notification) {
        // 只有在录音中时才处理
        guard recordingState == .recording else { return }

        LogManager.shared.warning("检测到 AVAudioEngine 配置变更，结束当前录音以避免静音续录")
        handleRecordingInterruption(reason: .engineConfigurationChanged)
    }

    // MARK: - 设备激活

    /// 根据 AppSettings 切换硬件输入设备。
    /// 普通 USB/蓝牙/内置麦克风只切 Core Audio 默认输入；仅连续互通麦克风需要 AVCaptureSession 预激活。
    func updateInputDevice() throws {
        // 先清理之前的激活会话
        stopDeviceActivationSession()

        AppSettings.shared.refreshInputDevices()

        let selectedID = AppSettings.shared.selectedDeviceID
        let targetID: String
        let targetName: String

        if selectedID == "default" {
            guard let defaultDevice = currentDefaultInputDeviceInfo() else {
                activeInputDeviceID = "default"
                activeInputDeviceName = "系统默认"
                LogManager.shared.warning("无法解析系统默认输入设备，将直接使用 AVAudioEngine 默认输入")
                return
            }

            let defaultIsCapturable = AppSettings.shared.availableInputDevices.contains {
                $0.id == defaultDevice.id
            }

            if defaultIsCapturable {
                targetID = defaultDevice.id
                targetName = "\(defaultDevice.name)（系统默认）"
                LogManager.shared.info("系统默认输入设备已解析 | 名称: \(targetName), ID: \(targetID)")

                activeInputDeviceID = targetID
                activeInputDeviceName = targetName
                LogManager.shared.info("使用系统当前默认输入设备，不额外创建设备激活会话")
                return
            }

            guard let fallbackDevice = preferredFallbackInputDevice() else {
                activeInputDeviceID = defaultDevice.id
                activeInputDeviceName = "\(defaultDevice.name)（系统默认，不可用）"
                LogManager.shared.warning("系统默认输入设备不可采集且没有可用备用麦克风 | 默认设备: \(defaultDevice.name), ID: \(defaultDevice.id)")
                return
            }

            targetID = fallbackDevice.id
            targetName = "\(fallbackDevice.name)（自动替代不可用的系统默认：\(defaultDevice.name)）"
            LogManager.shared.warning(
                "系统默认输入设备不可采集，自动改用可用麦克风 | 默认设备: \(defaultDevice.name), 默认ID: \(defaultDevice.id), 替代设备: \(fallbackDevice.name), 替代ID: \(fallbackDevice.id)")
        } else {
            targetID = selectedID
            targetName =
                AppSettings.shared.availableInputDevices.first(where: { $0.id == selectedID })?.name
                ?? selectedID
        }

        activeInputDeviceID = targetID
        activeInputDeviceName = targetName

        setDefaultInputDevice(deviceUID: targetID)

        guard shouldUseCaptureSessionActivation(deviceUID: targetID) else {
            LogManager.shared.info("已切换 Core Audio 默认输入设备 | 名称: \(targetName), ID: \(targetID)")
            audioEngine = AVAudioEngine()
            return
        }

        // 通过 AVCaptureDevice 查找目标设备
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        )

        guard
            let targetDevice = discoverySession.devices.first(where: { $0.uniqueID == targetID })
        else {
            LogManager.shared.warning("未找到可激活的麦克风设备 | 请求的设备: \(targetName), ID: \(targetID)，将使用系统当前默认输入")
            return
        }

        LogManager.shared.info("正在激活麦克风设备 | 名称: \(targetDevice.localizedName), ID: \(targetID)")

        // 创建 AVCaptureSession 来激活设备
        // 这对于 iPhone 连续互通设备特别重要，会触发 iPhone 进入麦克风模式
        do {
            let session = AVCaptureSession()
            let input = try AVCaptureDeviceInput(device: targetDevice)

            if session.canAddInput(input) {
                session.addInput(input)
                session.startRunning()

                // 保存引用，以便录音结束时清理
                deviceActivationSession = session
                deviceActivationInput = input

                LogManager.shared.info("设备激活成功 | 名称: \(targetDevice.localizedName)")

                // 重新创建 AVAudioEngine 以使用新设备
                audioEngine = AVAudioEngine()
            } else {
                LogManager.shared.warning("无法添加设备输入 | 名称: \(targetDevice.localizedName)，将使用默认设备")
            }
        } catch {
            LogManager.shared.warning("激活设备失败 | 错误: \(error.localizedDescription)，将使用默认设备")
        }
    }

    private func preferredFallbackInputDevice() -> AudioInputDevice? {
        let devices = AppSettings.shared.availableInputDevices.filter { $0.id != "default" }

        if let builtIn = devices.first(where: {
            $0.id == "BuiltInMicrophoneDevice" || $0.name.contains("MacBook")
        }) {
            return builtIn
        }

        return devices.first
    }

    private func shouldUseCaptureSessionActivation(deviceUID: String) -> Bool {
        guard let transportType = audioDeviceTransportType(for: deviceUID) else {
            return false
        }

        return transportType == kAudioDeviceTransportTypeContinuityCaptureWired
            || transportType == kAudioDeviceTransportTypeContinuityCaptureWireless
    }

    private func audioDeviceTransportType(for uid: String) -> UInt32? {
        var deviceID: AudioDeviceID = 0
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

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
        let translationStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &translationSize,
            &translation
        )

        guard translationStatus == noErr, deviceID != 0 else {
            return nil
        }

        address.mSelector = kAudioDevicePropertyTransportType
        var transportType: UInt32 = 0
        propertySize = UInt32(MemoryLayout<UInt32>.size)
        let transportStatus = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &transportType
        )

        guard transportStatus == noErr else {
            return nil
        }
        return transportType
    }

    func currentDefaultInputDeviceInfo() -> AudioInputDevice? {
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

        guard status == noErr, deviceID != 0,
            let uid = stringProperty(
                for: deviceID,
                selector: kAudioDevicePropertyDeviceUID
            )
        else {
            return nil
        }

        let name =
            stringProperty(
                for: deviceID,
                selector: kAudioObjectPropertyName
            ) ?? uid

        return AudioInputDevice(id: uid, name: name)
    }

    private func stringProperty(
        for deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }

        guard status == noErr else { return nil }
        return value as String?
    }

    /// 设置系统默认输入设备
    func setDefaultInputDevice(deviceUID: String) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propsize: UInt32 = 0
        AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propsize)

        let nDevices = Int(propsize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: nDevices)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propsize, &deviceIDs)

        for id in deviceIDs {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let uidPointer = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
            uidPointer.initialize(to: nil)
            defer {
                uidPointer.deinitialize(count: 1)
                uidPointer.deallocate()
            }

            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            let uidStatus = AudioObjectGetPropertyData(
                id, &uidAddress, 0, nil, &uidSize, uidPointer)

            if uidStatus == noErr, let uidString = uidPointer.pointee as String?,
                uidString == deviceUID
            {
                var defaultInputAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultInputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )

                var mutableDeviceID = id
                AudioObjectSetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &defaultInputAddress,
                    0,
                    nil,
                    UInt32(MemoryLayout<AudioDeviceID>.size),
                    &mutableDeviceID
                )
                break
            }
        }
    }

    /// 停止设备激活会话
    func stopDeviceActivationSession() {
        if let session = deviceActivationSession {
            session.stopRunning()
            if let input = deviceActivationInput {
                session.removeInput(input)
            }
        }
        deviceActivationSession = nil
        deviceActivationInput = nil
    }
}
