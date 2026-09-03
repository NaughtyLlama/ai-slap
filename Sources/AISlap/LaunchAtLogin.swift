import Foundation
import ServiceManagement

/// Starts AI-slap when the user logs in.
///
/// A watcher that stops watching after a reboot is worse than no watcher: the data
/// quietly stops, the menu-bar icon is absent rather than warning, and the person
/// assumes it is running. This app went dark for a full day that way.
///
/// `SMAppService.mainApp` is the modern route — it registers the bundle itself, appears
/// in System Settings › General › Login Items under the user's control, and needs no
/// helper target or launchd plist of our own.
enum LaunchAtLogin {

    enum State {
        case enabled
        case disabled
        /// The user switched it off in System Settings. Respect that — re-registering
        /// behind their back is exactly the behaviour that gets an app distrusted.
        case deniedBySystemSettings
        case unavailable(String)

        var isOn: Bool {
            if case .enabled = self { return true }
            return false
        }
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled:          return .enabled
        case .notRegistered:    return .disabled
        case .requiresApproval: return .deniedBySystemSettings
        case .notFound:         return .unavailable("the app bundle moved")
        @unknown default:       return .unavailable("unknown status")
        }
    }

    /// Returns nil on success, or a human-readable reason it didn't work.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            NSLog("AISlap: launch-at-login \(enabled ? "register" : "unregister") failed — \(error)")
            return error.localizedDescription
        }
    }

    /// Login items are recorded by path. An app launched from a build directory can be
    /// deleted by the next clean build, and the login item then points at nothing —
    /// silently, which is the failure mode this whole file exists to prevent.
    static var isInStableLocation: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }
}
