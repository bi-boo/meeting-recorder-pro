//
//  HotKeyManager.swift
//  极简录音 - 全局快捷键管理器
//

import Foundation
import Carbon

class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()
    
    @Published var currentHotKey: HotKeyConfiguration?
    
    var onHotKeyPressed: (() -> Void)?
    
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    
    private init() {
        loadHotKey()
    }
    
    // MARK: - Hot Key Configuration
    struct HotKeyConfiguration: Codable, Equatable {
        var keyCode: UInt32
        var modifiers: UInt32
        
        var displayString: String {
            var parts: [String] = []
            
            if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
            if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
            if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
            if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
            
            if let keyString = keyCodeToString(keyCode) {
                parts.append(keyString)
            }
            
            return parts.joined()
        }
    }
    
    // MARK: - Register/Unregister
    func registerHotKey() {
        guard let config = currentHotKey else {
            print("未设置快捷键")
            return
        }
        
        unregisterHotKey()
        
        // 设置事件处理
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        
        let handler: EventHandlerUPP = { (_, event, _) -> OSStatus in
            HotKeyManager.shared.onHotKeyPressed?()
            return noErr
        }
        
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, &eventHandler)
        
        // 注册快捷键
        let hotKeyID = EventHotKeyID(signature: OSType(0x4852_4B59), id: 1) // "HRKY"
        
        let status = RegisterEventHotKey(
            config.keyCode,
            config.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        
        if status == noErr {
            print("快捷键已注册: \(config.displayString)")
        } else {
            print("快捷键注册失败: \(status)")
        }
    }
    
    func unregisterHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }
    
    // MARK: - Save/Load
    func saveHotKey(_ config: HotKeyConfiguration) {
        currentHotKey = config
        
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: "recordingHotKey")
        }
        
        registerHotKey()
    }
    
    private func loadHotKey() {
        if let data = UserDefaults.standard.data(forKey: "recordingHotKey"),
           let config = try? JSONDecoder().decode(HotKeyConfiguration.self, from: data) {
            currentHotKey = config
        } else {
            // 默认快捷键: Cmd + Shift + R
            currentHotKey = HotKeyConfiguration(
                keyCode: UInt32(kVK_ANSI_R),
                modifiers: UInt32(cmdKey | shiftKey)
            )
        }
    }
    
    // MARK: - Key Code to String
    static func keyCodeToString(_ keyCode: UInt32) -> String? {
        let keyCodeMap: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_Space): "空格", UInt32(kVK_Return): "回车",
            UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
            UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
            UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
            UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        ]
        return keyCodeMap[keyCode]
    }
}

private func keyCodeToString(_ keyCode: UInt32) -> String? {
    return HotKeyManager.keyCodeToString(keyCode)
}
