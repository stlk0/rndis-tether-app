import Foundation

/// The menu bar symbol: online; a phone without internet, or an install running; nothing usable.
enum Glyph { case online, dimmed, offline }

/// Raw values are NSMenuItem tags; 0 means none.
enum MenuAction: Int {
    case openSettings = 1
    case disconnect, connect
}

struct MenuRow: Equatable {
    /// How an info row (one without an action) is drawn.
    enum Style { case title, primary, secondary, speed }

    var title: String
    var tooltip: String?
    var action: MenuAction?
    /// What VoiceOver says instead of a title that is not words.
    var accessibilityLabel: String?
    var style: Style
    var disabled: Bool

    init(
        _ title: String, tooltip: String? = nil, action: MenuAction? = nil, accessibilityLabel: String? = nil,
        style: Style = .primary, disabled: Bool = false
    ) {
        self.title = title
        self.tooltip = tooltip
        self.action = action
        self.accessibilityLabel = accessibilityLabel
        self.style = style
        self.disabled = disabled
    }

    static func hint(_ title: String) -> MenuRow { MenuRow(title, style: .secondary) }
    static func terminalHint(_ command: String) -> MenuRow { .hint("Run in Terminal: \(command)") }

    /// Longer titles widen the whole menu.
    private static let maxTitleLength = 50

    /// Text from the service or the phone: the full text in the tooltip.
    static func truncated(_ text: String, style: Style = .primary) -> MenuRow {
        guard text.count > maxTitleLength else { return MenuRow(text, style: style) }
        return MenuRow(String(text.prefix(maxTitleLength - 1)) + "…", tooltip: text, style: style)
    }
}

extension ServiceAction {
    /// The window's texts name it too.
    var menuTitle: String {
        switch self {
        case .install: return "Install Service…"
        case .reinstall: return "Reinstall Service…"
        case .update: return "Update Service…"
        }
    }
}

let howToFixTitle = "Show How to Fix…"
/// The window's later-hint quotes it.
let settingsMenuTitle = "Settings…"

struct MenuModel {
    var rows: [MenuRow]
    var glyph: Glyph
    var visible: Bool
    var summary: String  // the accessibility description

    static func make(_ state: AppState) -> MenuModel {
        guard state.serviceKnown else {  // nothing to offer on a guess
            let checking = "Checking the service…"
            return MenuModel(
                rows: [MenuRow(checking, style: .title)], glyph: .offline, visible: state.alwaysShowIcon,
                summary: checking)
        }
        var rows = menuRows(state)
        let summary = (rows.first { $0.style == .primary } ?? rows[0]).title  // not the phone's name
        rows[0].style = .title  // the headline
        let phoneAttached = state.service.status?.phoneAttached == true
        return MenuModel(
            rows: rows, glyph: glyph(state), visible: state.alwaysShowIcon || phoneAttached || needsAttention(state),
            summary: summary)
    }

    /// A service problem keeps the icon visible, even with no phone.
    private static func needsAttention(_ state: AppState) -> Bool {
        state.installPhase.isBusy || state.neededAction != nil || state.service.status?.protocolSupported == false
    }

    private static func glyph(_ state: AppState) -> Glyph {
        if state.installPhase.isBusy { return .dimmed }
        guard let s = state.service.status, s.protocolSupported else { return .offline }
        return s.state == .online ? .online : s.phoneAttached ? .dimmed : .offline
    }

    private static func menuRows(_ state: AppState) -> [MenuRow] {
        // The old service still answers while the password dialog of an update is up.
        if let job = state.installPhase.job {
            return [MenuRow("Installing the service…")] + (job.replacesRunning ? [.hint(connectionDropWarning)] : [])
        }
        switch state.service {
        case .running(let s) where !s.protocolSupported:
            return appTooOldRows(state)
        case .running(let s):
            var rows = stateRows(s, state) + connectionToggleRows(s, state) + versionRows(s, state)
            if let p = s["settings-problem"] {
                rows.append(.truncated("Settings file problem: \(p)", style: .secondary))
            }
            return rows
        case .notInstalled, .notRunning:
            guard state.cli != nil else {
                return [MenuRow("Part of RNDIS Tether is missing"), MenuRow(howToFixTitle, action: .openSettings)]
            }
            // neededAction is Reinstall after an install that didn't start, as in the window.
            let action = state.neededAction ?? .reinstall  // never nil for these two cases
            return [
                MenuRow(action == .install ? "Service not installed" : "Service not running"),
                MenuRow(action.menuTitle, action: .openSettings),
            ]
        }
    }

    private static func stateRows(_ s: ServiceStatus, _ state: AppState) -> [MenuRow] {
        let phone = phoneRow(s.phone)
        switch s.state {
        case .online:
            return onlineRows(s, phone: phone, state)
        case .connecting:
            return [phone, MenuRow("Connecting…")]
        case .retrying:
            let problem = s["problem"] ?? ""
            return [phone, .truncated("Can't connect: \(problem)"), .hint(advice(problem))]
        case .unsupported:
            return [
                phone, MenuRow("Not working as USB tethering"),
                .hint("Unplug it, turn on USB tethering, plug it in again"),
            ]
        case .paused:
            let hint: String
            if !state.canUseAdminSocket {
                hint = "An administrator of this Mac can connect it again"  // Connect is greyed out
            } else if s.phoneAttached {
                hint = "Click Connect to use the phone's internet again"
            } else {
                hint = "Plug in the phone and click Connect"
            }
            return (s.phoneAttached ? [phone] : []) + [MenuRow("Disconnected"), .hint(hint)]
        case .sleeping:
            return [MenuRow("Paused while the Mac sleeps")]
        case .noPhone:
            return [MenuRow("No phone connected"), .hint("Plug in the phone and turn on USB tethering")]
        case nil:
            return [.truncated("Service state: \(s["state"] ?? "")")]
        }
    }

    /// Duration and speed, then the route and the error counters when they say something.
    private static func onlineRows(_ s: ServiceStatus, phone: MenuRow, _ state: AppState) -> [MenuRow] {
        let since = Double(s.number("connected-since") ?? 0)
        var rows = [phone, MenuRow("Online for \(durationText(state.now - since))"), speedRow(state.speed)]
        if let primary = s["primary"], primary != s["interface"] {
            rows.append(
                primary.isEmpty
                    ? .hint("macOS has no internet route right now")
                    : .truncated("Internet goes through \(state.interfaceName(primary))", style: .secondary))
        }
        let dropped = (s.number("rx-dropped") ?? 0) + (s.number("tx-dropped") ?? 0)
        let errors = s.number("usb-errors") ?? 0
        let resets = s.number("resets") ?? 0
        if dropped + errors + resets > 0 {
            rows.append(.hint("Problems: dropped \(dropped), USB errors \(errors), resets \(resets)"))
        }
        return rows
    }

    /// Connect while paused, Disconnect while a phone is attached; greyed out for other users.
    private static func connectionToggleRows(_ s: ServiceStatus, _ state: AppState) -> [MenuRow] {
        let isPaused = s.state == .paused
        guard s.supportsPause, isPaused || s.phoneAttached else { return [] }
        let allowed = state.canUseAdminSocket
        let title = (isPaused ? "Connect" : "Disconnect") + (allowed ? "" : " (administrators only)")
        return [MenuRow(title, action: isPaused ? .connect : .disconnect, disabled: !allowed)]
    }

    /// The app from install.sh updates by running it again (too long for the menu); Homebrew's
    /// by `brew upgrade`.
    private static func appTooOldRows(_ state: AppState) -> [MenuRow] {
        let next =
            state.cli?.bundled == true
            ? MenuRow(howToFixTitle, action: .openSettings) : .terminalHint(upgradeAppCommand)
        return [MenuRow("This app is older than the service"), next]
    }

    private static func versionRows(_ s: ServiceStatus, _ state: AppState) -> [MenuRow] {
        guard let cliVersion = state.cli?.version else { return [] }
        switch compareServiceWithCLI(s, cliVersion: cliVersion) {
        case .orderedAscending?:
            return [
                MenuRow(ServiceAction.update.menuTitle, action: .openSettings), .hint("Version \(cliVersion) is ready"),
            ]
        case .orderedDescending? where state.cli?.bundled == true:
            return appTooOldRows(state)
        case .orderedDescending?:
            return [MenuRow("Part of RNDIS Tether is out of date"), .terminalHint("brew upgrade rndis-tether")]
        default:
            return []
        }
    }

    /// Tab-separated: the menu puts each value in a fixed column.
    static func speedRow(_ speed: Speed?) -> MenuRow {
        guard let speed else {
            return MenuRow("↓\t—\t↑\t—", accessibilityLabel: "Speed not measured yet", style: .speed)
        }
        let down = speedText(speed.down)
        let up = speedText(speed.up)
        return MenuRow("↓\t\(down)\t↑\t\(up)", accessibilityLabel: "Download \(down), upload \(up)", style: .speed)
    }

    /// `phone` without the trailing ` vvvv:pppp`; `Phone` when the USB name says nothing.
    static func phoneRow(_ phone: String?) -> MenuRow {
        let full = phone ?? ""
        let name = full.replacingOccurrences(
            of: " [0-9a-fA-F]{4}:[0-9a-fA-F]{4}$", with: "", options: .regularExpression)
        // "USB device" and "unknown device": the service's names for a phone without a product
        // name (rndis-tether's src/usb.c); "" when there was only the id or no phone field.
        let hasName = !["", "USB device", "unknown device"].contains(name)
        var row = MenuRow.truncated(hasName ? name : "Phone", style: .title)
        if !full.isEmpty { row.tooltip = full }
        return row
    }
}

func speedText(_ bitsPerSecond: Double) -> String {
    bitsPerSecond >= 1e6
        ? String(format: "%.1f Mbit/s", bitsPerSecond / 1e6)
        : String(format: "%.0f kbit/s", bitsPerSecond / 1e3)
}

func durationText(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    if total < 60 { return "\(total) s" }
    if total < 3600 { return "\(total / 60) min" }
    return "\(total / 3600) h \(total / 60 % 60) min"
}

/// The same substrings `rndis-tether status` matches (rndis-tether's src/cli.c, advice()).
func advice(_ problem: String) -> String {
    if problem.contains("already open by another program") { return "Quit HoRNDIS or other tethering apps" }
    if problem.contains("net.link.fake") { return "Restart the Mac" }
    if problem.contains("already exists") { return "Another VPN or tether tool uses the interface" }
    if problem.contains("data interface not found") { return "The phone is still turning on tethering…" }
    return "Retrying by itself. If it stays, replug the cable."
}

/// Hides the icon only after `delay` seconds unwanted, so a replug does not make it flicker.
struct Visibility {
    static let delay = 3.0
    private(set) var visible = false
    private var unwantedSince: Double?

    /// The seconds until a pending hide is due.
    mutating func update(want: Bool, now: Double) -> Double? {
        if want {
            visible = true
            unwantedSince = nil
            return nil
        }
        guard visible else { return nil }
        let since = unwantedSince ?? now
        unwantedSince = since
        if now - since >= Self.delay {
            visible = false
            unwantedSince = nil
            return nil
        }
        return since + Self.delay - now
    }
}
