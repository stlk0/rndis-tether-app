import AppKit
import SystemConfiguration

/// Activates even an accessory app; `activate(ignoringOtherApps:)` is deprecated from macOS 14.
func activateApp() {
    if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
}

/// Seconds since boot: the clock of polls and deadlines.
var uptime: Double { ProcessInfo.processInfo.systemUptime }

/// Seconds.
private enum PollInterval {
    static let fast = 1.0
    static let running = 3.0
    static let idle = 10.0  // no service: nothing changes until the user installs it
    static let upgradeCheck = 60.0
    static let upgradeCheckTolerance = 10.0  // lets macOS group the wakeups
}

/// Seconds.
private enum QuitTimeout {
    static let reply = 3.0  // logout must not hang, even behind a queued Connect or Disconnect
    static let statusRead = 1
    static let pauseRequest = 1  // with statusRead, must end inside `reply` when nothing is queued
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let launch: Launch
    let prefs = Prefs()
    let socketQueue = DispatchQueue(label: Paths.bundleID + ".socket")
    let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    /// The bundle and executable paths that survive `brew upgrade`.
    let stableAppPath = optPath(Bundle.main.bundlePath)
    let stableExecutablePath = optPath(Bundle.main.executablePath ?? CommandLine.arguments[0])
    let inAdminGroup = Privileged.currentUserIsInAdminGroup()

    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var rowItems: [NSMenuItem] = []
    let quitItem = NSMenuItem(
        title: "Quit RNDIS Tether", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let hotspotImage = AppDelegate.menuBarImage(symbolName: "personalhotspot")
    let hotspotSlashImage = AppDelegate.menuBarImage(symbolName: "personalhotspot.slash")  // macOS 15 and later
    var menuOpen = false
    var visibility = Visibility()
    var hidePending = false
    var settingsWindow: SettingsWindow?

    var service = Service.notInstalled
    var serviceKnown = false
    var serviceSilent = false
    var canUseAdminSocket = false
    var cli: CLI?
    var meter = SpeedMeter()
    var installPhase = InstallPhase.idle
    /// Set from the click until the service's answer: an older poll must not undo the box.
    var preferRequested: Bool?
    /// Numbers the clicks: only the reply to the latest one clears `preferRequested`.
    var preferClicks = 0
    /// This launch has checked prefs.pidPausedOnQuit: once, at the first supported status.
    var didHandlePIDPausedOnQuit = false

    var asleep = false
    var pollTimer: Timer?
    /// A silent service holds each read for SocketClient.statusTimeout: without this the 1 s
    /// timer would pile reads up in front of Connect, Disconnect and the quit.
    var pollPending = false
    var interfaceDisplayNames: [String: String] = [:]

    init(launch: Launch) {
        self.launch = launch
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let replacedCopy = replaceOtherCopies()
        listenToOtherCopies()
        updateLoginItem()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspaceCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = Paths.bundleID  // keeps its place across relaunches
        statusItem.isVisible = false
        buildStatusMenu()
        statusItem.menu = menu

        socketQueue.async {
            let cli = CLI.lookUp()
            let snapshot = Self.readService()
            DispatchQueue.main.async {
                self.cli = cli
                self.didReadService(snapshot)
                // Even after a silent read: a service that never answers still gets a window.
                let opensWindow = opensWindowOnLaunch(
                    setupDone: self.prefs.setupDone, byUser: self.launch.byUser, replacedCopy: replacedCopy)
                if opensWindow { self.showSettingsWindow() }
            }
        }
        _ = startRepeatingTimer(
            every: PollInterval.upgradeCheck, tolerance: PollInterval.upgradeCheckTolerance,
            calling: #selector(checkForUpgrades))

        buildKeyboardShortcuts()
    }

    /// A launch by the user turns Open at Login on once (the first launch), and moves an existing
    /// login item to this copy, say after the app was moved.
    func updateLoginItem() {
        guard launch.byUser else { return }
        let firstLaunch = !prefs.didTurnOnLoginByDefault && !prefs.setupDone
        let pointsAtOtherCopy = LoginItem.isOn && LoginItem.executable != stableExecutablePath
        guard firstLaunch || pointsAtOtherCopy else { return }
        guard (try? LoginItem.turnOn(executable: stableExecutablePath)) != nil else { return }
        if firstLaunch { prefs.didTurnOnLoginByDefault = true }
    }

    /// On the main run loop in common modes, so it also fires while a menu is tracking.
    private func startRepeatingTimer(every interval: Double, tolerance: Double, calling selector: Selector) -> Timer {
        let timer = Timer(timeInterval: interval, target: self, selector: selector, userInfo: nil, repeats: true)
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// Opening the running app again always shows the window: the icon can be behind the
    /// notch or hidden by macOS's menu bar settings, and the app cannot tell.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettingsWindow()
        return false
    }

    @objc func showSettingsWindow() {
        let window = settingsWindow ?? SettingsWindow(app: self)
        settingsWindow = window
        window.show(setup: !prefs.setupDone)
    }

    func markSetUp() { prefs.setupDone = true }

    /// Socket queue only.
    static func readService() -> ServiceSnapshot {
        let found: Service? =
            switch SocketClient.readStatus() {
            case .text(let text): .running(ServiceStatus(text: text))
            case .silent: nil
            case .noService: FileManager.default.fileExists(atPath: Paths.daemonPlist) ? .notRunning : .notInstalled
            }
        return ServiceSnapshot(service: found, canUseAdminSocket: SocketClient.canUseAdminSocket, readAt: uptime)
    }

    @objc func poll() {
        guard !pollPending else { return }
        pollPending = true
        socketQueue.async {
            let snapshot = Self.readService()
            DispatchQueue.main.async {
                self.pollPending = false
                self.didReadService(snapshot)
            }
        }
    }

    func didReadService(_ snapshot: ServiceSnapshot) {
        canUseAdminSocket = snapshot.canUseAdminSocket
        serviceSilent = snapshot.service == nil
        if let polled = snapshot.service {
            service = polled
            serviceKnown = true
            meter.add(polled.status, time: snapshot.readAt)
        }
        installPhase.observe(running: snapshot.service?.status != nil, readAt: snapshot.readAt)
        resumeIfPausedOnQuit()
        render()
        schedulePolling()
    }

    /// The pid stays until the service confirms, so a failed resume is tried again at the next
    /// launch.
    func resumeIfPausedOnQuit() {
        guard !didHandlePIDPausedOnQuit, let status = service.status, status.protocolSupported else { return }
        didHandlePIDPausedOnQuit = true
        let step = launchPauseStep(
            pidPausedOnQuit: prefs.pidPausedOnQuit, canUseAdminSocket: canUseAdminSocket, status: status)
        switch step {
        case .none: break
        case .forget: prefs.pidPausedOnQuit = nil
        case .resume: setPaused(false) { ok in if ok { self.prefs.pidPausedOnQuit = nil } }
        }
    }

    /// Fast while the user looks or a change is expected soon.
    private var pollInterval: Double {
        if case .starting = installPhase { return PollInterval.fast }
        if serviceSilent || menuOpen { return PollInterval.fast }
        return service.status != nil ? PollInterval.running : PollInterval.idle
    }

    func schedulePolling() {
        guard !asleep else {
            pollTimer?.invalidate()
            pollTimer = nil
            return
        }
        let interval = pollInterval
        if pollTimer?.timeInterval == interval { return }
        pollTimer?.invalidate()
        pollTimer = startRepeatingTimer(every: interval, tolerance: interval / 10, calling: #selector(poll))
    }

    @objc func willSleep() {
        asleep = true
        schedulePolling()
    }

    @objc func didWake() {
        asleep = false
        poll()
        checkForUpgrades()
    }

    /// Every minute and after wake: finds a new or removed rndis-tether CLI (the menu then offers
    /// to install or update the service), and relaunches into a newer copy of this app.
    @objc func checkForUpgrades() {
        socketQueue.async {
            let cli = CLI.lookUp()
            DispatchQueue.main.async {
                self.cli = cli
                self.render()
            }
        }
        relaunchIfUpgraded()
    }

    /// The main menu: hidden in an accessory app, but it routes ⌘W and ⌘Q in the settings window.
    func buildKeyboardShortcuts() {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(
            withTitle: "Quit RNDIS Tether", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let item = NSMenuItem()
        item.submenu = appMenu
        NSApp.mainMenu = NSMenu()
        NSApp.mainMenu?.addItem(item)
    }

    /// nil when the quit does not touch the connection.
    private var quitToolTip: String? {
        guard quitCanPause(canUseAdminSocket: canUseAdminSocket, status: service.status) else { return nil }
        return prefs.keepConnectionOnQuit ? "The connection keeps working" : "Also disconnects the phone"
    }

    func render() {
        let state = makeState()
        if let window = settingsWindow, window.isOpen {
            window.update(
                SettingsModel.make(state), alwaysShowIcon: prefs.alwaysShowIcon,
                keepConnectionOnQuit: prefs.keepConnectionOnQuit, openAtLogin: LoginItem.isOn)
        }
        quitItem.toolTip = quitToolTip
        renderStatusItem(MenuModel.make(state))
    }

    func makeState() -> AppState {
        AppState(
            service: service, serviceKnown: serviceKnown, installPhase: installPhase, cli: cli,
            canUseAdminSocket: canUseAdminSocket, inAdminGroup: inAdminGroup, alwaysShowIcon: prefs.alwaysShowIcon,
            preferRequested: preferRequested, speed: meter.speed, appVersion: appVersion,
            now: Date().timeIntervalSince1970, interfaceName: displayName(ofInterface:))
    }

    /// "Wi-Fi" for "en0"; the BSD name itself when macOS has no display name for it.
    func displayName(ofInterface bsdName: String) -> String {
        if let cached = interfaceDisplayNames[bsdName] { return cached }
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        let match = interfaces.first { SCNetworkInterfaceGetBSDName($0) as String? == bsdName }
        let name = match.flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? } ?? bsdName
        interfaceDisplayNames[bsdName] = name
        return name
    }

    func menuNeedsUpdate(_ menu: NSMenu) { renderMenu(MenuModel.make(makeState()).rows) }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        schedulePolling()
        poll()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        schedulePolling()
        render()
    }

    @objc func performRowAction(_ sender: NSMenuItem) {
        guard let action = MenuAction(rawValue: sender.tag) else { return }
        switch action {
        case .openSettings:
            showSettingsWindow()
        case .disconnect, .connect:
            prefs.pidPausedOnQuit = nil  // the user decides now: the quit's pause no longer counts
            setPaused(action == .disconnect)
        }
    }

    func setPaused(_ paused: Bool, done: @escaping (Bool) -> Void = { _ in }) {
        sendAdminSetting(
            .paused, to: paused, alertTitle: paused ? "Couldn't disconnect the phone" : "Couldn't connect the phone",
            done: done)
    }

    /// `done` gets whether the service answered ok. It runs before the status read that follows
    /// is rendered, so it can change that render.
    func sendAdminSetting(_ setting: AdminSetting, to on: Bool, alertTitle: String, done: @escaping (Bool) -> Void) {
        socketQueue.async {
            let error = SocketClient.set(setting, to: on)
            let snapshot = Self.readService()
            // The alert is modal: polls run meanwhile, and this snapshot must not undo them.
            DispatchQueue.main.async {
                done(error == nil)
                self.didReadService(snapshot)
                if let error { self.showAlert(alertTitle, details: error) }
            }
        }
    }

    /// Copies replaced by a later one, or exiting for an upgrade, call exit() and skip this.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Through the run loop: a quit inside a main-queue block never sees that queue again.
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        let keepConnection = prefs.keepConnectionOnQuit
        let lastStatus = service.status
        socketQueue.async {
            let pidPausedOnQuit = Self.pauseForQuit(keepConnection: keepConnection, lastStatus: lastStatus)
            RunLoop.main.perform(inModes: [.common]) {
                if let pidPausedOnQuit, !replied { self.prefs.pidPausedOnQuit = pidPausedOnQuit }
                reply()
            }
        }
        RunLoop.main.add(Timer(timeInterval: QuitTimeout.reply, repeats: false) { _ in reply() }, forMode: .common)
        return .terminateLater
    }

    /// Socket queue only, behind a queued Connect or Disconnect. Returns the pid of the service it
    /// paused, and only from a fresh read: the last poll can be 3 s old, and a `rndis-tether
    /// disconnect` since then is not the quit's own pause. After a timeout the request may still
    /// pause; no pid then, so the next launch shows Connect instead of guessing.
    static func pauseForQuit(keepConnection: Bool, lastStatus: ServiceStatus?) -> String? {
        guard !keepConnection else { return nil }
        var fresh: ServiceStatus?
        if case .text(let text) = SocketClient.readStatus(timeout: QuitTimeout.statusRead) {
            fresh = ServiceStatus(text: text)
        }
        let admin = SocketClient.canUseAdminSocket
        guard pausesOnQuit(keepConnection: false, canUseAdminSocket: admin, status: fresh ?? lastStatus),
            SocketClient.set(.paused, to: true, timeout: QuitTimeout.pauseRequest) == nil
        else { return nil }
        return fresh?.pid
    }

    func install(_ action: ServiceAction) {
        guard let cliPath = cli?.path, CLI.isInstallable(cliPath) else { return }
        let job = InstallJob(action: action, replacesRunning: service.status != nil)
        installPhase = .password(job)
        render()
        // After the next display pass, so the window's "Enter … in the macOS dialog" is drawn first:
        // the password dialog and the install block the main thread.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            activateApp()
            let result = Privileged.install(cliPath: cliPath, replacesRunning: job.replacesRunning)
            if let window = self.settingsWindow, window.isVisible { window.bringForward() }
            switch result {
            case .ok:
                self.installPhase = .starting(job, since: uptime)
            case .cancelled:
                self.installPhase = .idle
            case .failed(let text):
                self.installPhase = .idle
                self.render()  // before the alert: it points at the Terminal link, which shows only when idle
                self.showAlert(
                    "Couldn't \(action.verb) the service",
                    details: SettingsModel.installFailureText(text, action: action, inAdminGroup: self.inAdminGroup))
            }
            self.render()
            self.poll()
        }
    }

    func setPreferPhone(_ on: Bool) {
        preferClicks += 1
        let click = preferClicks
        preferRequested = on
        render()
        let alertTitle = "Couldn't change “\(SettingsWindow.preferPhoneTitle)”"
        sendAdminSetting(.preferPhone, to: on, alertTitle: alertTitle) { _ in
            if self.preferClicks == click { self.preferRequested = nil }
        }
    }

    func setKeepConnectionOnQuit(_ keep: Bool) {
        prefs.keepConnectionOnQuit = keep
        render()
    }

    func setAlwaysShowIcon(_ always: Bool) {
        prefs.alwaysShowIcon = always
        render()
    }

    func toggleLogin() {
        do {
            if LoginItem.isOn {
                try LoginItem.turnOff()
            } else {
                try LoginItem.turnOn(executable: stableExecutablePath)
            }
        } catch {
            showAlert("Couldn't change “\(SettingsWindow.openAtLoginTitle)”", details: error.localizedDescription)
        }
        render()
    }

    func showAlert(_ title: String, details: String) {
        activateApp()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = details
        alert.runModal()
    }
}
