import Foundation

final class Prefs {
    /// Stored names; changing one forgets that setting in installed copies.
    private enum Key: String {
        case keepConnectionOnQuit
        case alwaysShowIcon = "showIconMode"
        case setupDone = "didInitialize"
        case didTurnOnLoginByDefault = "loginDefaulted"
        case pidPausedOnQuit = "pausedOnQuit"
    }

    private let defaults = UserDefaults.standard

    private func value(_ key: Key) -> Any? { defaults.object(forKey: key.rawValue) }
    private func set(_ value: Any?, for key: Key) { defaults.set(value, forKey: key.rawValue) }

    var alwaysShowIcon: Bool {
        get { value(.alwaysShowIcon) as? String == "always" }
        set { set(newValue ? "always" : "connected", for: .alwaysShowIcon) }
    }
    var setupDone: Bool {
        get { value(.setupDone) as? Bool ?? false }
        set { set(newValue, for: .setupDone) }
    }
    /// Open at Login was turned on once, on the first launch; never again by itself.
    var didTurnOnLoginByDefault: Bool {
        get { value(.didTurnOnLoginByDefault) as? Bool ?? false }
        set { set(newValue, for: .didTurnOnLoginByDefault) }
    }
    /// The pid of the service the last quit paused; the next launch connects it again.
    /// Connect or Disconnect by the user clears it.
    var pidPausedOnQuit: String? {
        get { value(.pidPausedOnQuit) as? String }
        set { set(newValue, for: .pidPausedOnQuit) }
    }
    var keepConnectionOnQuit: Bool {
        get { value(.keepConnectionOnQuit) as? Bool ?? false }
        set { set(newValue, for: .keepConnectionOnQuit) }
    }
}
