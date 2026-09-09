import AppKit
import ApplicationServices
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate,
                         UNUserNotificationCenterDelegate {

    private var store: SessionStore?
    private var engine: InterruptionEngine?
    private let observer = WindowContextObserver()
    private var menuBar: MenuBarController?

    private var currentContext: WindowContext?
    private var currentStartedAt: Date?
    private var isPaused = false
    private var menuRefreshTimer: Timer?
    private var notificationsAllowed = false
    private let hotkeys = GlobalHotkeys()
    private let nudgePanel = NudgePanel()
    private let doug = DougWindow()
    private var hotkeyRegistered = false
    private var hotkeyPresses = 0
    private var pendingPanel: (eventID: Int64, ruleID: String)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let store = try SessionStore()
            self.store = store

            let rulebook = try Rulebook.loadBundled()
            engine = InterruptionEngine(
                rulebook: rulebook,
                store: store,
                personalizer: Personalizer(store: store)
            )
            engine?.onFire = { [weak self] in self?.refreshMenu() }
        } catch {
            presentFatal(error)
            return
        }

        menuBar = MenuBarController(
            onTogglePause: { [weak self] in self?.togglePause() },
            onToggleNudges: { [weak self] in self?.toggleNudges() },
            onSetSensitivity: { [weak self] in self?.setSensitivity($0) },
            onSetAmnesty: { [weak self] in self?.setAmnesty($0) },
            onSetBudget: { [weak self] in self?.setBudget($0) },
            onShowLearned: { [weak self] in self?.showLearned() },
            onTestNudge: { [weak self] in self?.testNudge() },
            onSetStyle: { [weak self] in self?.setStyle($0) },
            onSetDestination: { [weak self] in self?.setDestination($0) },
            destinations: { [weak self] in self?.destinationChoices() ?? [] },
            onToggleMascot: { [weak self] in self?.toggleMascot() },
            onToggleCalmMode: { [weak self] in self?.toggleCalmMode() },
            onSetMaxTier: { [weak self] in self?.setMaxTier($0) },
            onTogglePanic: { [weak self] in self?.togglePanic() },
            onToggleLaunchAtLogin: { [weak self] in self?.toggleLaunchAtLogin() },
            onToggleRule: { [weak self] id, muted in
                self?.engine?.setUserMuted(id, muted: muted)
                self?.refreshMenu()
            },
            ruleStates: { [weak self] in self?.engine?.ruleStates() ?? [] },
            onHandoffNow: { [weak self] in self?.handoffNow() },
            onFixPermission: { [weak self] in self?.openAccessibilitySettings() },
            onExport: { [weak self] in self?.export() },
            onRevealData: { [weak self] in self?.revealData() },
            onDeleteAll: { [weak self] in self?.deleteAll() }
        )

        // The status line counts down toward a fire and reports why it's held, so it
        // has to move on its own rather than only on context change.
        menuRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: 5, repeats: true
        ) { [weak self] _ in
            self?.refreshMenu()
        }

        observer.onChange = { [weak self] context in
            self?.contextChanged(to: context)
        }

        engine?.onHandoffResult = { [weak self] result in
            self?.report(result)
        }

        // docs/05 entry point 1. Entry point 2 is the notification's "Hand it over";
        // the goose-drag is Phase 1.
        hotkeyRegistered = hotkeys.register(
            id: GlobalHotkeys.handoffID, keyCode: 49, modifiers: 2048  // Option-Space
        ) { [weak self] in
            self?.hotkeyPresses += 1
            self?.handoffNow()
            self?.refreshMenu()
        }
        if !hotkeyRegistered {
            NSLog("AISlap: could not register Option-Space — something else owns it.")
        }

        // docs/04: users need to trust they can make it vanish in one keystroke, or
        // they won't run it at all.
        hotkeys.register(
            id: GlobalHotkeys.panicID, keyCode: 5, modifiers: 2048 | 256  // Opt-Cmd-G
        ) { [weak self] in
            self?.panicHide()
        }

        engine?.onPresentPanel = { [weak self] copy, prompt, eventID, ruleID in
            self?.presentPanel(
                copy: copy, prompt: prompt, eventID: eventID, ruleID: ruleID
            )
        }

        // docs/04's one design rule: the mascot *is* the button. Clicking Doug or
        // dragging him onto a window runs the same handoff the shortcut runs — a mascot
        // that only nags gets muted.
        doug.onHandoffGesture = { [weak self] in self?.handoffFromDoug() }
        doug.calmMode = MascotSettings.calmMode
        doug.setEnabled(MascotSettings.isEnabled)

        // A bubble nobody answers is a soft no, and docs/04 escalates within the same
        // context rather than firing a second nudge at it.
        nudgePanel.onLinger = { [weak self] in self?.lingerEscalate() }

        UNUserNotificationCenter.current().delegate = self
        InterruptionEngine.registerNotificationCategory()
        requestNotificationPermission()

        // An unanswered nudge is a soft no. Left as "fired" it inflates the acceptance
        // denominator and never reaches the backoff.
        engine?.resolveStaleEvents()

        requestAccessibilityIfNeeded()
        observer.start()
        refreshMenu()

        doug.destinationName = engine?.handoff.preferredDestination?.name
        // After the menu bar exists, so the answer has somewhere to be reflected.
        askForDestinationIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        closeCurrentSession(at: Date())
    }

    // MARK: - Session bookkeeping

    private func contextChanged(to context: WindowContext) {
        let now = Date()
        closeCurrentSession(at: now)

        currentContext = context
        currentStartedAt = now

        // Switching apps drops him straight back to sleep. docs/04 is explicit that
        // escalation happens only *within* one sustained context — carrying a tier
        // across an app switch is how a mascot becomes a nag.
        doug.reset()

        if !isPaused {
            engine?.contextBegan(context, at: now)
        }
        refreshMenu()
    }

    private func closeCurrentSession(at end: Date) {
        engine?.contextEnded()

        guard !isPaused,
              let context = currentContext,
              let start = currentStartedAt,
              let store
        else {
            currentContext = nil
            currentStartedAt = nil
            return
        }

        let session = Session(context: context, startedAt: start, endedAt: end)
        do {
            try store.record(session, category: engine?.category(for: context))
        } catch {
            NSLog("AISlap: failed to record session — \(error.localizedDescription)")
        }
        currentContext = nil
        currentStartedAt = nil
    }

    // MARK: - Permissions

    /// One prompt, at launch, per the permission budget in docs/02. Screen Recording
    /// is never requested — nothing here captures anything.
    private func requestAccessibilityIfNeeded() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options = [key: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        if !trusted {
            NSLog("AISlap: Accessibility not granted — running on bundle IDs only.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.observer.refresh()
                self?.refreshMenu()
            }
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert]) { granted, error in
                if let error {
                    NSLog("AISlap: notification auth failed — \(error.localizedDescription)")
                } else if !granted {
                    NSLog("AISlap: notifications denied — nudges will not appear.")
                }
            }
    }

    // MARK: - Notification responses

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if let eventID = info["eventID"] as? Int64,
           let ruleID = info["ruleID"] as? String {
            engine?.handleResponse(
                actionIdentifier: response.actionIdentifier,
                eventID: eventID,
                ruleID: ruleID
            )
        }
        refreshMenu()
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    // MARK: - Menu actions

    private func togglePause() {
        if isPaused {
            isPaused = false
            observer.start()
            observer.refresh()
        } else {
            closeCurrentSession(at: Date())
            isPaused = true
            observer.stop()
        }
        refreshMenu()
    }

    private func toggleNudges() {
        guard let engine else { return }
        engine.isEnabled.toggle()
        refreshMenu()
    }

    private func setSensitivity(_ sensitivity: InterruptionEngine.Sensitivity) {
        engine?.sensitivity = sensitivity
        refreshMenu()
    }

    private func setAmnesty(_ amnesty: InterruptionEngine.Amnesty) {
        engine?.amnesty = amnesty
        refreshMenu()
    }

    private func setBudget(_ budget: Int) {
        engine?.dailyBudget = budget
        refreshMenu()
    }

    /// A system that quietly retunes itself has to be able to show its work, or the
    /// first surprising silence reads as a bug.
    private func showLearned() {
        guard let engine else { return }
        let alert = NSAlert()
        alert.messageText = "What AI-slap has learned about you"
        alert.informativeText = engine.explanation()
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// The panel is presented here rather than in the engine: the engine decides
    /// whether to interrupt, the app layer owns what that looks like. Swapping the
    /// panel for the mascot later touches only this file and NudgePanel.
    private func presentPanel(
        copy: String, prompt: String, eventID: Int64, ruleID: String
    ) {
        // Tier 2: one clack of the claw, and the bubble comes up over his head.
        doug.escalate(to: .clack)
        pendingPanel = (eventID, ruleID)

        nudgePanel.show(
            copy: copy, prompt: prompt, anchor: doug.frameOnScreen
        ) { [weak self] response in
            self?.pendingPanel = nil
            let outcome: SessionStore.Outcome
            switch response {
            case .accept:     outcome = .accepted
            case .alreadyDid: outcome = .alreadyDid
            case .mute:       outcome = .muted
            // An ignored panel is a soft no, not silence: docs/03 wants it feeding the
            // backoff, or a rule nobody engages with never learns that.
            case .dismiss, .ignored: outcome = .dismissed
            }
            if outcome == .accepted || outcome == .alreadyDid {
                // The mood loop from docs/04, and the only time he is ever delighted.
                self?.doug.celebrate()
            } else {
                self?.doug.reset()
            }
            self?.engine?.recordPanelOutcome(
                outcome, eventID: eventID, ruleID: ruleID
            )
            self?.refreshMenu()
        }
    }

    /// Tier 2 sat unanswered. He crosses the screen to the window it is about and takes
    /// the note with him, rather than a second nudge arriving on top of the first.
    private func lingerEscalate() {
        doug.escalate(to: .scuttle)
        // The scuttle takes about a second; the bubble follows once he has arrived, or
        // it would point at where he used to be.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, self.nudgePanel.isShowing else { return }
            self.nudgePanel.reanchor(to: self.doug.frameOnScreen)
        }
    }

    /// A click or a drag on Doug. If a bubble is up this *is* the answer to it, so it
    /// records an acceptance rather than leaving the nudge to time out as ignored —
    /// otherwise the fastest path to the handoff would also be the one that teaches the
    /// Personaliser the rule was unwanted.
    private func handoffFromDoug() {
        if let (eventID, ruleID) = pendingPanel {
            pendingPanel = nil
            nudgePanel.close()
            engine?.recordPanelOutcome(.accepted, eventID: eventID, ruleID: ruleID)
        } else {
            handoffNow()
        }
        doug.celebrate()
        refreshMenu()
    }

    /// Fires through the real presentation path, skipping every gate, and records
    /// nothing — a test must not pollute the history the Personaliser learns from.
    private func testNudge() {
        guard let engine else { return }
        guard engine.style == .panel else {
            engine.sendTestNudge()
            return
        }
        doug.escalate(to: .clack)
        nudgePanel.show(
            copy: "Test nudge — this is what one looks like",
            prompt: "Nothing was logged. Your real nudges use these same buttons.",
            anchor: doug.frameOnScreen
        ) { [weak self] _ in self?.doug.reset() }
    }

    private func destinationChoices()
        -> [(id: String, name: String, installed: Bool, active: Bool)]
    {
        guard let handoff = engine?.handoff else { return [] }
        let active = handoff.preferredDestination?.id
        return handoff.availableDestinations.map {
            (id: $0.id, name: $0.name, installed: $0.isNativeAvailable, active: $0.id == active)
        }
    }

    private func setDestination(_ id: String) {
        Handoff.preferredID = id
        Handoff.hasChosenDestination = true
        doug.destinationName = engine?.handoff.preferredDestination?.name
        refreshMenu()
    }

    /// Asked once, on the first run that has a choice to offer.
    ///
    /// The handoff used to go to whichever supported app happened to be installed first
    /// in the rulebook's order, which is fine only if everyone uses that one. Someone who
    /// works in ChatGPT would have had their window quietly pasted into Claude.
    private func askForDestinationIfNeeded() {
        guard let handoff = engine?.handoff, !Handoff.hasChosenDestination else { return }
        let choices = handoff.availableDestinations
        // Nothing to ask about if there is only one answer.
        guard choices.count > 1 else {
            Handoff.hasChosenDestination = true
            return
        }

        let alert = NSAlert()
        alert.messageText = "Where should AI-slap send your work?"
        alert.informativeText =
            "When you hand a window over, it opens here with your prompt already written. "
            + "Nothing is ever sent for you — you read it and press return yourself.\n\n"
            + "You can change this any time from the menu."
        alert.alertStyle = .informational

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        for choice in choices {
            popup.addItem(withTitle: choice.isNativeAvailable
                ? choice.name
                : "\(choice.name) — in the browser")
            popup.lastItem?.representedObject = choice.id
        }
        // Default the selection to whatever it would have used anyway.
        if let current = handoff.preferredDestination?.id,
           let index = choices.firstIndex(where: { $0.id == current }) {
            popup.selectItem(at: index)
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Use this")

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()

        if let id = popup.selectedItem?.representedObject as? String {
            setDestination(id)
        } else {
            Handoff.hasChosenDestination = true
        }
    }

    private func setStyle(_ style: InterruptionEngine.Style) {
        engine?.style = style
        refreshMenu()
    }

    private func toggleMascot() {
        MascotSettings.isEnabled.toggle()
        doug.setEnabled(MascotSettings.isEnabled)
        refreshMenu()
    }

    private func toggleCalmMode() {
        MascotSettings.calmMode.toggle()
        doug.calmMode = MascotSettings.calmMode
        refreshMenu()
    }

    private func setMaxTier(_ tier: DougWindow.Tier) {
        MascotSettings.maxTier = tier
        // Lowering the cap has to take effect on whatever he is doing right now, not on
        // the next nudge — someone reaching for this setting is reaching for it because
        // of what is on their screen at that moment.
        doug.reset()
        refreshMenu()
    }

    private func toggleLaunchAtLogin() {
        let turningOn = !LaunchAtLogin.state.isOn
        if let failure = LaunchAtLogin.set(turningOn) {
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login setting"
            alert.informativeText = failure
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        } else if turningOn, !LaunchAtLogin.isInStableLocation {
            // Worth saying once, at the moment it matters: the login item records a
            // path, and this one is inside a build directory.
            let alert = NSAlert()
            alert.messageText = "Set to open at login — but move the app first"
            alert.informativeText =
                "AI-slap is running from a build folder. If that folder is rebuilt or "
                + "cleaned, the login item will point at nothing and it will silently "
                + "stop starting.\n\nRun ./scripts/build-app.sh --install to put it in "
                + "/Applications, which is stable."
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        refreshMenu()
    }

    private func togglePanic() {
        guard let engine else { return }
        if engine.suppression.isPanicked {
            engine.suppression.cancelPanic()
            doug.unhide()
            refreshMenu()
        } else {
            panicHide()
        }
    }

    private func panicHide() {
        guard let engine else { return }
        nudgePanel.close()
        doug.hide()
        engine.suppression.panic()
        notify(
            title: "Hidden for 30 minutes",
            body: "Nothing will interrupt you. Turn it back on from the menu."
        )
        refreshMenu()
    }

    private func handoffNow() {
        engine?.handoffFrontmostWindow(title: currentContext?.title)
    }

    /// The clipboard is the universal fallback (docs/05), but only if the user knows
    /// it's there. Silence after a failed paste looks identical to a broken app.
    private func report(_ result: Handoff.Result) {
        switch result {
        case .pasted:
            break  // They can see it. Saying so as well would be noise.
        case .clipboardOnly(let reason):
            notify(
                title: "It's on your clipboard — press \u{2318}V",
                body: "Couldn't paste for you: \(reason)."
            )
        case .needsScreenRecording:
            // macOS needs a relaunch before the grant takes effect, so say that
            // plainly rather than letting the next attempt fail mysteriously.
            notify(
                title: "Allow Screen Recording to send the window",
                body: "Turn on AI-slap in Privacy & Security \u{203A} Screen Recording, "
                    + "then quit and reopen AI-slap. Handoff works without it, "
                    + "text only."
            )
        case .failed(let message):
            notify(title: "Handoff didn't work", body: message)
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "handoff.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
        )
    }

    private func export() {
        guard let store else { return }
        do {
            let url = try store.exportCSV()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            present(error)
        }
    }

    private func revealData() {
        guard let store else { return }
        NSWorkspace.shared.activateFileViewerSelecting([store.databaseURL])
    }

    private func deleteAll() {
        guard let store else { return }
        let alert = NSAlert()
        alert.messageText = "Delete all logged sessions?"
        alert.informativeText =
            "This permanently erases the local log at \(store.databaseURL.path), "
            + "including everything the app has learned about your habits. "
            + "It cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            closeCurrentSession(at: Date())
            try store.deleteAll()
            refreshMenu()
        } catch {
            present(error)
        }
    }

    /// The permission is granted outside the app, so it can come back at any moment —
    /// and after a rebuild it can vanish the same way. Re-check on every refresh.
    private func openAccessibilitySettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )!
        NSWorkspace.shared.open(url)
    }

    private func refreshMenu() {
        guard let store, let menuBar else { return }

        engine?.notificationStatus { [weak self] allowed in
            self?.notificationsAllowed = allowed
        }

        syncDoug()

        menuBar.update(
            context: isPaused ? nil : currentContext,
            category: currentContext.flatMap { engine?.category(for: $0) },
            statusLine: engine?.statusLine(
                for: isPaused ? nil : currentContext, since: currentStartedAt
            ) ?? "—",
            stats: store.statsSinceStartOfDay(),
            nudgesToday: store.firedToday(),
            dailyBudget: engine?.dailyBudget ?? 0,
            isPaused: isPaused,
            nudgesEnabled: engine?.isEnabled ?? false,
            sensitivity: engine?.sensitivity ?? .balanced,
            amnesty: engine?.amnesty ?? .standard,
            style: engine?.style ?? .panel,
            mascotEnabled: MascotSettings.isEnabled,
            calmMode: MascotSettings.calmMode,
            maxTier: MascotSettings.maxTier,
            isPanicked: engine?.suppression.isPanicked ?? false,
            launchAtLogin: LaunchAtLogin.state,
            budget: engine?.dailyBudget ?? 4,
            hasAccessibility: AXIsProcessTrusted(),
            notificationsAllowed: notificationsAllowed,
            hotkeyRegistered: hotkeyRegistered,
            hotkeyPresses: hotkeyPresses,
            lastHandoff: engine?.handoff.lastResult?.summary
        )
    }

    /// Keeps Doug in step with suppression and with how close the current context is to
    /// a nudge. Runs on the menu's own refresh rather than a timer of its own — a
    /// resident mascot earning a second polling loop is exactly the battery complaint
    /// docs/04 sets budgets to avoid.
    private func syncDoug() {
        guard MascotSettings.isEnabled else { return }

        // Hiding when it wasn't needed costs nothing; failing to hide once costs the
        // account. Every check here errs toward gone.
        let suppressed = engine?.suppression.check().suppressed ?? false
        if suppressed || isPaused || engine?.isEnabled == false {
            doug.hide()
            return
        }
        doug.unhide()

        guard !nudgePanel.isShowing else { return }

        // Tier 1 at the halfway mark: he stops and looks at the window before anything
        // fires. It is the cheapest interruption in the product and should be nearly all
        // of them — most contexts that earn a stare never earn a nudge.
        if let progress = engine?.dwellProgress(
            for: currentContext, since: currentStartedAt
        ), progress >= 0.5 {
            doug.escalate(to: .sideEye)
        }
    }

    // MARK: - Errors

    private func present(_ error: Error) {
        let alert = NSAlert(error: error)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func presentFatal(_ error: Error) {
        present(error)
        NSApp.terminate(nil)
    }
}
