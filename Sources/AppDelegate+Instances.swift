import AppKit

private let quitNotification = Notification.Name(Paths.bundleID + ".quit")
/// The quit notification's object: a copy ignores its own post.
private let ownPID = String(getpid())

extension AppDelegate {
    /// The copy started last asks the others to quit. Returns whether another copy was running.
    func replaceOtherCopies() -> Bool {
        let othersRunning = NSRunningApplication.runningApplications(withBundleIdentifier: Paths.bundleID)
            .contains { $0.processIdentifier != getpid() }
        if othersRunning {
            DistributedNotificationCenter.default().postNotificationName(
                quitNotification, object: ownPID,
                userInfo: nil, deliverImmediately: true)
        }
        return othersRunning
    }

    func listenToOtherCopies() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(quitFromNotification(_:)),
            name: quitNotification, object: nil)
    }

    /// exit(0): KeepAlive does not restart it, and the quit's pause is skipped, so the phone
    /// stays connected.
    @objc func quitFromNotification(_ notification: Notification) {
        if notification.object as? String != ownPID { exit(0) }
    }

    /// Not Bundle: it caches the Info.plist of a path, and an upgrade changes the file.
    func shortVersion(ofApp path: String) -> String? {
        NSDictionary(contentsOfFile: path + "/Contents/Info.plist")?["CFBundleShortVersionString"] as? String
    }

    func relaunchIfUpgraded() {
        guard !menuOpen, !installPhase.isBusy, settingsWindow?.isVisible != true else { return }
        guard let version = shortVersion(ofApp: stableAppPath),
            compareVersions(version, appVersion) == .orderedDescending
        else { return }
        if launch.atLogin { exit(EX_TEMPFAIL) }  // launchd's KeepAlive starts the new version
        // The new copy asks this one to quit (replaceOtherCopies).
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [Launch.relaunchArgument]
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: stableAppPath), configuration: configuration)
    }
}
