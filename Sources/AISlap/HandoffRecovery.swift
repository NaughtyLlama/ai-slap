import AppKit

/// The one dialog this app has: what is about to be sent, and a place to say what you
/// want done with it. Also the rescue panel for the paths where the paste didn't happen.
///
/// Payloads stay in memory for at most five minutes, or until closed, replaced or erased.
final class HandoffRecovery: NSObject {
    static let shared = HandoffRecovery()
    private var panel: NSPanel?
    private var prompt: String?
    private var image: CGImage?
    private var expiry: Timer?

    /// What gets sent when you don't type anything.
    ///
    /// Deliberately a question about the screenshot rather than a claim about your work.
    /// The app has no idea what you are doing — it has a picture and nothing else — and
    /// a prompt that pretends otherwise just wastes the first line of the conversation.
    static let defaultPrompt = "Here's my screen. Help me with this."

    /// Whether the handoff stops to show you the screenshot first.
    ///
    /// It defaults to asking, because the app is about to send a photograph of your
    /// screen and this is where you get to look at it. But a confirmation you always
    /// answer the same way is just a second keystroke, so it can be switched off from
    /// the dialog doing the asking, and switched back on from the menu.
    enum Preference: String { case ask, alwaysInclude, alwaysTextOnly }

    static var preference: Preference {
        get { Preference(rawValue: UserDefaults.standard.string(forKey: "handoffReview") ?? "") ?? .ask }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "handoffReview") }
    }

    static func review(image: CGImage?, hasPermission: Bool, prompt: String) -> Handoff.ReviewChoice {
        switch preference {
        case .alwaysInclude: return .send(prompt: prompt, includeImage: image != nil)
        case .alwaysTextOnly: return .send(prompt: prompt, includeImage: false)
        case .ask: break
        }

        let alert = NSAlert()
        alert.messageText = image == nil ? "Send this without a screenshot?" : "Send this to your AI?"
        alert.informativeText = image != nil
            ? "This is what will be sent. Nothing is submitted for you — you get the last word in the chat."
            : hasPermission
                ? "The window couldn't be captured, so this will go over as text. Nothing else was substituted."
                : "Screenshots need Screen Recording. You can send this as text now, or turn the permission on and try again."

        // The prompt field is the point. The app knows nothing about your work beyond a
        // picture of it, so the one useful thing it can do is get out of the way and let
        // you say what you actually want before the chat opens.
        let field = NSTextField(string: prompt)
        field.placeholderString = "What do you want done with this?"
        field.lineBreakMode = .byWordWrapping
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        if let image {
            let view = NSImageView()
            view.image = NSImage(cgImage: image, size: .zero)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.translatesAutoresizingMaskIntoConstraints = false
            view.heightAnchor.constraint(equalToConstant: 240).isActive = true
            view.widthAnchor.constraint(equalToConstant: 440).isActive = true
            stack.addArrangedSubview(view)
        }
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 440).isActive = true
        stack.addArrangedSubview(field)
        stack.frame = NSRect(x: 0, y: 0, width: 440, height: image == nil ? 44 : 294)
        alert.accessoryView = stack

        var buttons: [NSButton] = []
        buttons.append(alert.addButton(withTitle: image == nil ? "Send as text" : "Send"))
        if image != nil {
            buttons.append(alert.addButton(withTitle: "Without screenshot"))
            buttons[1].keyEquivalent = "t"
            buttons[1].keyEquivalentModifierMask = .command
        }
        buttons.append(alert.addButton(withTitle: "Cancel"))
        if image == nil && !hasPermission {
            buttons.append(alert.addButton(withTitle: "Turn on screenshots…"))
            buttons.last?.keyEquivalent = "s"
            buttons.last?.keyEquivalentModifierMask = .command
        }
        buttons.last(where: { $0.title == "Cancel" })?.keyEquivalent = "\u{1b}"

        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again — just send it"

        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        let result = alert.runModal()
        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalPrompt = typed.isEmpty ? defaultPrompt : typed

        let choice: Handoff.ReviewChoice
        switch result {
        case .alertFirstButtonReturn:
            choice = .send(prompt: finalPrompt, includeImage: image != nil)
        case .alertSecondButtonReturn where image != nil:
            choice = .send(prompt: finalPrompt, includeImage: false)
        case .alertThirdButtonReturn where image == nil && !hasPermission:
            choice = .permission
        case .alertSecondButtonReturn where image == nil && !hasPermission:
            choice = .cancel
        default:
            choice = .cancel
        }

        // Remember the answer they just gave, not a guess at which one they meant.
        // Cancelling is not a preference about future handoffs.
        if alert.suppressionButton?.state == .on, case .send(_, let withImage) = choice {
            preference = withImage ? .alwaysInclude : .alwaysTextOnly
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
