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
    private let historyWindow = HistoryWindow()
    private var maintenanceTimer: Timer?
    private var hotkeyRegistered = false
    private var hotkeyPresses = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let store = try SessionStore(retentionDays: UserDefaults.standard.integer(forKey: "historyRetentionDays"))
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
            onTogglePanic: { [weak self] in self?.togglePanic() },
            onToggleLaunchAtLogin: { [weak self] in self?.toggleLaunchAtLogin() },
            onToggleRule: { [weak self] id, muted in
                self?.engine?.setUserMuted(id, muted: muted)
                self?.refreshMenu()
            },
            ruleStates: { [weak self] in self?.engine?.ruleStates() ?? [] },
            onHandoffNow: { [weak self] in self?.handoffNow() },
            onFixPermission: { [weak self] in self?.openAccessibilitySettings() },
            onShowHistory: { [weak self] in self?.showHistory() },
            onSetRetention: { [weak self] in self?.setRetention($0) },
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

        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            do { try self?.store?.pruneHistory() }
            catch { NSLog("AISlap: history maintenance failed — \(error.localizedDescription)") }
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

        UNUserNotificationCenter.current().delegate = self
        InterruptionEngine.registerNotificationCategory()
        if engine?.style == .notification { requestNotificationPermission() }

        // An unanswered nudge is a soft no. Left as "fired" it inflates the acceptance
        // denominator and never reaches the backoff.
        engine?.resolveStaleEvents()

        requestAccessibilityIfNeeded()
        observer.start()
        refreshMenu()
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
            nudgePanel.close()
            engine?.handoff.cancel()
            isPaused = true
            observer.stop()
        }
        refreshMenu()
    }

    private func toggleNudges() {
        guard let engine else { return }
        engine.isEnabled.toggle()
        if !engine.isEnabled { nudgePanel.close() }
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
        nudgePanel.show(copy: copy, prompt: prompt) { [weak self] response in
            let outcome: SessionStore.Outcome
            switch response {
            case .accept:     outcome = .accepted
            case .alreadyDid: outcome = .alreadyDid
            case .mute:       outcome = .muted
            // An ignored panel is a soft no, not silence: docs/03 wants it feeding the
            // backoff, or a rule nobody engages with never learns that.
            case .dismiss, .ignored: outcome = .dismissed
            }
            self?.engine?.recordPanelOutcome(
                outcome, eventID: eventID, ruleID: ruleID
            )
            self?.refreshMenu()
        }
    }

    /// Fires through the real presentation path, skipping every gate, and records
    /// nothing — a test must not pollute the history the Personaliser learns from.
    private func testNudge() {
        guard let engine else { return }
        guard engine.style == .panel else {
            engine.sendTestNudge()
            return
        }
        nudgePanel.show(
            copy: "Test nudge — this is what one looks like",
            prompt: "Nothing was logged. Your real nudges use these same buttons."
        ) { _ in }
    }

    private func setStyle(_ style: InterruptionEngine.Style) {
        engine?.style = style
        if style == .notification { requestNotificationPermission() }
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
            refreshMenu()
        } else {
            panicHide()
        }
    }

    private func panicHide() {
        guard let engine else { return }
        nudgePanel.close()
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
        case .pasteRequested, .clipboardOnly, .cancelled:
            break // Recovery controls are visible without notification permission.
        case .needsScreenRecording:
            let alert = NSAlert()
            alert.messageText = "Try the handoff again after allowing screenshots"
            alert.informativeText = "Enable AI-slap in Privacy & Security → Screen Recording. If macOS asks you to quit and reopen, do that first. Text-only handoffs remain available."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        case .failed(let message):
            let alert = NSAlert()
            alert.messageText = "Handoff couldn't continue"
            alert.informativeText = message
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        refreshMenu()
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

    private func showHistory() {
        guard let store else { return }
        historyWindow.show(text: store.historySummary())
    }

    private func setRetention(_ days: Int) {
        guard let store, [0, 30, 90, 365].contains(days) else { return }
        if days > 0 && (store.retentionDays == 0 || days < store.retentionDays) {
            let alert = NSAlert()
            alert.messageText = "Keep only the last \(days) days?"
            alert.informativeText = "Older usage history and interruption outcomes will be permanently removed, along with app-managed exports containing expired history."
            alert.addButton(withTitle: "Change retention")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        store.retentionDays = days
        UserDefaults.standard.set(days, forKey: "historyRetentionDays")
        do { try store.pruneHistory(); showHistory() }
        catch { present(error) }
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
        alert.messageText = "Delete all history and learning?"
        alert.informativeText =
            "This erases usage history, interruption outcomes, learned adjustments, muted rules, "
            + "and CSV exports in AI-slap's data folder. Copied exports elsewhere are not affected. "
            + "Your app settings and macOS permissions are kept. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            closeCurrentSession(at: Date())
            observer.stop()
            nudgePanel.close()
            historyWindow.close()
            engine?.resetHistory()
            defer { if !isPaused { observer.start() }; refreshMenu() }
            try store.deleteAll()
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

        engine?.expireTargets()
        engine?.notificationStatus { [weak self] allowed in
            self?.notificationsAllowed = allowed
        }

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
