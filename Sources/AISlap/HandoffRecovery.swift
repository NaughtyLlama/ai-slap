import AppKit

/// Payloads stay in memory for at most five minutes, or until closed/replaced/erased.
final class HandoffRecovery: NSObject {
    static let shared = HandoffRecovery()
    private var panel: NSPanel?
    private var prompt: String?
    private var image: CGImage?
    private var expiry: Timer?

    static func review(image: CGImage?, hasPermission: Bool) -> Handoff.ReviewChoice {
        let alert = NSAlert()
        alert.messageText = image == nil ? "Hand over text only?" : "Hand over this screenshot?"
        alert.informativeText = image != nil
            ? "Check that this is the window you meant to share. The screenshot and prompt will go to your AI app; nothing is submitted automatically."
            : hasPermission
                ? "The original window couldn't be identified uniquely or captured. No other window was substituted. You can still hand over the prompt."
                : "Screenshots are optional. Continue with the prompt, or enable Screen Recording and try again."
        if let image {
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
            view.image = NSImage(cgImage: image, size: .zero)
            view.imageScaling = .scaleProportionallyUpOrDown
            alert.accessoryView = view
            alert.addButton(withTitle: "Include screenshot")
            alert.addButton(withTitle: "Text only")
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.addButton(withTitle: "Continue text only")
            alert.addButton(withTitle: "Cancel")
            if !hasPermission { alert.addButton(withTitle: "Screenshot settings…") }
        }
        NSApp.activate(ignoringOtherApps: true)
        let result = alert.runModal()
        if image != nil {
            return result == .alertFirstButtonReturn ? .includeImage
                : result == .alertSecondButtonReturn ? .textOnly : .cancel
        }
        return result == .alertFirstButtonReturn ? .textOnly
            : result == .alertThirdButtonReturn ? .permission : .cancel
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
