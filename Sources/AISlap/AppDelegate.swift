import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var store: SessionStore?
    private let observer = WindowContextObserver()
    private var menuBar: MenuBarController?

    private var currentContext: WindowContext?
    private var currentStartedAt: Date?
    private var isPaused = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            store = try SessionStore()
        } catch {
            presentFatal(error)
            return
        }

        menuBar = MenuBarController(
            onTogglePause: { [weak self] in self?.togglePause() },
            onExport: { [weak self] in self?.export() },
            onRevealData: { [weak self] in self?.revealData() },
            onDeleteAll: { [weak self] in self?.deleteAll() }
        )

        observer.onChange = { [weak self] context in
            self?.contextChanged(to: context)
        }

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
        refreshMenu()
    }

    private func closeCurrentSession(at end: Date) {
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
            try store.record(session)
        } catch {
            NSLog("AISlap: failed to record session — \(error.localizedDescription)")
        }
        currentContext = nil
        currentStartedAt = nil
    }

    // MARK: - Permission

    /// One prompt, at launch, per the permission budget in docs/02. Screen Recording
    /// is never requested here — Phase 0 does not capture anything.
    private func requestAccessibilityIfNeeded() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options = [key: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        if !trusted {
            NSLog("AISlap: Accessibility not granted — running on bundle IDs only.")
            // The system prompt is modal-free and easy to miss, so re-check shortly
            // after and pick up the permission without needing a relaunch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.observer.refresh()
                self?.refreshMenu()
            }
        }
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
            "This permanently erases the local log at \(store.databaseURL.path). "
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
            stats: store.statsSinceStartOfDay(),
            isPaused: isPaused,
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
