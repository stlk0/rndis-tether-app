import Foundation

/// "Open at Login" as a user LaunchAgent. SMAppService piles up stale entries when an
/// ad hoc rebuild changes the code identity. Never runs launchctl: bootout would kill a
/// copy that launchd started.
enum LoginItem {
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Paths.bundleID).plist")
    }

    static var isOn: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static var executable: String? { (NSDictionary(contentsOf: plistURL)?["ProgramArguments"] as? [String])?.first }

    static func turnOn(executable: String) throws {
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist(executable: executable),
            format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
    }

    static func turnOff() throws {
        if isOn { try FileManager.default.removeItem(at: plistURL) }
    }

    /// The user LaunchAgent that opens the app at login. KeepAlive restarts it after a crash
    /// or a non-zero exit (EX_TEMPFAIL: relaunch into a new version), not after Quit.
    static func plist(executable: String) -> [String: Any] {
        [
            "Label": Paths.bundleID,
            "ProgramArguments": [executable, Launch.loginArgument],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "AssociatedBundleIdentifiers": [Paths.bundleID],
        ]
    }
}
