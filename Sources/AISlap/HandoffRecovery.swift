import AppKit

/// Payloads stay in memory for at most five minutes, or until closed/replaced/erased.
final class HandoffRecovery: NSObject {
    static let shared = HandoffRecovery()
    private var panel: NSPanel?
    private var prompt: String?
    private var image: CGImage?
    private var expiry: Timer?

    /// Whether the handoff stops to show you the screenshot first.
    ///
    /// It defaults to asking, because the app is holding a photograph of your screen and
    /// the only thing that makes that bearable is seeing it before it leaves. But a
    /// confirmation you always answer the same way is just a second keystroke, and for
    /// someone handing off twenty times a day that is the whole cost of the feature.
    /// So it is a preference, set from the dialog itself at the moment it annoys you.
    enum Preference: String { case ask, alwaysInclude, alwaysTextOnly }

    static var preference: Preference {
        get { Preference(rawValue: UserDefaults.standard.string(forKey: "handoffReview") ?? "") ?? .ask }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "handoffReview") }
    }

    static func review(image: CGImage?, hasPermission: Bool) -> Handoff.ReviewChoice {
        switch preference {
        case .alwaysInclude: return image != nil ? .includeImage : .textOnly
        case .alwaysTextOnly: return .textOnly
        case .ask: break
        }

        let alert = NSAlert()
        alert.messageText = image == nil ? "Hand over text only?" : "Hand over this screenshot?"
        alert.informativeText = image != nil
            ? "Check that this is the window you meant to share. The screenshot and prompt will go to your AI app; nothing is submitted automatically."
            : hasPermission
                ? "The original window couldn't be identified uniquely or captured. No other window was substituted. You can still hand over the prompt."
                : "Screenshots are optional. Continue with the prompt, or enable Screen Recording and try again."

        // Every button reachable from the keyboard. The first one already answers to
        // Return; the rest would otherwise need the mouse, which for a dialog that
        // interrupts a keyboard shortcut is a strange thing to insist on.
        var buttons: [NSButton] = []
        if let image {
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
            view.image = NSImage(cgImage: image, size: .zero)
            view.imageScaling = .scaleProportionallyUpOrDown
            alert.accessoryView = view
            buttons.append(alert.addButton(withTitle: "Include screenshot"))
            buttons.append(alert.addButton(withTitle: "Text only"))
            buttons.append(alert.addButton(withTitle: "Cancel"))
            buttons[1].keyEquivalent = "t"
            buttons[1].keyEquivalentModifierMask = .command
        } else {
            buttons.append(alert.addButton(withTitle: "Continue text only"))
            buttons.append(alert.addButton(withTitle: "Cancel"))
            if !hasPermission {
                buttons.append(alert.addButton(withTitle: "Screenshot settings…"))
                buttons[2].keyEquivalent = "s"
                buttons[2].keyEquivalentModifierMask = .command
            }
        }
        buttons[0].keyEquivalent = "\r"
        buttons[1].keyEquivalent = "\u{1b}"

        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = image != nil
            ? "Don't ask again — hand it over as soon as I press the key"
            : "Don't ask again — carry on without a screenshot"

        NSApp.activate(ignoringOtherApps: true)
        let result = alert.runModal()
        let choice: Handoff.ReviewChoice = image != nil
            ? (result == .alertFirstButtonReturn ? .includeImage
                : result == .alertSecondButtonReturn ? .textOnly : .cancel)
            : (result == .alertFirstButtonReturn ? .textOnly
                : result == .alertThirdButtonReturn ? .permission : .cancel)

        // Remember the answer they just gave, not a guess at which one they meant.
        // Cancelling is not a preference about future handoffs.
        if alert.suppressionButton?.state == .on {
            switch choice {
            case .includeImage: preference = .alwaysInclude
            case .textOnly: preference = .alwaysTextOnly
            case .cancel, .permission: break
            }
        }
        return choice
    }

    func show(prompt: String, image: CGImage?, message: String) {
        close()
        self.prompt = prompt
        self.image = image
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Finish your handoff"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        let text = NSTextField(wrappingLabelWithString: message)
        text.preferredMaxLayoutWidth = 340
        let copyPrompt = NSButton(title: "Copy prompt", target: self, action: #selector(copyText))
        let copyImage = NSButton(title: "Copy screenshot", target: self, action: #selector(copyScreenshot))
        copyImage.isEnabled = image != nil
        let done = NSButton(title: "Done", target: self, action: #selector(close))
        let buttons = NSStackView(views: [copyPrompt, copyImage, done])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [text, buttons])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.frame = panel.contentView!.bounds
        stack.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(stack)
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 400, y: frame.minY + 24))
        }
        self.panel = panel
        panel.orderFrontRegardless()
        expiry = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in self?.close() }
    }

    @objc private func copyText() {
        if let prompt { Pasteboard.beginStaging().put(text: prompt) }
    }
    @objc private func copyScreenshot() {
        if let image { Pasteboard.beginStaging().put(image: image) }
    }
    @objc func close() {
        expiry?.invalidate()
        expiry = nil
        panel?.orderOut(nil)
        panel = nil
        prompt = nil
        image = nil
    }
}
