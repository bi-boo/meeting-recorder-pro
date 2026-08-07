//
//  AudioRecorderManagerDevice.swift
//  会议录音 Pro - 设备监听与激活
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
        NotificationCenter.default.removeObserver(
            self,
            name: .AVAudioEngineConfigurationChange,
            object: nil
        )
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
        // 无论是否正在录音都先刷新列表，避免空闲态长期显示过期设备。
        AppSettings.shared.refreshInputDevices()

        let currentDefaultID = currentDefaultInputDeviceInfo()?.id
        if let expectedID = expectedDefaultInputDeviceID, currentDefaultID == expectedID {
            expectedDefaultInputDeviceID = nil
            LogManager.shared.debug("忽略应用主动切换输入设备产生的系统回调 | 设备ID: \(expectedID)")
            return
        }

        if recordingState == .starting, currentAudioSource != .systemAudio {
            startupConfigurationChanged = true
            LogManager.shared.info("录音启动期检测到默认输入设备回调，继续等待设备路由稳定")
            return
        }

        // 录音和暂停都属于活跃会话；暂停期间切换设备同样必须保存当前文件。
        guard recordingState == .recording || recordingState == .paused,
            currentAudioSource != .systemAudio
        else { return }

        guard RecordingInputDeviceChangePolicy.shouldInterruptRecording(
            recordingDeviceID: recordingDeviceID,
            currentDefaultInputDeviceID: currentDefaultID
        ) else {
            if currentDefaultID == nil {
                LogManager.shared.debug("默认输入设备回调期间设备信息尚未稳定，等待后续回调")
            } else {
                LogManager.shared.debug("默认输入设备回调未改变当前录音设备，忽略")
            }
            return
        }

        LogManager.shared.warning("检测到音频设备变更，结束当前录音以避免静音续录")
        handleRecordingInterruption(reason: .deviceChanged)
    }

    /// 处理设备列表变更（设备被移除）
    func handleAudioDeviceListChange() {
        // 先刷新真实设备列表，避免用旧缓存误判设备是否仍然存在。
        AppSettings.shared.refreshInputDevices()

        guard recordingState == .recording || recordingState == .paused,
            currentAudioSource != .systemAudio
        else { return }
        guard let deviceID = recordingDeviceID, deviceID != "default" else { return }

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
        // Apple 会在 AVAudioEngine 的内部串行队列发送此通知。回调内不拆引擎，
        // 只切回主队列后再读取状态和处理资源。
        guard let changedEngine = notification.object as? AVAudioEngine else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, changedEngine === self.audioEngine else { return }
            self.processAudioEngineConfigurationChange()
        }
    }

    private func processAudioEngineConfigurationChange() {
        if recordingState == .starting {
            startupConfigurationChanged = true
            LogManager.shared.warning("录音启动期检测到 AVAudioEngine 配置变化，等待设备格式稳定")
            return
        }

        guard recordingState == .recording || recordingState == .paused,
            currentAudioSource != .systemAudio
        else { return }

        if recordingState == .paused {
            if hasRecordingInputConfigurationChanged() {
                LogManager.shared.warning("暂停期间输入设备配置发生变化，保存当前录音")
                handleRecordingInterruption(reason: .engineConfigurationChanged)
            } else {
                LogManager.shared.info("暂停期间仅检测到非输入侧配置变化，恢复时重新验证采集")
            }
            return
        }

        scheduleEngineConfigurationEvaluation()
    }

    private func scheduleEngineConfigurationEvaluation() {
        engineConfigurationEvaluationWorkItem?.cancel()
        engineConfigurationEvaluationGeneration += 1
        let evaluationGeneration = engineConfigurationEvaluationGeneration
        let observedFrames = framesCounter.withLock { $0 }
        let observedEngine = audioEngine

        let workItem = DispatchWorkItem { [weak self, weak observedEngine] in
            guard let self = self,
                let observedEngine = observedEngine,
                self.engineConfigurationEvaluationGeneration == evaluationGeneration,
                self.recordingState == .recording,
                self.audioEngine === observedEngine
            else { return }

            let currentFrames = self.framesCounter.withLock { $0 }
            if currentFrames > observedFrames {
                self.engineConfigurationRecoveryAttempts = 0
                LogManager.shared.info("引擎配置变化后音频帧仍在增长，判定为非输入侧变化")
                return
            }

            if !self.hasRecordingInputConfigurationChanged(),
                self.engineConfigurationRecoveryAttempts < 1
            {
                do {
                    self.engineConfigurationRecoveryAttempts += 1
                    if self.audioEngine.isRunning {
                        self.audioEngine.stop()
                    }
                    try self.audioEngine.start()
                    LogManager.shared.info("非输入侧配置变化后已重新启动音频引擎，继续验证")
                    self.scheduleEngineConfigurationEvaluation()
                    return
                } catch {
                    LogManager.shared.warning(
                        "非输入侧配置变化后重启音频引擎失败 | 错误: \(error.localizedDescription)")
                }
            }

            LogManager.shared.warning("引擎配置变化后音频帧停止增长，保存当前录音")
            self.handleRecordingInterruption(reason: .engineConfigurationChanged)
        }
        engineConfigurationEvaluationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
    }

    private func hasRecordingInputConfigurationChanged() -> Bool {
        if let recordingDeviceID = recordingDeviceID,
            let currentDeviceID = currentDefaultInputDeviceInfo()?.id,
            recordingDeviceID != currentDeviceID
        {
            return true
        }

        let currentFormat = audioEngine.inputNode.outputFormat(forBus: 0)
        if let sampleRate = recordingInputSampleRate,
            abs(currentFormat.sampleRate - sampleRate) > 0.5
        {
            return true
        }
        if let channelCount = recordingInputChannelCount,
            currentFormat.channelCount != channelCount
        {
            return true
        }
        return false
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

        let shouldChangeDefaultInput = currentDefaultInputDeviceInfo()?.id != targetID
        if shouldChangeDefaultInput {
            expectedDefaultInputDeviceID = targetID
            if !setDefaultInputDevice(deviceUID: targetID) {
                expectedDefaultInputDeviceID = nil
                LogManager.shared.warning("切换 Core Audio 默认输入设备失败 | 设备ID: \(targetID)")
            }
        }

        guard shouldUseCaptureSessionActivation(deviceUID: targetID) else {
            if shouldChangeDefaultInput {
                LogManager.shared.info("已切换 Core Audio 默认输入设备 | 名称: \(targetName), ID: \(targetID)")
                audioEngine = AVAudioEngine()
                setupEngineConfigurationChangeListener()
            } else {
                LogManager.shared.info("沿用当前 Core Audio 默认输入设备 | 名称: \(targetName), ID: \(targetID)")
            }
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
                setupEngineConfigurationChangeListener()
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

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var cfUID: CFString = uid as CFString
        let translationStatus: OSStatus = withUnsafeMutableBytes(of: &cfUID) { uidBytes in
            withUnsafeMutableBytes(of: &deviceID) { deviceIDBytes in
                var translation = AudioValueTranslation(
                    mInputData: uidBytes.baseAddress!,
                    mInputDataSize: UInt32(uidBytes.count),
                    mOutputData: deviceIDBytes.baseAddress!,
                    mOutputDataSize: UInt32(deviceIDBytes.count)
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

        guard translationStatus == noErr, deviceID != 0 else {
            return nil
        }

        address.mSelector = kAudioDevicePropertyTransportType
        var transportType: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
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
    @discardableResult
    func setDefaultInputDevice(deviceUID: String) -> Bool {
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
                let status = AudioObjectSetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &defaultInputAddress,
                    0,
                    nil,
                    UInt32(MemoryLayout<AudioDeviceID>.size),
                    &mutableDeviceID
                )
                return status == noErr
            }
        }
        return false
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
