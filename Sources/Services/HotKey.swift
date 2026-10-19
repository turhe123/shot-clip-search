import Carbon.HIToolbox
import Foundation

/// Registers a single system-wide hotkey through Carbon (no Accessibility permission required).
final class HotKey {
    static let shared = HotKey()

    var action: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Letters offered in Settings mapped to their virtual key codes.
    static let keyCodes: [String: Int] = [
        "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D, "E": kVK_ANSI_E,
        "F": kVK_ANSI_F, "G": kVK_ANSI_G, "H": kVK_ANSI_H, "I": kVK_ANSI_I, "J": kVK_ANSI_J,
        "K": kVK_ANSI_K, "L": kVK_ANSI_L, "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O,
        "P": kVK_ANSI_P, "Q": kVK_ANSI_Q, "R": kVK_ANSI_R, "S": kVK_ANSI_S, "T": kVK_ANSI_T,
        "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X, "Y": kVK_ANSI_Y,
        "Z": kVK_ANSI_Z,
    ]

    /// Re-registers the hotkey from the values stored in UserDefaults. Returns false if registration failed.
    @discardableResult
    func registerFromDefaults() -> Bool {
        let d = UserDefaults.standard
        let key = d.string(forKey: "hotkeyKey") ?? "V"
        var mods = 0
        if d.bool(forKey: "hotkeyCmd") { mods |= cmdKey }
        if d.bool(forKey: "hotkeyShift") { mods |= shiftKey }
        if d.bool(forKey: "hotkeyOption") { mods |= optionKey }
        if d.bool(forKey: "hotkeyControl") { mods |= controlKey }
        unregister()
        guard d.bool(forKey: "hotkeyEnabled"), mods != 0, let code = Self.keyCodes[key] else { return true }
        return register(keyCode: UInt32(code), modifiers: UInt32(mods))
    }

    private func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.shared.action?() }
                return noErr
            }, 1, &spec, nil, &handlerRef)
        }
        let id = EventHotKeyID(signature: OSType(0x5343_5348), id: 1) // "SCSH"
        return RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }
}
