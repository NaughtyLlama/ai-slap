import AppKit
import Carbon.HIToolbox

/// Option-Space, registered globally.
///
/// docs/05: `NSEvent.addGlobalMonitorForEvents` is not sufficient — it cannot consume
/// the event, so the keystroke would also reach whatever app is in front. Carbon's
/// RegisterEventHotKey is the API that actually claims the combination.
final class GlobalHotkey {

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onPress: (() -> Void)?

    /// Registers Option-Space. Returns false if something else already owns it.
    @discardableResult
    func register(onPress: @escaping () -> Void) -> Bool {
        self.onPress = onPress

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData else { return noErr }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData)
                .takeUnretainedValue()
            DispatchQueue.main.async { hotkey.onPress?() }
            return noErr
        }

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard status == noErr else { return false }

        let id = EventHotKeyID(signature: OSType(0x41495348), id: 1)  // 'AISH'
        let registered = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        return registered == noErr
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
