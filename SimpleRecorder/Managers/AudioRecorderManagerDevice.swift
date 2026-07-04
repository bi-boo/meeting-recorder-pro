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
        // 只有在录音中且使用麦克风时才需要检查
        guard isRecording, !isPaused, currentAudioSource != .systemAudio else { return }

        LogManager.shared.warning("检测到音频设备变更")

        // 给系统一点时间完成设备切换
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.isRecording else { return }

            // 检查音频引擎是否还在正常运行
            if !self.audioEngine.isRunning {
                self.handleRecordingInterruption(reason: .deviceChanged)
            }
        }
    }

    /// 处理设备列表变更（设备被移除）
    func handleAudioDeviceListChange() {
        // 只有在录音中且使用麦克风时才需要检查
        guard isRecording, !isPaused, currentAudioSource != .systemAudio else { return }
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
        if let changedEngine = notification.object as? AVAudioEngine,
            changedEngine !== audioEngine
        {
            return
        }

        // 只有在录音中时才处理
        guard isRecording, !isPaused else { return }

        LogManager.shared.warning("检测到 AVAudioEngine 配置变更")

        // 检查引擎是否还在运行
        if !audioEngine.isRunning {
            handleRecordingInterruption(reason: .engineConfigurationChanged)
        }
    }

    // MARK: - 设备激活

    /// 根据 AppSettings 切换硬件输入设备
    /// 使用 AVCaptureSession 激活设备，支持 iPhone 连续互通麦克风
    func updateInputDevice() throws {
        let selectedID = AppSettings.shared.selectedDeviceID

        // 先清理之前的激活会话
        stopDeviceActivationSession()

        guard selectedID != "default" else { return }

        // 通过 AVCaptureDevice 查找目标设备
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        )

        guard
            let targetDevice = discoverySession.devices.first(where: { $0.uniqueID == selectedID })
        else {
            LogManager.shared.warning("未找到匹配的麦克风设备 | 请求的设备ID: \(selectedID)，将使用默认设备")
            return
        }

        LogManager.shared.info("正在激活麦克风设备 | 名称: \(targetDevice.localizedName), ID: \(selectedID)")

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

                // 【关键】设置系统默认输入设备
                setDefaultInputDevice(deviceUID: selectedID)

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
