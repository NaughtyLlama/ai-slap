import AppKit
import Carbon.HIToolbox

/// Global hotkeys, registered with Carbon.
///
/// docs/05: `NSEvent.addGlobalMonitorForEvents` is not sufficient — it cannot consume
/// the event, so the keystroke would also reach whatever app is in front.
/// RegisterEventHotKey is the API that actually claims a combination.
final class GlobalHotkeys {

    static let handoffID: UInt32 = 1
    static let panicID: UInt32 = 2

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var handlerRef: EventHandlerRef?
    private var handlerInstalled = false

    @discardableResult
    func register(
        id: UInt32, keyCode: Int, modifiers: Int, action: @escaping () -> Void
    ) -> Bool {
        installHandlerIfNeeded()
        actions[id] = action

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x41495348), id: id)  // 'AISH'
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr else {
            actions[id] = nil
            return false
        }
        refs.append(ref)
        return true
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            let hotkeys = Unmanaged<GlobalHotkeys>.fromOpaque(userData)
                .takeUnretainedValue()
            let id = hotKeyID.id
            DispatchQueue.main.async { hotkeys.actions[id]?() }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    deinit {
        for ref in refs where ref != nil { UnregisterEventHotKey(ref!) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
