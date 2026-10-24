import AppKit
import Carbon.HIToolbox

/// 全局快捷键动作（R2.3）。
enum HotkeyAction: UInt32, CaseIterable {
    case selectRegion = 1
    case toggleLock
    case togglePause
    case rerunOnce

    var keyCode: UInt32 {
        switch self {
        case .selectRegion: UInt32(kVK_ANSI_T)
        case .toggleLock: UInt32(kVK_ANSI_L)
        case .togglePause: UInt32(kVK_ANSI_P)
        case .rerunOnce: UInt32(kVK_ANSI_R)
        }
    }

    /// 菜单项的 keyEquivalent（只用于显示）。
    var keyEquivalent: String {
        switch self {
        case .selectRegion: "t"
        case .toggleLock: "l"
        case .togglePause: "p"
        case .rerunOnce: "r"
        }
    }

    var shortcutLabel: String { "⌃⌥\(keyEquivalent.uppercased())" }

    var displayName: String {
        switch self {
        case .selectRegion: "框选新区域"
        case .toggleLock: "锁定/解锁面板"
        case .togglePause: "暂停/恢复全部"
        case .rerunOnce: "重新识别单次区域"
        }
    }
}

/// 基于 Carbon `RegisterEventHotKey` 的全局快捷键，不需要额外权限（design.md「HotkeyManager」）。
@MainActor
final class HotkeyManager {
    var handler: ((HotkeyAction) -> Void)?
    /// 注册失败（通常是与其他应用冲突）的快捷键（R2.4）。
    private(set) var conflicts: [HotkeyAction] = []

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    /// 'TPKY'
    private static let signature: OSType = 0x5450_4B59

    func registerAll() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventCallback, 1, &eventType, userData, &eventHandler)

        conflicts = []
        for action in HotkeyAction.allCases {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
            let status = RegisterEventHotKey(
                action.keyCode, UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref
            )
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
            } else {
                conflicts.append(action)
            }
        }
    }

    func unregisterAll() {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs = []
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }

    fileprivate func handle(id: UInt32) {
        guard let action = HotkeyAction(rawValue: id) else { return }
        handler?(action)
    }
}

/// Carbon 回调在主线程执行（应用事件目标）。
private func hotKeyEventCallback(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
    )
    guard status == noErr else { return status }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    let id = hotKeyID.id
    MainActor.assumeIsolated { manager.handle(id: id) }
    return noErr
}
