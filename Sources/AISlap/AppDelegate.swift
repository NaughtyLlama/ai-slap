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
            onExport: { [weak self] in self?.export() },
            onRevealData: { [weak self] in self?.revealData() },
            onDeleteAll: { [weak self] in self?.deleteAll() }
        )

        observer.onChange = { [weak self] context in
            self?.contextChanged(to: context)
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

    private func refreshMenu() {
        guard let store, let menuBar else { return }
        menuBar.update(
            context: isPaused ? nil : currentContext,
            category: currentContext.flatMap { engine?.category(for: $0) },
            stats: store.statsSinceStartOfDay(),
            nudgesToday: store.firedToday(),
            dailyBudget: engine?.dailyBudget ?? 0,
            isPaused: isPaused,
            nudgesEnabled: engine?.isEnabled ?? false,
            sensitivity: engine?.sensitivity ?? .balanced,
            hasAccessibility: AXIsProcessTrusted()
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
