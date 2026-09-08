import AppKit
import ApplicationServices

/// The view Doug is painted into. Flipped, so the grids in `DougSprite` can stay
/// exactly as the design file writes them — top-left origin, y downward.
///
/// It is sized to the sprite and nothing more, which is how the click-through
/// requirement in docs/04 is met: instead of tracking the sprite's frame and toggling
/// `ignoresMouseEvents` per region, the window *is* the sprite's frame. Every pixel
/// outside Doug belongs to the app underneath because there is no window there.
final class DougView: NSView {

    var mood: Doug.Mood = .sleep { didSet { if mood != oldValue { needsDisplay = true } } }
    var legFrame = false { didSet { if legFrame != oldValue { needsDisplay = true } } }
    var facingLeft = false { didSet { if facingLeft != oldValue { needsDisplay = true } } }
    var scale: CGFloat = 3

    /// A click on Doug is a handoff. docs/04: the mascot is the button, and a mascot
    /// that only nags gets muted.
    var onClick: (() -> Void)?
    /// Dropped somewhere other than where he was picked up.
    var onDrop: ((NSPoint) -> Void)?
    var onDragged: ((NSSize) -> Void)?

    private var dragOrigin: NSPoint?
    private var dragDistance: CGFloat = 0

    override var isFlipped: Bool { true }

    /// VoiceOver should not announce a wandering crab. docs/04: the mascot is
    /// decorative; the speech bubble is the part that has to be readable.
    override func accessibilityIsIgnored() -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Doug.draw(mood: mood, scale: scale, legFrame: legFrame, facingLeft: facingLeft)
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = NSEvent.mouseLocation
        dragDistance = 0
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragOrigin != nil else { return }
        dragDistance += abs(event.deltaX) + abs(event.deltaY)
        onDragged?(NSSize(width: event.deltaX, height: event.deltaY))
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragOrigin = nil }
        guard dragOrigin != nil else { return }
        // Four points of slop: a click with a shaky hand is still a click, and the
        // two gestures do the same thing anyway — this only decides which one the
        // engine is told about.
        if dragDistance > 4 {
            onDrop?(NSEvent.mouseLocation)
        } else {
            onClick?()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}


/// The taste controls docs/04 makes non-optional, kept next to the thing they control.
///
/// They live in `UserDefaults` rather than in `InterruptionEngine` on purpose: the engine
/// decides *whether* to interrupt, and everything here is about what an interruption
/// looks like once that decision is made. Mixing the two is how the mascot-free path
/// stops working without anyone noticing.
enum MascotSettings {

    /// docs/04 requires a mascot-free mode: some people will hate the character, and
    /// enterprise will require it. Off means the bubble appears without him.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "mascotEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "mascotEnabled") }
    }

    static var calmMode: Bool {
        get { UserDefaults.standard.object(forKey: "calmMode") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "calmMode") }
    }

    /// **Tier 4 is opt-in only and never reachable by escalation.** That is why the cap
    /// defaults to 3: raising it is a deliberate act, and lowering it is how any tier
    /// ≥ 3 gets individually disabled, which docs/04 also requires.
    static var maxTier: DougWindow.Tier {
        get {
            let raw = UserDefaults.standard.object(forKey: "maxTier") as? Int ?? 3
            return DougWindow.Tier(rawValue: raw) ?? .scuttle
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "maxTier") }
    }
}


/// A panel that holds a character and never takes focus.
private final class MascotPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}


/// Doug on the desktop: where he lives, how he moves, and the escalation ladder from
/// docs/04 expressed as five tiers of behaviour.
///
/// **Performance is a product requirement, not a nicety.** docs/04 sets 0% CPU while he
/// sleeps — not a paused loop, no render loop at all. So there is no display link and no
/// always-on timer here. A frame timer exists only while something is actually moving,
/// and is torn down the moment it stops. Tier 1, which should be the overwhelming
/// majority of interruptions, is a single repaint followed by nothing.
final class DougWindow {

    /// Interruption strength. Escalation happens only *within* one sustained context;
    /// switching apps drops straight back to `.ambient`.
    enum Tier: Int, CaseIterable, Comparable {
        case ambient = 0, sideEye, clack, scuttle, hardMode

        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .ambient:  return "Ambient — naps in a corner"
            case .sideEye:  return "Side-eye — looks at your window"
            case .clack:    return "Clack — speech bubble"
            case .scuttle:  return "Scuttle — crosses the screen"
            case .hardMode: return "Hard mode — sits on your work"
            }
        }

        var mood: Doug.Mood {
            switch self {
            case .ambient:  return .sleep
            case .sideEye:  return .watch
            case .clack:    return .annoyed
            case .scuttle:  return .grumpy
            case .hardMode: return .grumpy
            }
        }
    }

    /// docs/04 caps the cursor tug hard, and this is the cap.
    static let hardModeInterval: TimeInterval = 60 * 60

    /// Frames per second while anything is moving. Doug is a 34×22 sprite; more than
    /// this buys nothing and costs battery on a resident process.
    private static let frameRate: TimeInterval = 1.0 / 30.0

    var onHandoffGesture: (() -> Void)?

    private let panel: MascotPanel
    private let view: DougView
    private var frameTimer: Timer?
    private var wanderTimer: Timer?
    private var moodTimer: Timer?

    private var tier: Tier = .ambient
    private var moodOverride: Doug.Mood?
    private var isHidden = false
    private var isDragging = false
    private var phase = 0
    private var direction: CGFloat = -1
    private var walkUntil: Date?
    private var scuttleTarget: CGFloat?
    private var homeTarget: NSPoint?
    private var lastCursorTug: Date?

    /// Where Doug is pointing — the frame of the window the nudge is about, read over
    /// Accessibility. nil when that can't be read, which is the un-permissioned case.
    private var focusFrame: NSRect?

    var scale: CGFloat {
        get { view.scale }
        set {
            view.scale = newValue
            panel.setContentSize(Doug.size(scale: newValue))
            view.needsDisplay = true
        }
    }

    /// Calm mode from docs/04: he never wanders, appears only to interrupt, moves
    /// minimally. Vestibular sensitivity is common and a wandering sprite is a genuine
    /// accessibility problem, so the system setting forces this on regardless.
    var calmMode = false {
        didSet { calmMode ? stopWandering() : scheduleWander() }
    }

    private var motionIsReduced: Bool {
        calmMode || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    init() {
        let scale: CGFloat = 3
        view = DougView(frame: NSRect(origin: .zero, size: Doug.size(scale: scale)))
        view.scale = scale

        panel = MascotPanel(
            contentRect: view.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = view

        view.onClick = { [weak self] in self?.handoffGesture() }
        view.onDrop = { [weak self] _ in self?.handoffGesture() }
        view.onDragged = { [weak self] delta in self?.dragBy(delta) }

        // docs/04: he should end up on the screen with the active window, and survive
        // a display being unplugged mid-session.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.clampToScreen() }
    }

    // MARK: - Visibility

    private(set) var isEnabled = false

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        enabled ? present() : tearDown()
    }

    /// Suppression, and it has to be instant. docs/04 treats a mascot appearing during
    /// a screen share as the anecdote that kills the company, so this orders the window
    /// out rather than fading it, and kills every timer with it.
    func hide() {
        isHidden = true
        // A walk home is abandoned rather than resumed: `present()` puts him back in the
        // corner anyway, and leaving the target set would strand him there wearing the
        // walking face with no timer left to finish the walk.
        homeTarget = nil
        stopFrameTimer()
        stopWandering()
        panel.orderOut(nil)
    }

    func unhide() {
        guard isHidden else { return }
        isHidden = false
        guard isEnabled else { return }
        present()
    }

    private func present() {
        guard isEnabled, !isHidden else { return }
        moveHome()
        view.mood = displayMood
        panel.orderFrontRegardless()
        scheduleWander()
    }

    private func tearDown() {
        stopFrameTimer()
        stopWandering()
        moodTimer?.invalidate()
        moodTimer = nil
        panel.orderOut(nil)
    }

    /// The panel's frame in screen coordinates — what the speech bubble anchors to.
    var frameOnScreen: NSRect? {
        guard isEnabled, !isHidden, panel.isVisible else { return nil }
        return panel.frame
    }

    // MARK: - The ladder

    /// Move to a tier. Escalation is one way within a context; `reset()` is the only
    /// way back down, and a context change is what calls it.
    ///
    /// The cap is applied here rather than at the call sites, so there is exactly one
    /// place where "he will never do more than this" is true. Raising the cap to `.hardMode`
    /// is the opt-in docs/04 demands — from the default cap, no sequence of ignored
    /// nudges can reach it.
    func escalate(to newTier: Tier, focus: NSRect? = nil) {
        guard isEnabled else { return }
        let capped = min(newTier, MascotSettings.maxTier)
        guard capped > tier || (focus != nil && focus != focusFrame) else { return }
        setTier(max(capped, tier), focus: focus)
    }

    /// Switching apps resets to 0 — docs/04 is explicit that escalation only occurs
    /// within a single sustained context.
    func reset() {
        guard tier != .ambient else { return }
        setTier(.ambient, focus: nil)
    }

    private func setTier(_ newTier: Tier, focus: NSRect?) {
        tier = newTier
        focusFrame = focus ?? focusedWindowFrame()
        scuttleTarget = nil
        homeTarget = nil
        walkUntil = nil

        switch newTier {
        case .ambient:
            // He does not stop where the last nudge left him. Coming down from a tier
            // means walking back to his corner — which is also the answer to "he is
            // standing on my window and the nudge is over".
            goHome()

        case .sideEye:
            // The highest-value interaction in the product and the cheapest: he stops,
            // turns to face your window, and then nothing happens at all — one repaint,
            // no timer. Peripheral guilt costs no CPU.
            stopWandering()
            stopFrameTimer()
            view.facingLeft = facingTowardFocus()
            view.legFrame = false
            view.mood = displayMood
            view.needsDisplay = true

        case .clack:
            stopWandering()
            view.facingLeft = facingTowardFocus()
            view.mood = displayMood
            clack()

        case .scuttle:
            stopWandering()
            scuttleTarget = scuttleDestinationX()
            view.mood = displayMood
            startFrameTimer()

        case .hardMode:
            stopWandering()
            stopFrameTimer()
            perchOnFocus()
            view.mood = displayMood
            view.needsDisplay = true
            tugCursor()
        }
    }

    /// A handoff just landed. Brief celebration, then back to sleep — the whole mood
    /// loop in docs/04 in three lines.
    func celebrate() {
        guard isEnabled else { return }
        moodOverride = .delighted
        view.mood = .delighted
        view.needsDisplay = true
        moodTimer?.invalidate()
        moodTimer = Timer.scheduledTimer(withTimeInterval: 2.4, repeats: false) {
            [weak self] _ in
            self?.moodOverride = nil
            self?.setTier(.ambient, focus: nil)
        }
    }

    /// Walking home he is `.content`, not `.sleep` — a sleeping face on a moving crab
    /// reads as a bug, and content is the honest state anyway: the nudge is over.
    private var displayMood: Doug.Mood {
        if let moodOverride { return moodOverride }
        if homeTarget != nil { return .content }
        return tier.mood
    }

    // MARK: - Movement

    private func startFrameTimer() {
        guard frameTimer == nil, !isHidden, isEnabled else { return }
        frameTimer = Timer.scheduledTimer(
            withTimeInterval: Self.frameRate, repeats: true
        ) { [weak self] _ in self?.step() }
    }

    private func stopFrameTimer() {
        frameTimer?.invalidate()
        frameTimer = nil
        view.legFrame = false
    }

    /// One animation frame. Everything that moves goes through here so there is exactly
    /// one timer to account for when the battery question comes up.
    private func step() {
        guard !isDragging else { return }
        phase += 1
        view.legFrame = (phase / 9) % 2 == 1

        var frame = panel.frame
        let speed: CGFloat = tier == .scuttle ? 6.5 : 1.2

        if let home = homeTarget {
            // An unhurried amble back, on both axes — tier 4 leaves him perched partway
            // up a window, so returning along x alone would strand him in mid-air.
            let dx = home.x - frame.origin.x
            let dy = home.y - frame.origin.y
            let distance = max(abs(dx), abs(dy))
            direction = dx < 0 ? -1 : 1
            view.facingLeft = direction < 0

            if distance <= speed {
                panel.setFrameOrigin(home)
                homeTarget = nil
                stopFrameTimer()
                view.mood = displayMood
                view.needsDisplay = true
                scheduleWander()
                return
            }
            frame.origin.x += speed * dx / distance
            frame.origin.y += speed * dy / distance
            panel.setFrameOrigin(frame.origin)
            return
        }

        if let target = scuttleTarget {
            // Sideways, because that is how a crab crosses a room.
            let remaining = target - frame.origin.x
            direction = remaining < 0 ? -1 : 1
            view.facingLeft = direction < 0
            if abs(remaining) <= speed {
                frame.origin.x = target
                panel.setFrameOrigin(frame.origin)
                scuttleTarget = nil
                stopFrameTimer()
                view.facingLeft = facingTowardFocus()
                view.needsDisplay = true
                return
            }
            frame.origin.x += speed * direction
        } else {
            if let until = walkUntil, Date() >= until {
                walkUntil = nil
                stopFrameTimer()
                view.needsDisplay = true
                scheduleWander()
                return
            }
            frame.origin.x += speed * direction
            view.facingLeft = direction < 0
        }

        if let bounds = currentScreen?.visibleFrame {
            if frame.minX < bounds.minX + 8 {
                frame.origin.x = bounds.minX + 8
                direction = 1
            }
            if frame.maxX > bounds.maxX - 8 {
                frame.origin.x = bounds.maxX - frame.width - 8
                direction = -1
            }
        }
        panel.setFrameOrigin(frame.origin)
    }

    /// Tier 0 is asleep, not idling. He wakes on a long random interval, scuttles for a
    /// couple of seconds, and goes back to having no timer running at all.
    private func scheduleWander() {
        stopWandering()
        guard isEnabled, !isHidden, tier == .ambient, !motionIsReduced else { return }
        let delay = TimeInterval.random(in: 70...200)
        wanderTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) {
            [weak self] _ in
            guard let self, self.tier == .ambient else { return }
            self.walkUntil = Date().addingTimeInterval(.random(in: 1.5...4))
            self.direction = Bool.random() ? 1 : -1
            self.startFrameTimer()
        }
    }

    private func stopWandering() {
        wanderTimer?.invalidate()
        wanderTimer = nil
    }

    private func clack() {
        // One clack of the claw: two beats of leg frames and then still. Under reduced
        // motion he simply arrives, which is the same interruption without the movement.
        guard !motionIsReduced else {
            view.needsDisplay = true
            return
        }
        var beats = 0
        stopFrameTimer()
        frameTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) {
            [weak self] timer in
            guard let self else { return }
            self.view.legFrame.toggle()
            beats += 1
            if beats >= 6 {
                timer.invalidate()
                self.frameTimer = nil
                self.view.legFrame = false
            }
        }
    }

    private func dragBy(_ delta: NSSize) {
        isDragging = true
        stopFrameTimer()
        var origin = panel.frame.origin
        origin.x += delta.width
        origin.y -= delta.height  // screen coordinates are y-up; mouse deltas are not
        panel.setFrameOrigin(origin)
    }

    private func handoffGesture() {
        isDragging = false
        onHandoffGesture?()
    }

    // MARK: - Placement

    private var currentScreen: NSScreen? {
        let point = panel.frame.origin
        return NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
    }

    /// Bottom-right, clear of the Dock — the corner the speech bubble is designed to
    /// sit above.
    ///
    /// Measured against the screen he is currently standing on rather than the one under
    /// the pointer, so a walk home never turns into a jump between displays.
    private func homePoint(preferPointer: Bool = false) -> NSPoint? {
        let screen = preferPointer
            ? (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                ?? NSScreen.main)
            : currentScreen
        guard let visible = screen?.visibleFrame else { return nil }
        let size = panel.frame.size
        return NSPoint(x: visible.maxX - size.width - 28, y: visible.minY + 24)
    }

    private func moveHome() {
        guard let home = homePoint(preferPointer: true) else { return }
        panel.setFrameOrigin(home)
    }

    /// Back to the corner under his own steam. He only walks if he is actually somewhere
    /// else, and under reduced motion he is simply there — calm mode means he appears to
    /// interrupt and otherwise stays out of your eye, and a crab ambling across the
    /// screen is the exact motion that setting exists to remove.
    private func goHome() {
        guard let home = homePoint() else {
            stopFrameTimer()
            view.mood = displayMood
            scheduleWander()
            return
        }

        let distance = max(
            abs(home.x - panel.frame.origin.x), abs(home.y - panel.frame.origin.y)
        )
        guard distance > 2 else {
            homeTarget = nil
            stopFrameTimer()
            view.mood = displayMood
            view.needsDisplay = true
            scheduleWander()
            return
        }

        guard !motionIsReduced else {
            homeTarget = nil
            stopFrameTimer()
            panel.setFrameOrigin(home)
            view.mood = displayMood
            view.needsDisplay = true
            return
        }

        homeTarget = home
        view.mood = displayMood
        stopWandering()
        startFrameTimer()
    }

    private func clampToScreen() {
        guard let visible = currentScreen?.visibleFrame else { moveHome(); return }
        var frame = panel.frame
        if !visible.intersects(frame) { moveHome(); return }
        frame.origin.x = min(max(frame.minX, visible.minX + 8), visible.maxX - frame.width - 8)
        frame.origin.y = min(max(frame.minY, visible.minY + 8), visible.maxY - frame.height - 8)
        panel.setFrameOrigin(frame.origin)
    }

    /// Where a scuttle ends: beside the window the nudge is about, or the far side of
    /// the screen if that frame can't be read.
    private func scuttleDestinationX() -> CGFloat {
        guard let focus = focusFrame else {
            guard let visible = currentScreen?.visibleFrame else { return panel.frame.minX }
            return panel.frame.midX > visible.midX
                ? visible.minX + 24
                : visible.maxX - panel.frame.width - 24
        }
        return focus.midX - panel.frame.width / 2
    }

    /// Tier 4 only: he sits on the bottom-right of the window you are working in,
    /// which in practice is on top of the compose box.
    private func perchOnFocus() {
        guard let focus = focusFrame ?? focusedWindowFrame() else { return }
        panel.setFrameOrigin(NSPoint(
            x: focus.maxX - panel.frame.width - 24,
            y: focus.minY + 16
        ))
    }

    private func facingTowardFocus() -> Bool {
        guard let focus = focusFrame else { return view.facingLeft }
        return focus.midX < panel.frame.midX
    }

    /// docs/04 gates this hard, and every clause below is one of those gates: opt-in
    /// tier only, never mid-click, never more than once an hour, and a nudge of a few
    /// points rather than a capture of the cursor.
    private func tugCursor() {
        guard tier == .hardMode, !motionIsReduced else { return }
        guard NSEvent.pressedMouseButtons == 0 else { return }
        if let last = lastCursorTug, Date().timeIntervalSince(last) < Self.hardModeInterval {
            return
        }
        lastCursorTug = Date()

        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main else { return }

        let target = NSPoint(
            x: mouse.x + (panel.frame.midX < mouse.x ? -18 : 18),
            y: mouse.y
        )
        // CGWarp works in flipped global display coordinates, not AppKit's.
        let flipped = CGPoint(x: target.x, y: screen.frame.maxY - target.y)
        CGWarpMouseCursorPosition(flipped)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// The frontmost window's frame over Accessibility — the same permission the
    /// detector already holds, so this asks for nothing new. Without it Doug still
    /// works; he just has nothing to point at, and falls back to screen geometry.
    private func focusedWindowFrame() -> NSRect? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication
        else { return nil }

        let element = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXFocusedWindowAttribute as CFString, &windowRef
        ) == .success, let window = windowRef else { return nil }

        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        let axWindow = unsafeBitCast(window, to: AXUIElement.self)
        guard AXUIElementCopyAttributeValue(
                axWindow, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(
                axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef, let sizeValue = sizeRef
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(
            unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &origin)
        AXValueGetValue(
            unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size)

        // Accessibility reports top-left origin on the primary display's flipped
        // coordinate space; AppKit windows are bottom-left. Convert, or Doug points at
        // a window that is nowhere near where he thinks it is on a tall display.
        guard let primary = NSScreen.screens.first else { return nil }
        return NSRect(
            x: origin.x,
            y: primary.frame.maxY - origin.y - size.height,
            width: size.width,
            height: size.height
        )
    }
}
