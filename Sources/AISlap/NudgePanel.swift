import AppKit

/// The interruption itself: a small panel that appears and **stays until answered**.
///
/// This replaces the notification, which was the wrong container. A nudge carrying four
/// choices cannot live in a banner that removes itself after five seconds, and whether
/// it did so depended on a macOS preference the user had to know to change.
///
/// docs/04 specifies the window flags, and two of them are load-bearing:
///
/// - `.nonactivatingPanel` — the panel never takes keyboard focus, so you keep typing
///   into Gmail while it sits there. Without this the app is unusable.
/// - `.screenSaver` level plus `.fullScreenAuxiliary` — so it appears over full-screen
///   apps and follows you across Spaces instead of being stranded on desktop 1.
///
/// The character goes inside this window later. The behaviour — where it appears, how it
/// waits, what the buttons do — is the part that matters and is done here.
final class NudgePanel {

    /// If it is ignored this long, treat it as a soft no and take it away. An
    /// interruption that never resolves is its own kind of nag, and docs/03 wants
    /// dismissals feeding the backoff rather than accumulating as silence.
    static let ignoreTimeout: TimeInterval = 5 * 60

    enum Response {
        case accept
        case alreadyDid
        case dismiss
        case mute
        case ignored
    }

    private var panel: NSPanel?
    private var timeout: Timer?
    private var onRespond: ((Response) -> Void)?

    var isShowing: Bool { panel != nil }

    func show(copy: String, prompt: String, onRespond: @escaping (Response) -> Void) {
        close()
        self.onRespond = onRespond

        let width: CGFloat = 380
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // Never steal focus: the user is mid-sentence in the app underneath.
        panel.becomesKeyOnlyIfNeeded = true

        let content = buildContent(copy: copy, prompt: prompt, width: width)
        panel.setContentSize(content.fittingSize)
        panel.contentView = content

        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel

        timeout = Timer.scheduledTimer(
            withTimeInterval: Self.ignoreTimeout, repeats: false
        ) { [weak self] _ in
            self?.respond(.ignored)
        }
    }

    func close() {
        timeout?.invalidate()
        timeout = nil
        panel?.orderOut(nil)
        panel = nil
        onRespond = nil
    }

    // MARK: - Layout

    private func buildContent(copy: String, prompt: String, width: CGFloat) -> NSView {
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true

        let title = NSTextField(labelWithString: copy)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 3
        title.preferredMaxLayoutWidth = width - 32

        let detail = NSTextField(labelWithString: prompt)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 3
        detail.preferredMaxLayoutWidth = width - 32

        let accept = button("Hand it over", action: #selector(tapAccept), primary: true)
        // docs/02: the only coverage for AI used on a phone or another machine, and a
        // high rate here is a detection bug rather than user error.
        let already = button("I already did", action: #selector(tapAlreadyDid))
        let notNow = button("Not now", action: #selector(tapDismiss))
        let mute = button("Stop suggesting this", action: #selector(tapMute))

        let primaryRow = NSStackView(views: [accept, already])
        primaryRow.orientation = .horizontal
        primaryRow.spacing = 8
        primaryRow.distribution = .fillEqually

        let secondaryRow = NSStackView(views: [notNow, mute])
        secondaryRow.orientation = .horizontal
        secondaryRow.spacing = 8
        secondaryRow.distribution = .fillEqually

        let stack = NSStackView(views: [title, detail, primaryRow, secondaryRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.widthAnchor.constraint(equalToConstant: width),
        ])
        return background
    }

    private func button(
        _ title: String, action: Selector, primary: Bool = false
    ) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        if primary {
            button.keyEquivalent = "\r"
            button.bezelColor = .controlAccentColor
        } else {
            button.font = .systemFont(ofSize: 11)
        }
        return button
    }

    /// Bottom-right of whichever screen holds the pointer, clear of the Dock.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.maxX - size.width - 20,
            y: visible.minY + 20
        )
        panel.setFrameOrigin(origin)
    }

    // MARK: - Responses

    private func respond(_ response: Response) {
        let callback = onRespond
        close()
        callback?(response)
    }

    @objc private func tapAccept() { respond(.accept) }
    @objc private func tapAlreadyDid() { respond(.alreadyDid) }
    @objc private func tapDismiss() { respond(.dismiss) }
    @objc private func tapMute() { respond(.mute) }
}
