import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// A clipboard transaction may write/restore only while it still owns the clipboard.
/// A newer copy or handoff always wins. Tests use a private named pasteboard.
enum Pasteboard {
    static let restoreDelay: TimeInterval = 1
    private static var generations: [NSPasteboard.Name: UUID] = [:]

    final class Staged {
        private let board: NSPasteboard
        private let saved: [[NSPasteboard.PasteboardType: Data]]
        private let generation = UUID()
        private var expectedChangeCount: Int

        init(board: NSPasteboard) {
            self.board = board
            saved = (board.pasteboardItems ?? []).map { item in
                var values: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types { values[type] = item.data(forType: type) }
                return values
            }
            expectedChangeCount = board.changeCount
            generations[board.name] = generation
        }

        var ownsClipboard: Bool {
            generations[board.name] == generation && board.changeCount == expectedChangeCount
        }

        @discardableResult
        func put(text: String) -> Bool {
            guard ownsClipboard else { return false }
            board.clearContents()
            let success = board.setString(text, forType: .string)
            expectedChangeCount = board.changeCount
            return success
        }

        @discardableResult
        func put(image: CGImage) -> Bool {
            guard ownsClipboard else { return false }
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
            board.clearContents()
            let success = board.setData(png, forType: .png)
            expectedChangeCount = board.changeCount
            return success
        }

        @discardableResult
        func restoreIfOwned() -> Bool {
            guard ownsClipboard else { return false }
            board.clearContents()
            let restored = saved.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            if !restored.isEmpty { board.writeObjects(restored) }
            generations.removeValue(forKey: board.name)
            return true
        }

        deinit {
            if generations[board.name] == generation { generations.removeValue(forKey: board.name) }
        }
    }

    static func beginStaging(on board: NSPasteboard = .general) -> Staged { Staged(board: board) }
}

enum Keyboard {
    /// Revalidate immediately before posting, and address events to the destination
    /// process so a focus race cannot redirect a paste into an unrelated application.
    @discardableResult
    static func press(keyCode: CGKeyCode, flags: CGEventFlags, pid: pid_t) -> Bool {
        guard AXIsProcessTrusted(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }

    /// Require an editable text control before sending payloads. Unknown AX layouts
    /// take the explicit paste fallback instead of guessing at the focused control.
    static func hasEditableFocus(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        let element = value as! AXUIElement
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let role = role as? String,
              [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role) else { return false }
        var editable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &editable) == .success
            && editable.boolValue
    }

    static func parse(_ shortcut: String) -> (CGKeyCode, CGEventFlags)? {
        let parts = shortcut.lowercased().split(separator: "+").map(String.init)
        guard let keyName = parts.last else { return nil }
        var flags: CGEventFlags = []
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "option": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: return nil
            }
        }
        // Submission shortcuts are deliberately not supported.
        let keyCodes: [String: Int] = ["n": kVK_ANSI_N, "o": kVK_ANSI_O, "t": kVK_ANSI_T,
                                     "k": kVK_ANSI_K, "j": kVK_ANSI_J]
        guard let code = keyCodes[keyName] else { return nil }
        return (CGKeyCode(code), flags)
    }
}
