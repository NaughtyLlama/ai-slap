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
    private let hotkey = GlobalHotkey()
    private var hotkeyRegistered = false
    private var hotkeyPresses = 0

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
            onShowLearned: { [weak self] in self?.showLearned() },
            onTestNudge: { [weak self] in self?.engine?.sendTestNudge() },
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
        hotkeyRegistered = hotkey.register(onPress: { [weak self] in
            self?.hotkeyPresses += 1
            self?.handoffNow()
            self?.refreshMenu()
        })
        if !hotkeyRegistered {
            NSLog("AISlap: could not register Option-Space — something else owns it.")
        }

        UNUserNotificationCenter.current().delegate = self
        InterruptionEngine.registerNotificationCategory()
        requestNotificationPermission()

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
