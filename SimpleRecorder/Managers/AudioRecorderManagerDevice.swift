//
//  AudioRecorderManagerDevice.swift
//  会议录音 Pro - 设备监听与激活
//
//  职责范围：
//  - CoreAudio 设备变更监听（耳机插拔、设备列表变化）
//  - AVAudioEngine 配置变更监听
//  - 音频设备变更/移除/引擎配置变更的处理回调
//  - 解析本次录音使用的输入设备，判断是否需要独立采集链路
//  - 应用不修改系统默认输入设备
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

        // 独立采集链路固定在用户选择（或替代）的 AVCaptureDevice 上，系统默认输入
        // 变化不会改变实际录音设备；设备拔出由 handleAudioDeviceListChange 处理。
        if microphoneCaptureSession != nil, !activeInputFollowsSystemDefault {
            LogManager.shared.debug(
                "独立麦克风采集期间系统默认输入变化，实际录音设备未改变，忽略回调")
            return
        }

        if recordingState == .starting, currentAudioSource != .systemAudio {
            guard let currentDefaultID else {
                LogManager.shared.debug("录音启动期默认输入设备暂时不可解析，等待后续回调")
                return
            }
            guard currentDefaultID != activeInputDeviceID else {
                LogManager.shared.debug("录音启动期默认输入设备未实际变化，忽略回调")
                return
            }
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
        if microphoneCaptureSession != nil {
            // 固定设备的独立采集不跟随系统默认输入变化；设备拔出由
            // handleAudioDeviceListChange 单独处理。只有跟随系统默认时需要比较。
            guard activeInputFollowsSystemDefault else { return false }
            return recordingDeviceID != currentDefaultInputDeviceInfo()?.id
        }

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

    // MARK: - 录音输入设备解析

    /// 解析本次录音使用的输入设备，只记录结果，不修改系统默认输入。
    /// - 选择“系统默认”且默认设备可采集：跟随系统默认，由 AVAudioEngine 输入节点采集。
    /// - 选择“系统默认”但默认设备不可采集（例如虚拟设备）：改用可用麦克风，走独立采集。
    /// - 手动选择了麦克风：固定到该设备，走独立采集。
    /// macOS 27 上设置系统默认输入会返回成功但不生效，所以录音不能依赖切换默认输入。
    func resolveRecordingInputDevice() {
        AppSettings.shared.refreshInputDevices()

        let selectedID = AppSettings.shared.selectedDeviceID
        guard selectedID == "default" else {
            activeInputDeviceID = selectedID
            activeInputDeviceName =
                AppSettings.shared.availableInputDevices.first(where: { $0.id == selectedID })?.name
                ?? selectedID
            activeInputFollowsSystemDefault = false
            LogManager.shared.info(
                "使用手动选择的麦克风，不修改系统默认输入 | 名称: \(activeInputDeviceName ?? selectedID), ID: \(selectedID)")
            return
        }

        guard let defaultDevice = currentDefaultInputDeviceInfo() else {
            activeInputDeviceID = "default"
            activeInputDeviceName = "系统默认"
            activeInputFollowsSystemDefault = true
            LogManager.shared.warning("无法解析系统默认输入设备，将直接使用 AVAudioEngine 默认输入")
            return
        }

        let defaultIsCapturable = AppSettings.shared.availableInputDevices.contains {
            $0.id == defaultDevice.id
        }
        if defaultIsCapturable {
            activeInputDeviceID = defaultDevice.id
            activeInputDeviceName = "\(defaultDevice.name)（系统默认）"
            activeInputFollowsSystemDefault = true
            LogManager.shared.info(
                "系统默认输入设备已解析 | 名称: \(defaultDevice.name)（系统默认）, ID: \(defaultDevice.id)")
            return
        }

        guard let fallbackDevice = preferredFallbackInputDevice() else {
            activeInputDeviceID = defaultDevice.id
            activeInputDeviceName = "\(defaultDevice.name)（系统默认，不可用）"
            activeInputFollowsSystemDefault = true
            LogManager.shared.warning("系统默认输入设备不可采集且没有可用备用麦克风 | 默认设备: \(defaultDevice.name), ID: \(defaultDevice.id)")
            return
        }

        activeInputDeviceID = fallbackDevice.id
        activeInputDeviceName = "\(fallbackDevice.name)（自动替代不可用的系统默认：\(defaultDevice.name)）"
        activeInputFollowsSystemDefault = false
        LogManager.shared.warning(
            "系统默认输入设备不可采集，改用可用麦克风独立采集 | 默认设备: \(defaultDevice.name), 默认ID: \(defaultDevice.id), 替代设备: \(fallbackDevice.name), 替代ID: \(fallbackDevice.id)")
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

    /// 需在 resolveRecordingInputDevice() 之后调用。
    /// 不跟随系统默认的设备只能走独立采集；蓝牙或 AirPlay 输出时，跟随系统默认的
    /// 麦克风也走独立采集，避开 AVAudioEngine 隐式聚合设备返回静音帧的问题。
    func shouldUseIndependentMicrophoneCapture() -> Bool {
        RecordingInputRoutePolicy.requiresIndependentCapture(
            outputTransportType: defaultOutputTransportType(),
            inputFollowsSystemDefault: activeInputFollowsSystemDefault
        )
    }

    private func defaultOutputTransportType() -> UInt32? {
        var defaultOutputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var outputDeviceID = AudioDeviceID(0)
        var outputDeviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let outputStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputAddress,
            0,
            nil,
            &outputDeviceSize,
            &outputDeviceID
        )
        guard outputStatus == noErr, outputDeviceID != 0 else { return nil }

        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        let transportStatus = AudioObjectGetPropertyData(
            outputDeviceID,
            &transportAddress,
            0,
            nil,
            &transportSize,
            &transportType
        )
        guard transportStatus == noErr else { return nil }
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
}
