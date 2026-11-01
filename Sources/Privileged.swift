import Darwin.membership
import Foundation

/// `rndis-tether install` behind the macOS password dialog. In this process, so the dialog
/// names this app, and on the main thread, where NSAppleScript is used; the icon does not
/// respond until the install is done.
enum Privileged {
    enum InstallOutcome {
        case ok, cancelled
        case failed(String)
    }

    static func install(cliPath: String, replacesRunning: Bool) -> InstallOutcome {
        guard isSafeCommandPath(cliPath),
            let appleScript = NSAppleScript(source: script(cliPath: cliPath, replacesRunning: replacesRunning))
        else {
            return .failed("The rndis-tether command has an unusual path: \(cliPath)")
        }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        guard let error else { return .ok }
        if error[NSAppleScript.errorNumber] as? Int == userCanceledErr { return .cancelled }
        return .failed(error[NSAppleScript.errorMessage] as? String ?? "Unknown error")
    }

    /// The script for one macOS password dialog. Only call it with a path that passed
    /// `isSafeCommandPath`; it also goes through `quoted form of`.
    static func script(cliPath: String, replacesRunning: Bool) -> String {
        var prompt = "RNDIS Tether needs your password to install or update its background service."
        if replacesRunning { prompt += " \(connectionDropWarning)." }
        return "do shell script (quoted form of \"\(cliPath)\") & \" install\" "
            + "with prompt \"\(prompt)\" with administrator privileges"
    }

    /// The admin group, nested groups included: known before the admin socket exists.
    static func currentUserIsInAdminGroup() -> Bool {
        let adminGroupID: gid_t = 80
        var user = [UInt8](repeating: 0, count: MemoryLayout<uuid_t>.size)
        var group = user
        var member: Int32 = 0
        guard mbr_uid_to_uuid(getuid(), &user) == 0, mbr_gid_to_uuid(adminGroupID, &group) == 0,
            mbr_check_membership(&user, &group, &member) == 0
        else { return false }
        return member != 0
    }
}
