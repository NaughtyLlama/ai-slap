import AppKit
import Carbon.HIToolbox

/// Stages the handoff payload, then puts the user's clipboard back.
///
/// docs/05 is emphatic about the restore: silently destroying someone's clipboard is a
/// small betrayal that people notice and resent — especially from an app that already
/// watches what they do.
enum Pasteboard {

    /// How long to wait after the last paste before putting the old clipboard back.
    static let restoreDelay: TimeInterval = 1.0

    /// The user's clipboard, held so it can be given back.
    ///
    /// The restore is deliberately **not** on a timer from staging. It used to be, and
    /// that raced the paste: whenever the destination took longer than the timer to be
    /// ready, the payload was pulled out from under it, so the paste landed on nothing
    /// *and* the clipboard fallback was gone too.
    struct Staged {
        fileprivate let saved: Snapshot

        func restoreAfterPaste() {
            DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
                restore(saved, to: .general)
            }
        }

        /// Leaves the payload in place. Used on every failure path: docs/05 makes the
        /// clipboard the universal fallback, which only works if it is still there.
        func keepPayload() {}
    }

    static func beginStaging() -> Staged {
        Staged(saved: snapshot(.general))
    }

    /// Text and image go on the pasteboard **separately, and are pasted separately**.
    ///
    /// Writing both as one pasteboard write produces two items, and chat composers
    /// read only the first — which is why the prompt arrived and the screenshot
    /// silently didn't. Two writes and two Cmd-Vs put both in the composer.
    static func put(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func put(image: CGImage) {
        let bitmap = NSBitmapImageRep(cgImage: image)
        bitmap.size = NSSize(width: image.width, height: image.height)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
    }

    fileprivate struct Snapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> Snapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            var stored: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { stored[type] = data }
            }
            return stored
        }
        return Snapshot(items: items)
    }

    private static func restore(_ snapshot: Snapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }

        let restored = snapshot.items.map { stored -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in stored { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(restored)
    }

    /// Synthesises Cmd-V. Works because Accessibility is already granted — the same
    /// permission the whole product depends on.
    @discardableResult
    static func synthesizePaste() -> Bool {
        Keyboard.press(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
    }
}

enum Keyboard {
    @discardableResult
    static func press(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(
                keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(
                keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }

        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Parses a rulebook shortcut like "cmd+n" or "cmd+shift+o".
    static func parse(_ shortcut: String) -> (CGKeyCode, CGEventFlags)? {
        let parts = shortcut.lowercased().split(separator: "+").map(String.init)
        guard let keyName = parts.last else { return nil }

        var flags: CGEventFlags = []
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift":          flags.insert(.maskShift)
            case "opt", "option":  flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: return nil
            }
        }

        let keyCodes: [String: Int] = [
            "n": kVK_ANSI_N, "o": kVK_ANSI_O, "t": kVK_ANSI_T,
            "k": kVK_ANSI_K, "j": kVK_ANSI_J, "return": kVK_Return,
        ]
        guard let code = keyCodes[keyName] else { return nil }
        return (CGKeyCode(code), flags)
    }
}
