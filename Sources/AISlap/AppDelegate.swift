import AppKit

/// A hotkey, a screenshot, a chat window, a crab — and a light watch over which window
/// you are in, so the crab can suggest the handoff rather than waiting to be asked.
///
/// The watching was removed once and put back deliberately. What did *not* come back is
/// the part that made it heavy: the SQLite log of everywhere you had been and the
/// personaliser that learned from it. Rules are fixed, cooldowns are conservative, and
/// nothing about your day is written to disk. See `NudgeEngine`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menu: MenuBarController?
    private let hotkeys = GlobalHotkeys()
    private let doug = DougWindow()
    private let nudgePanel = NudgePanel()
    private let observer = WindowContextObserver()
    private var engine: NudgeEngine?
    private var handoff: Handoff?
    private var hotkeyRegistered = false
    private var lastResult: Handoff.Result?
    private var tickTimer: Timer?
    private var currentContext: WindowContext?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let handoff = Handoff(destinations: Destinations.load())
        self.handoff = handoff

        // A broken rulebook costs you the nudges, never the handoff. The app's one job
        // still works if this throws.
        if let rulebook = try? Rulebook.loadBundled() {
            let engine = NudgeEngine(rulebook: rulebook, handoff: handoff)
            self.engine = engine
            engine.onNudge = { [weak self] copy, prompt, ruleID in
                self?.presentNudge(copy: copy, prompt: prompt, ruleID: ruleID)
            }
            engine.onHandoffResult = { [weak self] result in self?.report(result) }
            observer.onChange = { [weak self] context in self?.contextChanged(context) }
            observer.start()
            tickTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) {
                [weak self] _ in self?.tick()
            }
        } else {
            NSLog("AISlap: rulebook failed to load — handoff still works, nudges are off")
        }

        menu = MenuBarController(
            onHandoffNow: { [weak self] in self?.handoffNow() },
            onSetDestination: { [weak self] id in
                Handoff.preferredID = id
                Handoff.hasChosenDestination = true
                self?.doug.destinationName = self?.handoff?.preferredDestination?.name
                self?.refresh()
            },
            destinations: { [weak self] in
                guard let handoff = self?.handoff else { return [] }
                let active = handoff.preferredDestination?.id
                return handoff.availableDestinations.map {
                    (id: $0.id, name: $0.name, installed: $0.isNativeAvailable, active: $0.id == active)
                }
            },
            onToggleMascot: { [weak self] in
                MascotSettings.isEnabled.toggle()
                self?.doug.setEnabled(MascotSettings.isEnabled)
                self?.refresh()
            },
            onToggleCalmMode: { [weak self] in
                MascotSettings.calmMode.toggle()
                self?.doug.calmMode = MascotSettings.calmMode
                self?.refresh()
            },
            onToggleLaunchAtLogin: { [weak self] in self?.toggleLaunchAtLogin() },
            onFixPermission: { [weak self] in self?.openAccessibilitySettings() },
            onShowWelcome: { [weak self] in Onboarding.show(force: true) { self?.refresh() } },
            onToggleNudges: { [weak self] in
                guard let engine = self?.engine else { return }
                engine.isEnabled.toggle()
                if !engine.isEnabled { self?.nudgePanel.close(); self?.doug.reset() }
                self?.refresh()
            },
            onSnooze: { [weak self] minutes in
                self?.engine?.snooze(minutes: minutes)
                self?.nudgePanel.close()
                self?.doug.reset()
                self?.refresh()
            },
            onCancelSnooze: { [weak self] in self?.engine?.cancelSnooze(); self?.refresh() },
            lastHandoff: { [weak self] in self?.lastResult?.summary }
        )

        doug.onHandoffGesture = { [weak self] in self?.handoffNow() }
        doug.calmMode = MascotSettings.calmMode
        doug.setEnabled(MascotSettings.isEnabled)
        doug.destinationName = handoff.preferredDestination?.name

        registerHotkeys()
        refresh()

        // First run explains the two permissions and asks which AI to use. Everything
        // works without answering it — the menu has the same choices — but arriving at
        // a menu-bar icon with no idea what it wants is how a shared build dies quietly.
        Onboarding.showIfFirstRun { [weak self] in
            self?.doug.destinationName = self?.handoff?.preferredDestination?.name
            self?.refresh()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard handoff != nil else { return }
        Onboarding.resumeIfNeeded()
        refresh()
    }

    // MARK: - Watching, and the nudge

    /// Switching apps drops Doug straight back to sleep. Escalation happens only
    /// *within* one sustained context; carrying a tier across an app switch is how a
    /// mascot becomes a nag.
    private func contextChanged(_ context: WindowContext) {
        currentContext = context
        engine?.contextChanged(to: context)
        nudgePanel.close()
        doug.reset()
        refresh()
    }

    /// Every five seconds: has this sit earned an interruption, and should Doug look up
    /// yet. Tier 1 is the whole bet of the product — he stops and turns to face your
    /// window, costing one repaint and no attention at all.
    private func tick() {
        engine?.tick()
        guard let progress = engine?.dwellProgress() else {
            if !nudgePanel.isShowing { doug.reset() }
            return
        }
        if progress >= 0.5, !nudgePanel.isShowing {
            doug.escalate(to: .sideEye)
        }
    }

    private func presentNudge(copy: String, prompt: String, ruleID: String) {
        doug.escalate(to: .clack)
        nudgePanel.show(copy: copy, prompt: prompt, anchor: doug.frameOnScreen) {
            [weak self] response in
            guard let self else { return }
            switch response {
            case .accept:
                self.doug.celebrate()
                self.engine?.accept()
            case .alreadyDid:
                // Not a refusal. They are already doing the thing, so start the amnesty
                // clock rather than counting it against the rule.
                self.doug.celebrate()
                self.engine?.markUsedAI()
                self.engine?.decline()
            case .mute:
                self.engine?.muteForToday(ruleID)
                self.engine?.decline()
                self.doug.reset()
            case .dismiss, .ignored:
                self.engine?.decline()
                self.doug.reset()
            }
            self.refresh()
        }
    }

    // MARK: - The handoff

    private func handoffNow() {
        guard let handoff, let app = NSWorkspace.shared.frontmostApplication else { return }
        let target = Handoff.Target(
            pid: app.processIdentifier,
            title: WindowCapture.focusedWindowTitle(pid: app.processIdentifier),
            prompt: HandoffRecovery.defaultPrompt
        )
        handoff.run(target) { [weak self] result in self?.report(result) }
    }

    /// Silence after a failed paste looks exactly like a broken app, so every path that
    /// leaves the user holding something says so.
    private func report(_ result: Handoff.Result) {
        lastResult = result
        switch result {
        case .pasteRequested:
            doug.celebrate()
        case .clipboardOnly:
            doug.reset()  // The recovery panel is already on screen saying what to do.
        case .cancelled:
            doug.reset()
        case .needsScreenRecording:
            doug.reset()
            let alert = NSAlert()
            alert.messageText = "Turn on screenshots, then try again"
            alert.informativeText = "Add AI-slap under Privacy & Security → Screen Recording. If macOS asks you to quit and reopen it, do that first. Handoffs still work as text without it."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        case .failed(let message):
            doug.reset()
            let alert = NSAlert()
            alert.messageText = "That handoff couldn't continue"
            alert.informativeText = message
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        refresh()
    }

    // MARK: - Hotkeys

    /// ⌥Space hands off. ⌥⌘G hides Doug instantly, for screen shares.
    private func registerHotkeys() {
        hotkeyRegistered = hotkeys.register(id: GlobalHotkeys.handoffID, keyCode: 49, modifiers: 2048) {  // ⌥Space
            [weak self] in self?.handoffNow()
        }
        hotkeys.register(id: GlobalHotkeys.panicID, keyCode: 5, modifiers: 2048 | 256) { [weak self] in  // ⌥⌘G
            guard let self else { return }
            self.doug.isHidden ? self.doug.unhide() : self.doug.hide()
            self.refresh()
        }
    }

    // MARK: - Permissions and settings

    private func toggleLaunchAtLogin() {
        if let problem = LaunchAtLogin.set(!LaunchAtLogin.state.isOn) {
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login item"
            alert.informativeText = problem
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        refresh()
    }

    private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Accessibility can be revoked at any moment, and after a rebuild it can vanish
    /// silently, so it is re-read on every menu refresh rather than cached at launch.
    /// "Why hasn't it said anything?" has to be answerable from the menu, because
    /// there is no longer a log to go and read.
    private func nudgeStatus() -> String {
        guard let engine else { return "Rules didn't load — handoff still works" }
        guard engine.isEnabled else { return "Not watching" }
        if let until = engine.snoozedUntil, engine.isSnoozed {
            return "Quiet until \(Self.clock.string(from: until))"
        }
        let verdict = engine.suppression.check()
        if verdict.suppressed { return verdict.reason.map { "Quiet — \($0)" } ?? "Quiet" }
        guard let context = currentContext else { return "Watching" }
        guard let rule = engine.rules.filter({ $0.matches(context) })
            .max(by: { $0.rule.confidence < $1.rule.confidence })
        else { return "Nothing to say about \(context.appName)" }
        switch engine.gate(rule, context: context) {
        case .blocked(let why): return "Quiet — \(why)"
        case .pass:
            let progress = engine.dwellProgress() ?? 0
            return progress >= 1 ? "About to say something" 
                : "Watching \(context.appName) — \(Int(progress * 100))% of the way there"
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private func refresh() {
        menu?.update(
            hasAccessibility: AXIsProcessTrusted(),
            hasScreenRecording: WindowCapture.hasPermission,
            hotkeyRegistered: hotkeyRegistered,
            nudgesEnabled: engine?.isEnabled ?? false,
            nudgeStatus: nudgeStatus(),
            mascotEnabled: MascotSettings.isEnabled,
            calmMode: MascotSettings.calmMode,
            dougHidden: doug.isHidden,
            launchAtLogin: LaunchAtLogin.state
        )
    }
}
