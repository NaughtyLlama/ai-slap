import AppKit

/// Stages the handoff payload, then puts the user's clipboard back.
///
/// docs/05 is emphatic about the restore: silently destroying someone's clipboard is a
/// small betrayal that people notice and resent — especially from an app that already
/// watches what they do.
enum Pasteboard {

    /// How long to leave the payload in place before restoring. Long enough for the
    /// paste to land, short enough that the user's own clipboard is barely gone.
    static let restoreDelay: TimeInterval = 2.5

    /// Puts text (and optionally an image) on the pasteboard and schedules the restore.
    static func stage(text: String, image: CGImage?) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        var items: [NSPasteboardWriting] = [text as NSString]
        if let image {
            let bitmap = NSBitmapImageRep(cgImage: image)
            bitmap.size = NSSize(width: image.width, height: image.height)
            let nsImage = NSImage(size: bitmap.size)
            nsImage.addRepresentation(bitmap)
            items.append(nsImage)
        }
        pasteboard.writeObjects(items)

        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            restore(saved, to: pasteboard)
        }
    }

    private struct Snapshot {
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
    static func synthesizePaste() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }
        let vKeyCode: CGKeyCode = 0x09  // kVK_ANSI_V

        guard let down = CGEvent(
                keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let up = CGEvent(
                keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return false }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
