import AppKit

// Outside the bundle the login item would point at a path that does not exist.
if Bundle.main.bundleIdentifier != Paths.bundleID {
    FileHandle.standardError.write(Data("Open \"RNDIS Tether.app\"\n".utf8))
    exit(EX_USAGE)
}

let app = NSApplication.shared
let delegate = AppDelegate(launch: Launch(CommandLine.arguments))
app.delegate = delegate
app.setActivationPolicy(.accessory)
// The LaunchAgent starts the app at login; macOS should not reopen it a second time.
app.disableRelaunchOnLogin()
app.run()
