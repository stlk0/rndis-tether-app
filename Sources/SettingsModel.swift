import Foundation

/// What the setup and settings window says and what its buttons do; the window only lays it out.
struct SettingsModel {
    /// What the main button does.
    enum Primary: Equatable {
        case run(ServiceAction)
        case copy
    }

    /// The setup starts with, and stays on, the service step.
    var needsService = false
    var heading = ""
    var paragraphs: [String] = []
    var commandNote: String?
    var primary: Primary?
    var linkTitle: String?
    var copyText = ""
    /// Instructions shown after copying `copyText`.
    var afterCopyHint = ""
    /// While installing, or after an install that did not start.
    var installMessage: String?
    /// Step 2 after Not Now while something is still to do; nil when nothing is.
    var notReady: (heading: String, text: String)?
    /// After "Background service:" on the settings page.
    var serviceState = ""
    var serviceDetail: String?
    var preferShown = false
    var quitSettingShown = false
    var preferOn = false
    var preferEnabled = false
    var preferHint = ""
    var footer = ""

    var serviceLine: String { "Background service: " + serviceState }
    /// Shown on the page when Copy Command is the main button.
    var command: String? { primary == .copy ? copyText : nil }

    var primaryTitle: String? {
        switch primary {
        case .run(.install)?: return "Install…"
        case .run(.reinstall)?: return "Reinstall…"
        case .run(.update)?: return "Update…"
        case .copy?: return "Copy Command"
        case nil: return nil
        }
    }

    static let readyHeading = "RNDIS Tether is ready"
    static let readyText =
        "Connect your phone with a USB cable and turn on USB tethering in its settings. The icon appears in the menu bar."
    private static let almostReady = "Almost ready"

    /// The install alert names it too.
    static func terminalLinkTitle(_ action: ServiceAction) -> String {
        "Prefer Terminal? Copy the \(action.verb) command"
    }

    /// sudo fails for users outside the admin group: only members get the Terminal hint.
    static func installFailureText(_ error: String, action: ServiceAction, inAdminGroup: Bool) -> String {
        guard inAdminGroup else { return error }
        return error + "\n\nYou can also \(action.verb) it from Terminal: in the RNDIS Tether window, click "
            + "“\(terminalLinkTitle(action))”."
    }

    static func make(_ state: AppState) -> SettingsModel {
        var m = SettingsModel()
        m.footer = footer(state)
        guard state.serviceKnown else {
            m.needsService = true
            m.heading = "Checking the background service…"
            m.paragraphs = ["This takes a few seconds."]
            m.serviceState = "Checking…"
            return m
        }
        if let s = state.service.status {
            guard s.protocolSupported else {
                m.needsService = true  // the setup stays here: nothing works until the app is updated
                m.explainAppTooOld(update: state.cli?.bundled == true ? appInstallCommand : upgradeAppCommand)
                return m
            }
            m.preferShown = true
            m.quitSettingShown = quitCanPause(canUseAdminSocket: state.canUseAdminSocket, status: s)
            m.preferOn = state.preferRequested ?? s.prefersPhone
            m.preferEnabled = state.canUseAdminSocket
            m.preferHint =
                state.canUseAdminSocket
                ? "Internet goes through the phone even when Wi-Fi is connected."
                : "Only an administrator of this Mac can change this."
        }
        guard let action = serviceAction(state) else {
            m.serviceState = "Running"
            return m
        }
        m.needsService = true
        m.serviceState = state.installPhase.isBusy ? "Installing…" : pendingServiceState(action, state)
        guard let cli = state.cli else {
            m.explainMissingCLI()
            return m
        }
        m.explain(action, state)
        let command = installCommand(cli.path)
        guard cli.installable else {
            // The dialog cannot run this path: Terminal is the only way.
            let terminalOnly = "Install it from Terminal: copy the command, paste it in Terminal and press Return."
            m.paragraphs = [terminalOnly]
            m.serviceDetail = terminalOnly
            m.offerCopy(command)
            return m
        }
        m.copyText = command
        switch state.installPhase {
        case .password:
            // Stays on screen through the install too: it blocks the main thread.
            m.installMessage =
                "Enter \(passwordName(state)) in the macOS dialog, then wait a few seconds while the service starts. "
                + "If you don't see the dialog, look behind other windows."
        case .starting: m.installMessage = "Starting the service…"
        case .didNotStart:
            m.installMessage = "The service was installed but didn't start. Click Reinstall, or restart the Mac."
        case .idle: break
        }
        guard !state.installPhase.isBusy else { return m }
        m.primary = .run(action)
        if state.inAdminGroup {
            m.linkTitle = terminalLinkTitle(action)
            m.afterCopyHint =
                "Copied. Open Terminal, paste with ⌘V and press Return, then type your Mac password "
                + "(it stays invisible while you type). This window updates by itself."
        }
        return m
    }

    /// "Version 1.0.0 · Service 1.0.1 · Command 1.0.2"
    private static func footer(_ state: AppState) -> String {
        let app = "Version \(state.appVersion)"
        guard state.serviceKnown else { return app }
        let serviceVersion = state.service.status?.version
        let service: String
        switch state.service {
        case .running: service = serviceVersion.map { "Service \($0)" } ?? "Service"
        case .notRunning: service = "Service not running"
        case .notInstalled: service = "Service not installed"
        }
        var parts = [app, service]
        if let cli = state.cli?.version, cli != serviceVersion { parts.append("Command \(cli)") }
        return parts.joined(separator: " · ")
    }

    /// While something is left to do for the service.
    private static func pendingServiceState(_ action: ServiceAction, _ state: AppState) -> String {
        switch action {
        case .install: return "Not installed"
        case .reinstall: return "Installed but not running"
        case .update: return "Update available" + versionChange(state)
        }
    }

    /// " (1.0.1 → 1.0.10)", or empty when either version is unknown.
    private static func versionChange(_ state: AppState) -> String {
        guard let service = state.service.status?.version, let cli = state.cli?.version else { return "" }
        return " (\(service) → \(cli))"
    }

    /// While an install runs, the action it started with, so the texts do not change halfway.
    private static func serviceAction(_ state: AppState) -> ServiceAction? {
        state.installPhase.job?.action ?? state.neededAction
    }

    private static func passwordName(_ state: AppState) -> String {
        state.inAdminGroup ? "your Mac password" : "the name and password of an administrator of this Mac"
    }

    private mutating func explain(_ action: ServiceAction, _ state: AppState) {
        let password = Self.passwordName(state)
        let rights =
            "The service needs full system rights to create a network connection. It only carries traffic "
            + "between your phone and this Mac, sends nothing anywhere, and its code is open."
        switch action {
        case .install:
            heading = "Install the background service"
            paragraphs = [
                "RNDIS Tether uses a small background service to connect to your phone over USB. "
                    + "Installing it is like installing a network driver: macOS asks for \(password).",
                rights,
            ]
            serviceDetail = "Without it, your phone can't share its internet with this Mac."
            notReady = (
                Self.almostReady,
                "The service isn't installed yet, so your phone can't connect. The icon stays in the menu "
                    + "bar until you install it: click it and choose \(action.menuTitle)"
            )
        case .reinstall:
            heading = "Repair the background service"
            paragraphs = [
                "The service is installed but not running. Installing it again usually fixes this. "
                    + "macOS asks for \(password).",
                rights,
            ]
            notReady = (
                Self.almostReady,
                "The service isn't running, so your phone can't connect. The icon stays in the menu bar "
                    + "until it runs: click it and choose \(action.menuTitle)"
            )
        case .update:
            let versions = Self.versionChange(state)
            heading = "Update the background service"
            paragraphs = [
                "This version of RNDIS Tether comes with a newer service\(versions). Updating asks for "
                    + "\(password). \(connectionDropWarning)."
            ]
            serviceDetail = connectionDropWarning + "."
            notReady = (
                Self.readyHeading,
                "Your phone can connect with the current service. To update it later, click the menu bar "
                    + "icon and choose \(action.menuTitle)"
            )
        }
    }

    private mutating func explainAppTooOld(update command: String) {
        heading = "This app is older than the service"
        paragraphs = [
            "RNDIS Tether can't read the service's status until it is updated. To update it, run this in Terminal:"
        ]
        notReady = (
            Self.almostReady,
            "This app is older than the service, so it can't show your phone. "
                + "To update it, run in Terminal: \(command)"
        )
        serviceState = "Running, but this app is too old for it"
        serviceDetail = "To update the app, run in Terminal:"
        offerCopy(command)
    }

    private mutating func explainMissingCLI() {
        heading = "One more part is needed"
        notReady = (
            Self.almostReady,
            "Part of RNDIS Tether is missing, so your phone can't connect. The icon stays in the menu "
                + "bar until it is fixed: click it and choose \(howToFixTitle)"
        )
        paragraphs = [
            "The rndis-tether package, which installs the service, is missing. To add it, run this in Terminal:"
        ]
        serviceDetail = "The rndis-tether package is missing. To add it, run in Terminal:"
        commandNote = "This window checks again every minute."
        offerCopy("brew install stlk0/tap/rndis-tether")
    }

    private mutating func offerCopy(_ command: String) {
        primary = .copy
        copyText = command
        afterCopyHint = "Copied. Paste it in Terminal and press Return."
    }
}
