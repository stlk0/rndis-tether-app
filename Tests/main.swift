import Foundation

// Assertion runner for the Foundation-only sources: `make test`. No phone or service needed.

// Line-buffered, so the FAIL lines before a crash still reach the CI log.
setvbuf(stdout, nil, _IOLBF, 0)

var failures = 0

func check(_ condition: Bool, _ message: @autoclosure () -> String = "", line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL Tests/main.swift:\(line) \(message())")
    }
}

func equal<T: Equatable>(_ a: T, _ b: T, _ context: String = "", line: Int = #line) {
    check(a == b, (context.isEmpty ? "" : context + ": ") + "\(a) != \(b)", line: line)
}

func status(_ text: String) -> ServiceStatus { ServiceStatus(text: text) }

let head = "protocol=1\nversion=1.0.1\npid=286\nprefer-phone=yes\n"
let phone = "phone=SAMSUNG_Android 04e8:6864\n"
/// A first install, and an update over a running service.
let installJob = InstallJob(action: .install, replacesRunning: false)
let updateJob = InstallJob(action: .update, replacesRunning: true)
let session =
    "interface=feth50\nconnected-since=1000\naddress=10.0.0.2\ngateway=10.0.0.1\nprimary=feth50\n"
    + "rx-bytes=1000\ntx-bytes=500\nrx-dropped=0\ntx-dropped=0\nusb-errors=0\nresets=0\n"
let samples: [String: String] = [
    "no-phone": head + "state=no-phone\n",
    "connecting": head + "state=connecting\n" + phone,
    "retrying": head + "state=retrying\n" + phone + "problem=data interface not found\n",
    "unsupported": head + "state=unsupported\n" + phone,
    "sleeping": head + "state=sleeping\n" + phone,
    "online": head + "state=online\n" + phone + session,
]

func titles(_ m: MenuModel) -> [String] { m.rows.map(\.title) }

// MARK: Parser

do {
    let s = status("protocol=1\nproblem=a = b, c d\nfuture-field=x\nnot a pair\n=empty name\nstate=online")
    equal(s["problem"], "a = b, c d")
    equal(s["future-field"], "x")
    equal(s.state, .online)
    equal(s["phone"], nil)
    equal(status("").state, nil)
    equal(status("rx-bytes=12\n").number("rx-bytes"), 12)
    equal(status("rx-bytes=x\n").number("rx-bytes"), nil)
    check(status(samples["sleeping"]!).phoneAttached)
    check(!status(samples["no-phone"]!).phoneAttached)
}

// MARK: SpeedMeter

do {
    var m = SpeedMeter()
    let a = status("pid=1\nconnected-since=5\nrx-bytes=1000\ntx-bytes=100\n")
    m.add(a, time: 10)
    equal(m.speed, nil)  // one sample is not a speed
    m.add(status("pid=1\nconnected-since=5\nrx-bytes=2000\ntx-bytes=300\n"), time: 12)
    equal(m.speed, Speed(down: 4000, up: 800))
    m.add(status("pid=1\nconnected-since=5\nrx-bytes=2010\ntx-bytes=300\n"), time: 12.01)
    equal(m.speed, Speed(down: 4000, up: 800))  // a quick second poll: the speed and its base stay
    m.add(status("pid=1\nconnected-since=5\nrx-bytes=3000\ntx-bytes=300\n"), time: 14)
    equal(m.speed, Speed(down: 4000, up: 0))
    m.add(status("pid=1\nconnected-since=5\nrx-bytes=10\ntx-bytes=300\n"), time: 15)
    equal(m.speed, nil)  // counter went down
    m.add(status("pid=1\nconnected-since=5\nrx-bytes=110\ntx-bytes=300\n"), time: 16)
    equal(m.speed, Speed(down: 800, up: 0))
    m.add(status("pid=1\nconnected-since=6\nrx-bytes=500\ntx-bytes=400\n"), time: 17)
    equal(m.speed, nil)  // new session
    m.add(status("pid=2\nconnected-since=6\nrx-bytes=600\ntx-bytes=400\n"), time: 18)
    equal(m.speed, nil)  // new service
    m.add(status("pid=2\nconnected-since=6\nrx-bytes=700\ntx-bytes=400\n"), time: 19)
    equal(m.speed, Speed(down: 800, up: 0))
    m.add(status("pid=2\nstate=no-phone\n"), time: 20)
    equal(m.speed, nil)  // session fields gone
    m.add(nil, time: 21)
    equal(m.speed, nil)

    equal(speedText(999_999), "1000 kbit/s")
    equal(speedText(1e6), "1.0 Mbit/s")
    equal(speedText(12_400_000), "12.4 Mbit/s")
    equal(speedText(0), "0 kbit/s")
    equal(durationText(-5), "0 s")
    equal(durationText(59), "59 s")
    equal(durationText(60), "1 min")
    equal(durationText(4320), "1 h 12 min")
}

// MARK: Visibility debounce

do {
    var v = Visibility()
    equal(v.update(want: false, now: 0), nil)
    check(!v.visible)
    _ = v.update(want: true, now: 1)
    check(v.visible)
    equal(v.update(want: false, now: 2), 3)
    check(v.visible)
    equal(v.update(want: false, now: 4), 1)
    check(v.visible)
    _ = v.update(want: true, now: 4.5)  // replug within 3 s: no flicker, timer starts over
    equal(v.update(want: false, now: 5), 3)
    equal(v.update(want: false, now: 8), nil)
    check(!v.visible)
}

// MARK: Menu model

/// An administrator, a CLI of the service's version, the app at 1.0.0.
func appState(_ service: Service, _ edit: (inout AppState) -> Void = { _ in }) -> AppState {
    var state = AppState(
        service: service, serviceKnown: true, installPhase: .idle,
        cli: CLI(path: "/usr/local/bin/rndis-tether", version: "1.0.1", installable: true),
        canUseAdminSocket: true, inAdminGroup: true, alwaysShowIcon: false, preferRequested: nil, speed: nil,
        appVersion: "1.0.0", now: 1000 + 4320,  // connected-since in `session`, plus 1 h 12 min
        interfaceName: { $0 })
    edit(&state)
    return state
}

func model(_ service: Service, _ edit: (inout AppState) -> Void = { _ in }) -> MenuModel {
    MenuModel.make(appState(service, edit))
}

func running(_ name: String, _ extra: String = "") -> Service { .running(status(samples[name]! + extra)) }

do {
    // Rows per state.
    let online = model(running("online")) { $0.speed = Speed(down: 12_400_000, up: 1_100_000) }
    equal(titles(online), ["SAMSUNG_Android", "Online for 1 h 12 min", "↓\t12.4 Mbit/s\t↑\t1.1 Mbit/s"])
    equal(online.rows[0].tooltip, "SAMSUNG_Android 04e8:6864")
    equal(online.glyph, .online)
    equal(online.summary, "Online for 1 h 12 min")  // the status line, not the phone
    equal(model(running("online")).rows[2].title, "↓\t—\t↑\t—")
    // Info rows: the phone's name, status lines and hints, like macOS's Wi-Fi menu.
    equal(online.rows.map(\.style), [.title, .primary, .speed])

    let routed = model(running("online", "primary=en0\nrx-dropped=2\ntx-dropped=1\nusb-errors=4\nresets=1\n")) {
        $0.interfaceName = { $0 == "en0" ? "Wi-Fi" : $0 }
    }
    equal(
        Array(titles(routed).suffix(2)), ["Internet goes through Wi-Fi", "Problems: dropped 3, USB errors 4, resets 1"])
    equal(routed.rows.suffix(2).map(\.style), [.secondary, .secondary])
    equal(titles(model(running("online", "primary=\n"))).last, "macOS has no internet route right now")

    equal(titles(model(running("connecting"))), ["SAMSUNG_Android", "Connecting…"])
    equal(model(running("retrying")).rows.map(\.style), [.title, .primary, .secondary])
    equal(model(running("no-phone")).rows.map(\.style), [.title, .secondary])
    equal(model(.notInstalled) { $0.cli = nil }.rows.map(\.style), [.title, .primary])
    equal(model(running("sleeping")).rows.map(\.style), [.title])
    equal(model(running("connecting")).glyph, .dimmed)
    equal(
        titles(model(running("retrying"))),
        ["SAMSUNG_Android", "Can't connect: data interface not found", "The phone is still turning on tethering…"])
    equal(
        titles(model(running("unsupported"))),
        ["SAMSUNG_Android", "Not working as USB tethering", "Unplug it, turn on USB tethering, plug it in again"])
    equal(titles(model(running("sleeping"))), ["Paused while the Mac sleeps"])
    equal(model(running("sleeping")).glyph, .dimmed)

    let noPhone = model(running("no-phone"))
    equal(titles(noPhone), ["No phone connected", "Plug in the phone and turn on USB tethering"])
    equal(noPhone.glyph, .offline)
    check(!noPhone.visible)

    // Service conditions: a headline and a row that opens the settings window.
    let notInstalled = model(.notInstalled)
    equal(titles(notInstalled), ["Service not installed", "Install Service…"])
    equal(notInstalled.rows.compactMap(\.action), [.openSettings])
    equal(notInstalled.glyph, .offline)
    check(notInstalled.visible)
    equal(titles(model(.notRunning)), ["Service not running", "Reinstall Service…"])
    let noCLI = model(.notInstalled) { $0.cli = nil }
    equal(titles(noCLI), ["Part of RNDIS Tether is missing", "Show How to Fix…"])
    equal(noCLI.rows.compactMap(\.action), [.openSettings])

    let installing = model(.notRunning) { $0.installPhase = .starting(installJob, since: 0) }
    equal(titles(installing), ["Installing the service…"])
    equal(
        titles(
            model(.notRunning) { $0.installPhase = .password(InstallJob(action: .reinstall, replacesRunning: true)) }),
        ["Installing the service…", "Internet through the phone stops for up to half a minute"])
    check(installing.visible)
    equal(titles(model(.notRunning) { $0.installPhase = .didNotStart }), ["Service not running", "Reinstall Service…"])
    // An install that didn't start: the menu says Reinstall, like the window.
    equal(
        titles(model(.notInstalled) { $0.installPhase = .didNotStart }), ["Service not running", "Reinstall Service…"])
    equal(
        titles(model(running("online")) { $0.installPhase = .password(updateJob) }),
        ["Installing the service…", "Internet through the phone stops for up to half a minute"])

    let older = model(running("no-phone")) { $0.cli?.version = "1.0.10" }
    equal(Array(titles(older).suffix(2)), ["Update Service…", "Version 1.0.10 is ready"])
    equal(older.rows.compactMap(\.action), [.openSettings])
    check(older.visible)
    equal(model(running("online")) { $0.cli?.version = "1.0.10" }.glyph, .online)  // the state's glyph

    let newer = model(running("no-phone")) { $0.cli?.version = "1.0.0" }
    equal(
        Array(titles(newer).suffix(2)),
        ["Part of RNDIS Tether is out of date", "Run in Terminal: brew upgrade rndis-tether"])
    check(!newer.visible)  // no forced visibility, no privileged action
    check(!newer.rows.contains { $0.action != nil })

    equal(
        titles(model(running("no-phone")) { $0.cli?.version = "1.0.1-dev" }),
        ["No phone connected", "Plug in the phone and turn on USB tethering"])

    let protocol2 = model(.running(status("protocol=2\nstate=online\n")))
    equal(titles(protocol2), ["This app is older than the service", "Run in Terminal: brew upgrade rndis-tether-app"])
    equal(protocol2.glyph, .offline)
    check(protocol2.visible)

    // The downloaded app brings its own command: a newer service means a newer app is out.
    let bundledNewer = model(running("no-phone")) {
        $0.cli?.version = "1.0.0"
        $0.cli?.bundled = true
    }
    equal(Array(titles(bundledNewer).suffix(2)), ["This app is older than the service", howToFixTitle])
    equal(bundledNewer.rows.compactMap(\.action), [.openSettings])
    let bundledProtocol2 = model(.running(status("protocol=2\nstate=online\n"))) { $0.cli?.bundled = true }
    equal(titles(bundledProtocol2), ["This app is older than the service", howToFixTitle])

    equal(
        titles(model(running("no-phone", "settings-problem=line 3: bad value\n")) { $0.alwaysShowIcon = true }).last,
        "Settings file problem: line 3: bad value")

    // A state this app does not know yet: shown as is, as not connected.
    let unknown = model(running("no-phone", "state=charging\n"))
    equal(titles(unknown), ["Service state: charging"])
    equal(unknown.glyph, .offline)
    check(!unknown.visible && !unknown.summary.isEmpty)

    // Visibility: Always, a phone attached, or a service problem; nothing else.
    for (name, _) in samples {
        for always in [false, true] {
            for installing in [false, true] {
                let m = model(running(name)) {
                    $0.alwaysShowIcon = always
                    $0.installPhase = installing ? .starting(installJob, since: 0) : .idle
                }
                let expected = always || name != "no-phone" || installing
                check(m.visible == expected, "\(name) always=\(always) installing=\(installing)")
            }
        }
    }
    for service in [Service.notInstalled, .notRunning] {
        for always in [false, true] {
            check(model(service) { $0.alwaysShowIcon = always }.visible, "\(service) always=\(always)")
        }
    }
}

// MARK: Install

do {
    func observed(_ phase: InstallPhase, running: Bool, readAt: Double) -> InstallPhase {
        var p = phase
        p.observe(running: running, readAt: readAt)
        return p
    }
    equal(observed(.starting(installJob, since: 0), running: true, readAt: 5), .idle)
    equal(observed(.starting(installJob, since: 0), running: false, readAt: 5), .starting(installJob, since: 0))
    equal(observed(.starting(installJob, since: 0), running: false, readAt: InstallPhase.grace), .didNotStart)
    // Read before the install returned: the old service, whatever it said.
    equal(observed(.starting(installJob, since: 10), running: true, readAt: 9), .starting(installJob, since: 10))
    equal(observed(.didNotStart, running: true, readAt: 20), .idle)
    equal(observed(.password(installJob), running: true, readAt: 20), .password(installJob))  // the dialog is still up
}

// MARK: Settings window

func settings(_ service: Service, _ edit: (inout AppState) -> Void = { _ in }) -> SettingsModel {
    SettingsModel.make(appState(service, edit))
}

do {
    let ok = settings(running("online"))
    check(ok.primary == nil && ok.linkTitle == nil && !ok.needsService && ok.notReady == nil)
    check(ok.preferShown && ok.preferOn && ok.preferEnabled)
    equal(ok.footer, "Version 1.0.0 · Service 1.0.1")

    let user = settings(running("online", "prefer-phone=no\n")) { $0.canUseAdminSocket = false }
    check(user.preferShown && !user.preferOn && !user.preferEnabled)
    // A click shows until the service has it.
    check(settings(running("online", "prefer-phone=no\n")) { $0.preferRequested = true }.preferOn)
    check(!settings(running("online")) { $0.preferRequested = false }.preferOn)

    // Fresh install, admin.
    let fresh = settings(.notInstalled)
    equal(fresh.primary, .run(.install))
    equal(fresh.primaryTitle, "Install…")
    equal(fresh.copyText, "sudo '/usr/local/bin/rndis-tether' install")
    check(fresh.linkTitle != nil && !fresh.afterCopyHint.isEmpty && fresh.installMessage == nil)
    check(fresh.needsService && !fresh.preferShown)
    equal(fresh.footer, "Version 1.0.0 · Service not installed · Command 1.0.1")
    equal(settings(.notRunning).footer, "Version 1.0.0 · Service not running · Command 1.0.1")
    equal(settings(.running(status("protocol=1\nstate=no-phone\n"))).footer, "Version 1.0.0 · Service · Command 1.0.1")

    // Not an administrator: the dialog wants an administrator, and no Terminal link (sudo would fail).
    let standard = settings(.notInstalled) { $0.inAdminGroup = false }
    check(standard.paragraphs[0].contains("an administrator of this Mac"))
    equal(standard.linkTitle, nil)
    equal(standard.primary, .run(.install))
    // The same goes for the alert after a failed install.
    equal(SettingsModel.installFailureText("Boom.", action: .install, inAdminGroup: false), "Boom.")
    let failed = SettingsModel.installFailureText("Boom.", action: .update, inAdminGroup: true)
    check(failed.hasPrefix("Boom.\n\n") && failed.contains("“Prefer Terminal? Copy the update command”"), failed)

    let stopped = settings(.notRunning)
    equal(stopped.primaryTitle, "Reinstall…")
    check(stopped.linkTitle != nil)

    let older = settings(running("no-phone")) { $0.cli?.version = "1.0.10" }
    equal(older.primary, .run(.update))
    equal(older.primaryTitle, "Update…")
    check(older.serviceLine.hasSuffix(" (1.0.1 → 1.0.10)"))
    equal(older.serviceDetail, connectionDropWarning + ".")  // the settings page warns before the dialog
    check(older.needsService && older.linkTitle != nil)
    equal(older.footer, "Version 1.0.0 · Service 1.0.1 · Command 1.0.10")
    // An update keeps its texts while it runs: the action is remembered, not read from a button.
    let updating = settings(.notRunning) {
        $0.cli?.version = "1.0.10"
        $0.installPhase = .starting(updateJob, since: 0)
    }
    equal(updating.heading, older.heading)
    check(
        updating.installMessage != nil && updating.primary == nil && updating.linkTitle == nil && updating.needsService)
    let asking = settings(running("no-phone")) {
        $0.cli?.version = "1.0.10"
        $0.installPhase = .password(updateJob)
    }
    check(asking.installMessage != nil)
    // While the dialog is up or the service starts, no "Copied…" instructions: nothing to paste.
    check(asking.afterCopyHint.isEmpty && updating.afterCopyHint.isEmpty)

    let didNotStart = settings(.notInstalled) { $0.installPhase = .didNotStart }
    equal(didNotStart.primary, .run(.reinstall))
    check(didNotStart.installMessage != nil)

    let newer = settings(running("no-phone")) { $0.cli?.version = "1.0.0" }
    check(newer.primary == nil && !newer.needsService)  // no downgrade offered
    equal(settings(running("no-phone")) { $0.cli?.version = "x" }.primary, nil)

    // The rndis-tether command is missing: the fix is a Homebrew command.
    let noCLI = settings(.notInstalled) { $0.cli = nil }
    equal(noCLI.primary, .copy)
    equal(noCLI.copyText, "brew install stlk0/tap/rndis-tether")
    check(noCLI.command == noCLI.copyText && !noCLI.afterCopyHint.isEmpty)
    check(noCLI.linkTitle == nil && noCLI.needsService)

    // A CLI path the dialog cannot take: Terminal only.
    let oddPath = settings(.notInstalled) { $0.cli?.installable = false }
    equal(oddPath.primary, .copy)
    equal(oddPath.command, fresh.copyText)
    equal(oddPath.linkTitle, nil)

    // The app is older than the service: the setup stays on a page with the command.
    let protocol2 = settings(.running(status("protocol=2\nstate=online\n")))
    equal(protocol2.primary, .copy)
    equal(protocol2.copyText, "brew upgrade rndis-tether-app")
    check(!protocol2.afterCopyHint.isEmpty)  // its Copy confirmation shows
    check(protocol2.needsService && !protocol2.preferShown)
    let bundled = settings(.running(status("protocol=2\nstate=online\n"))) { $0.cli?.bundled = true }
    equal(bundled.copyText, appInstallCommand)
    check(bundled.needsService && bundled.notReady?.text.hasSuffix(appInstallCommand) == true)

    // Step 2 after Not Now names the menu item that fixes what is left.
    func menuItem(_ m: MenuModel) -> String { m.rows.first { $0.action == .openSettings }?.title ?? "none" }
    check(fresh.notReady?.text.hasSuffix(menuItem(model(.notInstalled))) == true)
    check(stopped.notReady?.text.hasSuffix(menuItem(model(.notRunning))) == true)
    check(older.notReady?.text.hasSuffix(menuItem(model(running("no-phone")) { $0.cli?.version = "1.0.10" })) == true)
    check(noCLI.notReady?.text.hasSuffix(menuItem(model(.notInstalled) { $0.cli = nil })) == true)
    check(protocol2.notReady?.text.hasSuffix("brew upgrade rndis-tether-app") == true)
    equal(older.notReady?.heading, "RNDIS Tether is ready")  // the old service still works

    // Before the first answer: no guess in the menu or the window, nothing to install.
    let checkingMenu = model(.notInstalled) { $0.serviceKnown = false }
    equal(titles(checkingMenu), ["Checking the service…"])
    check(!checkingMenu.visible && checkingMenu.rows.allSatisfy { $0.action == nil })
    check(
        model(.notInstalled) {
            $0.serviceKnown = false
            $0.alwaysShowIcon = true
        }.visible)
    let checking = settings(.notInstalled) { $0.serviceKnown = false }
    check(checking.needsService && checking.primary == nil && checking.linkTitle == nil && !checking.preferShown)
    equal(checking.serviceLine, "Background service: Checking…")
    equal(checking.footer, "Version 1.0.0")
}

// MARK: Pause (rndis-tether 1.1.0)

do {
    let pausable = "paused=no\n"
    // Disconnect while a phone is attached; only with a service that can pause.
    let online = model(running("online", pausable))
    equal(online.rows.last, MenuRow("Disconnect", action: .disconnect))
    for name in ["connecting", "retrying", "unsupported", "sleeping"] {
        equal(model(running(name, pausable)).rows.last?.action, .disconnect, name)
    }
    check(!model(running("no-phone", pausable)).rows.contains { $0.action == .disconnect })
    check(!model(running("online")).rows.contains { $0.action != nil })  // service 1.0.x: no item
    let user = model(running("online", pausable)) { $0.canUseAdminSocket = false }
    equal(user.rows.last, MenuRow("Disconnect (administrators only)", action: .disconnect, disabled: true))

    // Paused with a phone: visible, dimmed, Connect.
    let pausedPhone = model(.running(status(head + "state=paused\npaused=yes\n" + phone)))
    equal(
        titles(pausedPhone),
        ["SAMSUNG_Android", "Disconnected", "Click Connect to use the phone's internet again", "Connect"])
    equal(pausedPhone.rows.map(\.style), [.title, .primary, .secondary, .primary])
    equal(pausedPhone.rows.last?.action, .connect)
    equal(pausedPhone.glyph, .dimmed)
    check(pausedPhone.visible)
    equal(pausedPhone.summary, "Disconnected")
    // Paused without a phone: hidden unless Always.
    let pausedEmpty = model(.running(status(head + "state=paused\npaused=yes\n")))
    equal(titles(pausedEmpty), ["Disconnected", "Plug in the phone and click Connect", "Connect"])
    equal(pausedEmpty.glyph, .offline)
    check(!pausedEmpty.visible)
    check(model(.running(status(head + "state=paused\npaused=yes\n"))) { $0.alwaysShowIcon = true }.visible)
    let pausedUser = model(.running(status(head + "state=paused\npaused=yes\n" + phone))) {
        $0.canUseAdminSocket = false
    }
    equal(pausedUser.rows.last, MenuRow("Connect (administrators only)", action: .connect, disabled: true))
    equal(pausedUser.rows[2].title, "An administrator of this Mac can connect it again")  // not "Click Connect"

    // The quit setting: administrators, with a service that can pause.
    check(settings(running("online", pausable)).quitSettingShown)
    check(!settings(running("online")).quitSettingShown)
    check(!settings(running("online", pausable)) { $0.canUseAdminSocket = false }.quitSettingShown)
    check(!settings(.notInstalled).quitSettingShown)

    // Quit: admin, a service in a known format that can pause; then the setting on and
    // not paused already.
    let running11 = status(samples["online"]! + pausable)
    check(quitCanPause(canUseAdminSocket: true, status: running11))
    check(!quitCanPause(canUseAdminSocket: false, status: running11))
    check(!quitCanPause(canUseAdminSocket: true, status: status(samples["online"]!)))
    check(!quitCanPause(canUseAdminSocket: true, status: status("protocol=2\nstate=online\npaused=no\n")))
    check(!quitCanPause(canUseAdminSocket: true, status: nil))
    check(pausesOnQuit(keepConnection: false, canUseAdminSocket: true, status: running11))
    check(!pausesOnQuit(keepConnection: true, canUseAdminSocket: true, status: running11))
    check(!pausesOnQuit(keepConnection: false, canUseAdminSocket: false, status: running11))
    check(!pausesOnQuit(keepConnection: false, canUseAdminSocket: true, status: nil))
    check(!pausesOnQuit(keepConnection: false, canUseAdminSocket: true, status: status(samples["online"]!)))
    check(
        !pausesOnQuit(
            keepConnection: false, canUseAdminSocket: true, status: status(head + "state=paused\npaused=yes\n")))

    // Launch: undo only the pause the quit made (pidPausedOnQuit), never a manual Disconnect.
    let pausedStatus = status(head + "state=paused\npaused=yes\n" + phone)
    equal(launchPauseStep(pidPausedOnQuit: "286", canUseAdminSocket: true, status: pausedStatus), .resume)
    // Connected again since the quit, so no longer paused.
    equal(launchPauseStep(pidPausedOnQuit: "286", canUseAdminSocket: true, status: running11), .forget)
    equal(launchPauseStep(pidPausedOnQuit: "286", canUseAdminSocket: true, status: status(samples["online"]!)), .forget)
    // Paused by Disconnect or the CLI.
    equal(launchPauseStep(pidPausedOnQuit: nil, canUseAdminSocket: true, status: pausedStatus), .none)
    equal(launchPauseStep(pidPausedOnQuit: "286", canUseAdminSocket: true, status: nil), .none)  // wait for the service
    equal(launchPauseStep(pidPausedOnQuit: "286", canUseAdminSocket: false, status: pausedStatus), .forget)
    // The service restarted and the CLI paused the new one: not the quit's pause.
    equal(launchPauseStep(pidPausedOnQuit: "100", canUseAdminSocket: true, status: pausedStatus), .forget)
    let protocol2 = status("protocol=2\npid=286\nstate=paused\npaused=yes\n")
    equal(launchPauseStep(pidPausedOnQuit: "286", canUseAdminSocket: true, status: protocol2), .none)
}

// MARK: Window on start

do {
    // A launch: the setup the first time the user opens the app, afterwards only when it
    // replaces a running copy, and nothing for the LaunchAgent (--login) or an upgrade relaunch.
    check(opensWindowOnLaunch(setupDone: false, byUser: true, replacedCopy: false))
    check(!opensWindowOnLaunch(setupDone: true, byUser: true, replacedCopy: false))
    check(opensWindowOnLaunch(setupDone: true, byUser: true, replacedCopy: true))
    check(!opensWindowOnLaunch(setupDone: false, byUser: false, replacedCopy: false))
    check(!opensWindowOnLaunch(setupDone: true, byUser: false, replacedCopy: true))
}

// MARK: Advice, phone names, long text

do {
    equal(advice("USB interface already open by another program"), "Quit HoRNDIS or other tethering apps")
    equal(advice("sysctl net.link.fake.lro is 1"), "Restart the Mac")
    equal(advice("feth50 already exists"), "Another VPN or tether tool uses the interface")
    equal(advice("data interface not found"), "The phone is still turning on tethering…")
    equal(advice("timeout"), "Retrying by itself. If it stays, replug the cable.")

    equal(MenuModel.phoneRow("Pixel 7 18d1:4eec").title, "Pixel 7")
    equal(MenuModel.phoneRow("USB device 18d1:4eec").title, "Phone")
    equal(MenuModel.phoneRow("unknown device").title, "Phone")
    equal(MenuModel.phoneRow(" 18d1:4eec").title, "Phone")
    equal(MenuModel.phoneRow(nil), MenuRow("Phone", style: .title))
    equal(MenuModel.phoneRow("Pixel").tooltip, "Pixel")

    let long = String(repeating: "x", count: 60)
    equal(MenuRow.truncated(long).title.count, 50)
    check(MenuRow.truncated(long).title.hasSuffix("…"))
    equal(MenuRow.truncated(long).tooltip, long)
    equal(MenuRow.truncated(String(long.prefix(50))), MenuRow(String(long.prefix(50))))
}

// MARK: Core

do {
    equal(compareVersions("1.0.1", "1.0.1"), .orderedSame)
    equal(compareVersions("1.0.0", "1.0.1"), .orderedAscending)
    equal(compareVersions("1.1", "1.0.9"), .orderedDescending)
    equal(compareVersions("1.0.10", "1.0.9"), .orderedDescending)
    equal(compareVersions("1.0.1-dev", "1.0.1"), nil)
    equal(compareVersions("", "1.0"), nil)
    equal(compareVersions("1..0", "1.0"), nil)

    equal(versionFromCLIOutput("rndis-tether 1.0.1\n"), "1.0.1")
    equal(versionFromCLIOutput(""), nil)

    equal(
        optPath("/usr/local/Cellar/rndis-tether-app/1.0.0/RNDIS Tether.app"),
        "/usr/local/opt/rndis-tether-app/RNDIS Tether.app")
    equal(
        optPath("/opt/homebrew/Cellar/rndis-tether-app/1.0.0_1/RNDIS Tether.app"),
        "/opt/homebrew/opt/rndis-tether-app/RNDIS Tether.app")
    equal(optPath("/Applications/RNDIS Tether.app"), "/Applications/RNDIS Tether.app")

    check(isSafeCommandPath("/opt/homebrew/opt/rndis-tether/bin/rndis-tether"))
    check(isSafeCommandPath("/usr/local/bin/rndis-tether"))
    check(isSafeCommandPath("/Applications/RNDIS Tether.app/Contents/Helpers/rndis-tether"))
    for bad in ["rndis-tether", "/a\"b", "/a\\b", "/a'b", "/a\nb", "", "/a;b", "/a$(b)"] {
        check(!isSafeCommandPath(bad), "accepted \(bad.debugDescription)")
    }
    equal(installCommand("/usr/local/bin/rndis-tether"), "sudo '/usr/local/bin/rndis-tether' install")
    equal(installCommand("/a b"), "sudo '/a b' install")
    equal(installCommand("/a'b"), "sudo '/a'\\''b' install")

    for cli in [
        "/usr/local/bin/rndis-tether", "/opt/homebrew/opt/rndis-tether/bin/rndis-tether",
        "/Applications/RNDIS Tether.app/Contents/Helpers/rndis-tether",
    ] {
        var error: NSDictionary?
        check(
            NSAppleScript(source: Privileged.script(cliPath: cli, replacesRunning: true))?.compileAndReturnError(&error)
                == true,
            "\(String(describing: error))")
    }
    check(Privileged.script(cliPath: "/a", replacesRunning: true).contains("half a minute"))
    check(!Privileged.script(cliPath: "/a", replacesRunning: false).contains("half a minute"))

    // The LaunchAgent's arguments start the app as a login launch.
    let agent = LoginItem.plist(
        executable: "/usr/local/opt/rndis-tether-app/RNDIS Tether.app/Contents/MacOS/RNDIS Tether")
    let agentLaunch = Launch(agent["ProgramArguments"] as? [String] ?? [])
    check(agentLaunch.atLogin && !agentLaunch.byUser)
    check(Launch(["app", "--login"]).atLogin)
    let relaunched = Launch(["app", "--relaunch"])
    check(relaunched.relaunched && !relaunched.byUser)
    check(Launch(["app"]).byUser)
}

print(failures == 0 ? "All tests passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
