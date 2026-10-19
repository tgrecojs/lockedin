import Foundation

/// Every name, path, and limit LockedIn uses, in one place.
/// To rename the project or relocate its files, change values here and nowhere else.
public enum Identifiers {
    public static let version = "0.1.0"
    public static let protocolVersion = 1

    public static let appName = "LockedIn"
    public static let bundleID = "com.tgreco.lockedin"
    public static let logSubsystem = "com.tgreco.lockedin"

    public static let daemonLabel = "com.tgreco.lockedin.daemon"
    public static let daemonExecutableName = "lockedind"
    public static let cliExecutableName = "lockedin"
    public static let appExecutableName = "LockedInApp"

    public static let daemonBinaryPath = "/Library/PrivilegedHelperTools/com.tgreco.lockedin.daemon"
    public static let launchdPlistPath = "/Library/LaunchDaemons/com.tgreco.lockedin.daemon.plist"
    public static let socketPath = "/var/run/lockedin.sock"
    public static let supportDirectory = "/Library/Application Support/LockedIn"
    public static let stateFilePath = "/Library/Application Support/LockedIn/state.json"
    public static let tablesDirectory = "/Library/Application Support/LockedIn/tables"
    public static let logDirectory = "/Library/Logs/LockedIn"
    public static let logFilePath = "/Library/Logs/LockedIn/lockedind.log"

    public static let authorizationRight = "com.tgreco.lockedin.start"
    public static let authorizationPrompt =
        "LockedIn needs your permission to start a block. A running block cannot be stopped early."

    public static let pfAnchor = "com.apple/300.lockedin"
    public static let pfWildcardAnchor = "com.apple/*"
    public static let pfAnchorFilePath = "/etc/pf.anchors/com.tgreco.lockedin"
    public static let pfConfPath = "/etc/pf.conf"
    public static let pfTable = "lockedin_blocked"
    public static func pfPortTable(_ port: UInt16) -> String { "\(pfTable)_p\(port)" }

    public static let hostsPath = "/etc/hosts"
    public static let hostsBeginMarker = "# BEGIN LOCKEDIN BLOCK"
    public static let hostsEndMarker = "# END LOCKEDIN BLOCK"
    public static let hostsBeginLine =
        "# BEGIN LOCKEDIN BLOCK -- managed by com.tgreco.lockedin.daemon; re-applied until the block ends; do not edit"
    public static let legacyHostsBeginMarker = "# BEGIN SELFCONTROL BLOCK"
    public static let legacyHostsEndMarker = "# END SELFCONTROL BLOCK"

    public static let cliInstallPath = "/usr/local/bin/lockedin"
    public static let appInstallPath = "/Applications/LockedIn.app"
    public static let userBlocklistRelativePath = ".config/lockedin/blocklist.txt"

    public static let adminGroupID: UInt32 = 80

    public static let minBlockSeconds = 10
    public static let maxBlockSeconds = 7 * 24 * 60 * 60
    public static let defaultMaxBlockMinutes = 24 * 60
    public static let maxEntries = 2000
    public static let maxRequestBytes = 256 * 1024
    public static let persistIntervalSeconds = 10
    public static let integrityIntervalSeconds = 15
    public static let resolveIntervalSeconds = 180
    public static let resolveBudgetSeconds: Double = 10

    /// Names and paths left behind by the original SelfControl app; cleaned up on install.
    public enum Legacy {
        public static let daemonLabel = "org.eyebeam.selfcontrold"
        public static let launchdPlistPath = "/Library/LaunchDaemons/org.eyebeam.selfcontrold.plist"
        public static let helperPath = "/Library/PrivilegedHelperTools/org.eyebeam.selfcontrold"
        public static let oldDaemonLabel = "org.eyebeam.SelfControl"
        public static let oldLaunchdPlistPath = "/Library/LaunchDaemons/org.eyebeam.SelfControl.plist"
        public static let oldHelperPath = "/Library/PrivilegedHelperTools/org.eyebeam.SelfControl"
        public static let pfAnchorName = "org.eyebeam"
        public static let pfAnchorFilePath = "/etc/pf.anchors/org.eyebeam"
        public static let pfTokenPath = "/etc/SelfControlPFToken"
        public static let lockPath = "/etc/SelfControl.lock"
        public static let settingsDirectory = "/usr/local/etc"
        public static let preferencesDomain = "org.eyebeam.SelfControl"
        public static let preferencesBlocklistKey = "Blocklist"
    }

    /// Ordered key/value listing for `lockedin identifiers`.
    public static var all: [(key: String, value: String)] {
        [
            ("version", version),
            ("protocolVersion", String(protocolVersion)),
            ("appName", appName),
            ("bundleID", bundleID),
            ("daemonLabel", daemonLabel),
            ("daemonBinaryPath", daemonBinaryPath),
            ("launchdPlistPath", launchdPlistPath),
            ("socketPath", socketPath),
            ("supportDirectory", supportDirectory),
            ("stateFilePath", stateFilePath),
            ("tablesDirectory", tablesDirectory),
            ("logFilePath", logFilePath),
            ("authorizationRight", authorizationRight),
            ("pfAnchor", pfAnchor),
            ("pfAnchorFilePath", pfAnchorFilePath),
            ("pfTable", pfTable),
            ("hostsPath", hostsPath),
            ("hostsBeginMarker", hostsBeginMarker),
            ("hostsEndMarker", hostsEndMarker),
            ("cliInstallPath", cliInstallPath),
            ("appInstallPath", appInstallPath),
            ("userBlocklistRelativePath", userBlocklistRelativePath),
            ("maxBlockSeconds", String(maxBlockSeconds)),
            ("maxEntries", String(maxEntries)),
        ]
    }
}
