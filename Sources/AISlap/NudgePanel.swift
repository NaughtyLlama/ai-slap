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
/// It is now drawn as Doug's speech bubble rather than as system chrome: paper, hard ink
/// border, misregistered accent shadow, and a stepped tail pointing back at him. When he
/// is switched off or suppressed the tail goes away and the bubble stands on its own —
/// the four buttons are the part that matters and they are identical either way.
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

    /// Exposed for `scripts/design-preview.sh`; nothing in the app itself reads it.
    var panelForPreview: NSPanel? { panel }

    /// Called when the bubble has sat unanswered long enough to be worth escalating —
    /// the tier-2 → tier-3 transition in docs/04. It fires once, and only while the
    /// bubble is still up.
    var onLinger: (() -> Void)?

    /// docs/04: ignoring a tier-2 for another stretch on the same context earns a
    /// tier-3. This is that stretch.
    static let lingerDelay: TimeInterval = 90

    private var linger: Timer?

    func show(
        copy: String,
        prompt: String,
        anchor: NSRect? = nil,
        onRespond: @escaping (Response) -> Void
    ) {
        close()
        self.onRespond = onRespond

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: BubbleView.width, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The bubble draws its own accent shadow, misregistered by design. A system
        // shadow underneath it turns that into mud.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        // Never steal focus: the user is mid-sentence in the app underneath.
        panel.becomesKeyOnlyIfNeeded = true

        let content = buildContent(copy: copy, prompt: prompt, tail: anchor != nil)
        panel.setContentSize(content.frame.size)
        panel.contentView = content

        position(panel, anchor: anchor)
        panel.orderFrontRegardless()
        self.panel = panel

        timeout = Timer.scheduledTimer(
            withTimeInterval: Self.ignoreTimeout, repeats: false
        ) { [weak self] _ in
            self?.respond(.ignored)
        }
        linger = Timer.scheduledTimer(
            withTimeInterval: Self.lingerDelay, repeats: false
        ) { [weak self] _ in
            self?.onLinger?()
        }
    }

    /// Move an already-visible bubble — used when Doug scuttles out from under it.
    func reanchor(to anchor: NSRect?) {
        guard let panel else { return }
        position(panel, anchor: anchor)
    }

    func close() {
        timeout?.invalidate()
        timeout = nil
        linger?.invalidate()
        linger = nil
        panel?.orderOut(nil)
        panel = nil
        onRespond = nil
    }

    // MARK: - Layout

    private func buildContent(copy: String, prompt: String, tail: Bool) -> NSView {
        let inset: CGFloat = 15
        let innerWidth = BubbleView.width - inset * 2

        let title = NSTextField(wrappingLabelWithString: copy)
        title.font = .systemFont(ofSize: 15.5, weight: .semibold)
        title.textColor = Doug.Palette.standard.ink
        title.isSelectable = false
        title.preferredMaxLayoutWidth = innerWidth

        let detail = NSTextField(wrappingLabelWithString: prompt)
        detail.font = .systemFont(ofSize: 12)
        // The muted ink from the design file — not a system secondary label, which
        // resolves against the system appearance and washes out on Doug's paper.
        detail.textColor = NSColor(srgbRed: 0.388, green: 0.361, blue: 0.333, alpha: 1)
        detail.isSelectable = false
        detail.preferredMaxLayoutWidth = innerWidth

        let accept = PixelButton(
            "Hand it over", target: self, action: #selector(tapAccept), style: .primary)
        // docs/02: the only coverage for AI used on a phone or another machine, and a
        // high rate here is a detection bug rather than user error.
        let already = PixelButton(
            "I already did", target: self, action: #selector(tapAlreadyDid), style: .plain)
        let notNow = PixelButton(
            "Not now", target: self, action: #selector(tapDismiss), style: .plain)
        let mute = PixelButton(
            "Stop suggesting this", target: self, action: #selector(tapMute), style: .quiet)

        let topRow = NSStackView(views: [accept, already])
        topRow.orientation = .horizontal
        topRow.spacing = 6
        topRow.distribution = .fillEqually

        let bottomRow = NSStackView(views: [notNow, mute])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 6
        bottomRow.distribution = .fillEqually

        let stack = NSStackView(views: [title, detail, topRow, bottomRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.setCustomSpacing(6, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Without this the rows hug their titles and the four buttons come out four
        // different widths — which reads as three afterthoughts beside a primary,
        // rather than four equal answers, which is what they are.
        for row in [topRow, bottomRow] {
            row.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
        }

        let sizer = NSView()
        sizer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: sizer.topAnchor),
            stack.leadingAnchor.constraint(equalTo: sizer.leadingAnchor),
            stack.widthAnchor.constraint(equalToConstant: innerWidth),
        ])
        let bodyHeight = stack.fittingSize.height
        let bubbleHeight = bodyHeight + inset * 2

        let bubble = BubbleView(bubbleHeight: bubbleHeight, showsTail: tail)
        bubble.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = true
        stack.frame = NSRect(
            x: inset,
            y: bubble.bounds.height - bubbleHeight + inset,
            width: innerWidth,
            height: bodyHeight
        )
        stack.autoresizingMask = []
        return bubble
    }

    /// Above Doug when he is on screen, so the tail points at him. Otherwise
    /// bottom-right of whichever screen holds the pointer, clear of the Dock.
    private func position(_ panel: NSPanel, anchor: NSRect?) {
        let size = panel.frame.size

        if let anchor {
            let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }
                ?? NSScreen.main
            guard let visible = screen?.visibleFrame else { return }
            let x = min(
                max(visible.minX + 8, anchor.midX - BubbleView.tailInset - 14),
                visible.maxX - size.width - 8
            )
            let y = min(anchor.maxY + 6, visible.maxY - size.height - 8)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - size.width - 20,
            y: visible.minY + 20
        ))
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


/// The bubble itself: accent plate, paper, hard ink border, stepped tail.
///
/// Drawn rather than composed from layers because the accent plate is *offset* from the
/// paper, not blurred behind it — that misregistration is the same one the sprite uses,
/// and a `shadowOffset` with a blur radius of zero is a fight with CoreAnimation for no
/// gain.
private final class BubbleView: NSView {

    static let width: CGFloat = 344
    static let border: CGFloat = 3
    static let shadow: CGFloat = 6
    static let step: CGFloat = 6
    static let tailInset: CGFloat = 30

    private let bubbleHeight: CGFloat
    private let showsTail: Bool

    init(bubbleHeight: CGFloat, showsTail: Bool) {
        self.bubbleHeight = bubbleHeight
        self.showsTail = showsTail
        let tail = showsTail ? Self.step * 3 : 0
        super.init(frame: NSRect(
            x: 0, y: 0,
            width: Self.width + Self.shadow,
            height: bubbleHeight + Self.shadow + tail
        ))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Doug.Palette.standard
        let tail = showsTail ? Self.step * 3 : 0
        let paper = NSRect(
            x: 0, y: bounds.height - bubbleHeight,
            width: Self.width, height: bubbleHeight
        )

        palette.accent.setFill()
        paper.offsetBy(dx: Self.shadow, dy: -Self.shadow).fill()

        palette.paper.setFill()
        paper.fill()

        palette.ink.setStroke()
        let outline = NSBezierPath(rect: paper.insetBy(dx: Self.border / 2, dy: Self.border / 2))
        outline.lineWidth = Self.border
        outline.stroke()

        guard showsTail else { return }
        // Three descending blocks rather than a triangle: the tail is made of the same
        // pixels Doug is, so it reads as part of him and not as a chat app.
        palette.ink.setFill()
        for (index, width) in [27.0, 18.0, 9.0].enumerated() {
            NSRect(
                x: Self.tailInset,
                y: bounds.height - bubbleHeight - Self.step * CGFloat(index + 1),
                width: CGFloat(width),
                height: Self.step
            ).fill()
        }
        _ = tail
    }
}


/// A flat button in Doug's palette. Four of these carry every response a nudge accepts,
/// so the visual weight has to say which one is primary without AppKit's help.
private final class PixelButton: NSButton {

    enum Style { case primary, plain, quiet }

    private let style: Style

    init(_ label: String, target: AnyObject, action: Selector, style: Style) {
        self.style = style
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        // A non-activating panel never becomes key, so AppKit never draws the default
        // button in the accent colour — the primary action came out looking as inert as
        // "Not now". Every button here is drawn explicitly for the same reason.
        if style == .primary { keyEquivalent = "\r" }
        title = ""
        attributedTitle = NSAttributedString(
            string: label.uppercased(),
            attributes: [
                .font: PixelButton.labelFont,
                .foregroundColor: style == .quiet
                    ? NSColor(srgbRed: 0.227, green: 0.208, blue: 0.188, alpha: 1)
                    : Doug.Palette.standard.ink,
                .kern: 0.6,
            ]
        )
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Silkscreen if it is installed — the design file loads it from Google Fonts, and
    /// it is not bundled here because that means shipping a binary asset and its
    /// licence. Monospaced system text at small size with tracking is the near miss,
    /// and if the font is ever installed this picks it up with no code change.
    static let labelFont: NSFont =
        NSFont(name: "Silkscreen", size: 9)
        ?? .monospacedSystemFont(ofSize: 9.5, weight: .bold)

    override func draw(_ dirtyRect: NSRect) {
        let palette = Doug.Palette.standard
        let rect = bounds.insetBy(dx: 1, dy: 1)

        switch style {
        case .primary:
            palette.accent.setFill()
            rect.fill()
        case .plain, .quiet:
            palette.paper.setFill()
            rect.fill()
            palette.ink.setStroke()
            let border = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
            border.lineWidth = 2
            // "Stop suggesting this" is the nag-fatigue control the product depends on,
            // so it stays on every nudge — but dashed, because it is the one choice that
            // should not compete with answering.
            if style == .quiet { border.setLineDash([4, 3], count: 2, phase: 0) }
            border.stroke()
        }

        super.draw(dirtyRect)
    }
}
