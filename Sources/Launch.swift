import Foundation

struct Launch {
    /// Passed by the LaunchAgent. Stored in installed LaunchAgent plists: changing it makes
    /// older installs start at login as if the user opened them.
    static let loginArgument = "--login"
    /// Passed by an older copy that relaunches the app after an upgrade.
    static let relaunchArgument = "--relaunch"

    let atLogin: Bool
    let relaunched: Bool

    init(_ arguments: [String]) {
        let flags = arguments.dropFirst()
        atLogin = flags.contains(Self.loginArgument)
        relaunched = flags.contains(Self.relaunchArgument)
    }

    var byUser: Bool { !atLogin && !relaunched }
}

/// A launch that replaces a running copy counts as opening the app again: it shows the settings.
func opensWindowOnLaunch(setupDone: Bool, byUser: Bool, replacedCopy: Bool) -> Bool {
    byUser && (!setupDone || replacedCopy)
}

/// Also decides whether the quit setting is shown.
func quitCanPause(canUseAdminSocket: Bool, status: ServiceStatus?) -> Bool {
    guard canUseAdminSocket, let status, status.protocolSupported else { return false }
    return status.supportsPause
}

func pausesOnQuit(keepConnection: Bool, canUseAdminSocket: Bool, status: ServiceStatus?) -> Bool {
    !keepConnection && quitCanPause(canUseAdminSocket: canUseAdminSocket, status: status) && status?.paused == false
}

enum LaunchPauseStep: Equatable {
    case none
    case resume  // send `set paused no`, then forget the pid
    case forget
}

/// A launch undoes only the pause its own quit made: `pidPausedOnQuit` is the pid of the service
/// it paused, so a pause from Disconnect, or in a service started since, stays. Without the admin
/// socket the pid is dropped rather than retried at every launch.
func launchPauseStep(pidPausedOnQuit: String?, canUseAdminSocket: Bool, status: ServiceStatus?) -> LaunchPauseStep {
    guard let pidPausedOnQuit, let status, status.protocolSupported else { return .none }
    return status.paused && canUseAdminSocket && status.pid == pidPausedOnQuit ? .resume : .forget
}
