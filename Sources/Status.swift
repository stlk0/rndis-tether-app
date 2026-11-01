import Foundation

/// One answer of the status socket: `name=value` lines, split at the first `=`.
struct ServiceStatus: Equatable {
    /// `state` values (README "For other programs").
    enum State: String {
        case noPhone = "no-phone"
        case paused, unsupported, sleeping, retrying, connecting, online
    }

    var fields: [String: String] = [:]

    init(text: String) {
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
    }

    subscript(name: String) -> String? { fields[name] }
    func number(_ name: String) -> UInt64? { fields[name].flatMap { UInt64($0) } }
    /// With another format, no other field means anything.
    var protocolSupported: Bool { fields["protocol"] == "1" }
    /// The service's process: a new pid is a new service.
    var pid: String? { fields["pid"] }
    var version: String? { fields["version"] }
    /// nil for a value this app does not know: treated as not connected and shown as is.
    var state: State? { fields["state"].flatMap(State.init(rawValue:)) }
    /// USB name of the phone while one is plugged in, also while paused.
    var phone: String? { fields["phone"] }
    /// `sleeping` only happens with a phone attached (rndis-tether's src/status.c,
    /// status_choose), so wake does not flicker.
    var phoneAttached: Bool {
        switch state {
        case .connecting, .retrying, .online, .unsupported, .sleeping: return true
        case .paused: return phone != nil
        case .noPhone, nil: return false
        }
    }
    /// rndis-tether 1.1.0 and later.
    var supportsPause: Bool { fields["paused"] != nil }
    var paused: Bool { fields["paused"] == "yes" }
    var prefersPhone: Bool { fields["prefer-phone"] == "yes" }
}

enum Service: Equatable {
    case notInstalled  // no LaunchDaemon plist
    case notRunning  // the plist is there, the status socket does not answer
    case running(ServiceStatus)

    var status: ServiceStatus? {
        if case .running(let status) = self { return status }
        return nil
    }
}

struct ServiceSnapshot {
    /// nil while the service is busy: what it said last still holds.
    var service: Service?
    var canUseAdminSocket: Bool
    var readAt: Double  // uptime
}

/// Bits per second.
struct Speed: Equatable {
    var down: Double
    var up: Double
}

struct SpeedMeter {
    /// Readings closer than this (the menu and the window poll at once) say 0 or a spike.
    private static let minInterval = 0.5

    private var previous: (session: String, rx: UInt64, tx: UInt64, time: Double)?
    private(set) var speed: Speed?

    mutating func add(_ status: ServiceStatus?, time: Double) {
        guard let status, let rx = status.number("rx-bytes"), let tx = status.number("tx-bytes") else {
            previous = nil
            speed = nil
            return
        }
        let session = "\(status.pid ?? "")/\(status["connected-since"] ?? "")"
        if let previous, previous.session == session {
            let elapsed = time - previous.time
            guard elapsed >= Self.minInterval else { return }  // keeps speed and previous
            if rx >= previous.rx, tx >= previous.tx {
                speed = Speed(down: Double(rx - previous.rx) * 8 / elapsed, up: Double(tx - previous.tx) * 8 / elapsed)
            } else {
                speed = nil
            }
        } else {
            speed = nil
        }
        previous = (session, rx, tx, time)
    }
}

enum ServiceAction: Equatable {
    case install, reinstall, update

    var verb: String { self == .update ? "update" : "install" }
}

/// The outage while an install replaces a running service.
let connectionDropWarning = "Internet through the phone stops for up to half a minute"

/// Kept while the install runs, so the texts do not change halfway.
struct InstallJob: Equatable {
    var action: ServiceAction
    var replacesRunning: Bool  // the phone's connection drops
}

enum InstallPhase: Equatable {
    case idle
    case password(InstallJob)
    /// The install returned at `since` (uptime); the service has `grace` seconds to answer.
    case starting(InstallJob, since: Double)
    case didNotStart

    static let grace = 10.0

    var job: InstallJob? {
        switch self {
        case .password(let job), .starting(let job, _): return job
        case .idle, .didNotStart: return nil
        }
    }

    var isBusy: Bool { job != nil }

    /// Moves on from `starting` once a read made after the install returned sees the service
    /// (idle) or the grace time passes without it (didNotStart); `didNotStart` clears when the
    /// service shows up.
    mutating func observe(running: Bool, readAt: Double) {
        switch self {
        case .starting(_, let since):
            guard readAt >= since else { return }  // that read saw the old service
            if running {
                self = .idle
            } else if readAt >= since + Self.grace {
                self = .didNotStart
            }
        case .didNotStart where running:
            self = .idle
        default:
            break
        }
    }
}

struct AppState {
    var service: Service
    /// Until a poll has found the service, or found it missing, `service` is a guess.
    var serviceKnown: Bool
    var installPhase: InstallPhase
    var cli: CLI?
    var canUseAdminSocket: Bool
    /// The password dialog and sudo accept the user's own password.
    var inAdminGroup: Bool
    var alwaysShowIcon: Bool
    /// The user's last click on "Prefer the phone", shown until the service has it.
    var preferRequested: Bool?
    var speed: Speed?
    var appVersion: String
    /// Wall clock, to compare with the service's `connected-since`; polls use `uptime`.
    var now: Double
    var interfaceName: (String) -> String

    var neededAction: ServiceAction? {
        switch service {
        case .running(let s):
            return compareServiceWithCLI(s, cliVersion: cli?.version) == .orderedAscending ? .update : nil
        case .notInstalled: return installPhase == .didNotStart ? .reinstall : .install
        case .notRunning: return .reinstall
        }
    }
}

/// The CLI's version is the one `rndis-tether install` would install.
func compareServiceWithCLI(_ status: ServiceStatus, cliVersion: String?) -> ComparisonResult? {
    guard let service = status.version, let cliVersion else { return nil }
    return compareVersions(service, cliVersion)
}
