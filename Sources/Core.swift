import Foundation

enum Paths {
    static let bundleID = "io.github.stlk0.rndis-tether-app"
    static let statusSocket = "/var/run/rndis-tether.sock"
    static let adminSocket = "/var/run/rndis-tether-admin.sock"
    static let daemonPlist = "/Library/LaunchDaemons/io.github.stlk0.rndis-tether.plist"
    static let cliFallbacks = ["/opt/homebrew/bin/rndis-tether", "/usr/local/bin/rndis-tether"]
    /// The command inside the app that install.sh installs; the Homebrew build has none.
    static let bundledCLI = "/Contents/Helpers/rndis-tether"
}

let upgradeAppCommand = "brew upgrade rndis-tether-app"
/// install.sh, which also updates the app it installed.
let appInstallCommand =
    "/bin/sh -c \"$(curl -fsSL https://raw.githubusercontent.com/stlk0/rndis-tether-app/main/install.sh)\""

/// Dotted numbers compared numerically (`1.0.10` > `1.0.9`); nil if either is anything else,
/// so no privileged action is offered on a version this app cannot read.
func compareVersions(_ a: String, _ b: String) -> ComparisonResult? {
    let dotted = "^[0-9]+(\\.[0-9]+)*$"
    guard [a, b].allSatisfy({ $0.range(of: dotted, options: .regularExpression) != nil }) else { return nil }
    return a.compare(b, options: .numeric)
}

/// `rndis-tether version` prints `rndis-tether 1.0.1`: the last word.
func versionFromCLIOutput(_ output: String) -> String? {
    output.split(whereSeparator: \.isWhitespace).last.map(String.init)
}

/// Homebrew deletes `/Cellar/<name>/<version>/` on upgrade; `/opt/<name>/` stays.
func optPath(_ path: String) -> String {
    path.replacingOccurrences(of: "/Cellar/([^/]+)/[^/]+/", with: "/opt/$1/", options: .regularExpression)
}

struct CLI {
    var path: String
    var version: String?
    var installable: Bool
    /// Inside the app (install.sh): a newer one comes with a new version of the app.
    var bundled = false

    /// Blocks; socket queue only. Homebrew's command first, then the app's own, then any other.
    static func lookUp() -> CLI? {
        let bundledPath = Bundle.main.bundlePath + Paths.bundledCLI
        var candidates = [bundledPath] + Paths.cliFallbacks
        if let path = Bundle.main.object(forInfoDictionaryKey: "RTCLIPath") as? String, !path.isEmpty {
            candidates.insert(path, at: 0)
        }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        return CLI(
            path: path, version: cachedVersion(of: path), installable: isInstallable(path), bundled: path == bundledPath
        )
    }

    private static var cache: (file: [String], version: String)?

    /// Asks the command again only when its file changed: `rndis-tether install` replaces it
    /// under the same name, and `brew upgrade` points the link at a new Cellar path.
    private static func cachedVersion(of path: String) -> String? {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let attributes = (try? FileManager.default.attributesOfItem(atPath: real)) ?? [:]
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let file = [path, real, "\(attributes[.systemFileNumber] ?? "")", "\(modified)"]
        if let cache, cache.file == file { return cache.version }
        let found = version(of: path)
        cache = found.map { (file, $0) }  // a failed run is tried again
        return found
    }

    private static func version(of path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return process.terminationStatus == 0 ? versionFromCLIOutput(output) : nil
    }

    /// An existing regular executable at a path that is safe to hand to AppleScript.
    static func isInstallable(_ path: String) -> Bool {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let type = (try? FileManager.default.attributesOfItem(atPath: real))?[.type] as? FileAttributeType
        return isSafeCommandPath(path) && type == .typeRegular && FileManager.default.isExecutableFile(atPath: real)
    }
}

/// Absolute, and no quotes, backslashes or newlines that could reach AppleScript. Spaces are
/// fine: the app's own command is inside "RNDIS Tether.app".
func isSafeCommandPath(_ path: String) -> Bool {
    path.range(of: "^/[A-Za-z0-9._+@/ -]+$", options: .regularExpression) != nil
}

/// The install command for Terminal, with the path in single quotes for the shell.
func installCommand(_ cliPath: String) -> String {
    "sudo '" + cliPath.replacingOccurrences(of: "'", with: "'\\''") + "' install"
}
