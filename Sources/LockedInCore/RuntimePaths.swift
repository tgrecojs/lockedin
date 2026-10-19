import Foundation

/// Effective filesystem locations. In production these are the system paths from `Identifiers`.
///
/// For unprivileged testing, set `LOCKEDIN_TEST_ROOT=<dir>`: every path is relocated under that
/// directory and pfctl is simulated. `LOCKEDIN_SOCKET=<path>` overrides the socket path on its own
/// (unix socket paths must stay under 104 bytes, so a deep test root needs a short socket path).
public struct RuntimePaths: Sendable, Equatable {
    public let root: String
    public let socket: String

    public init(root: String, socketOverride: String? = nil) {
        self.root = root
        self.socket = socketOverride ?? (root + Identifiers.socketPath)
    }

    public static let current: RuntimePaths = {
        let env = ProcessInfo.processInfo.environment
        return RuntimePaths(root: env["LOCKEDIN_TEST_ROOT"] ?? "", socketOverride: env["LOCKEDIN_SOCKET"])
    }()

    public var isTestMode: Bool { !root.isEmpty }
    public var hosts: String { root + Identifiers.hostsPath }
    public var pfAnchorFile: String { root + Identifiers.pfAnchorFilePath }
    public var supportDirectory: String { root + Identifiers.supportDirectory }
    public var stateFile: String { root + Identifiers.stateFilePath }
    public var tablesDirectory: String { root + Identifiers.tablesDirectory }
    public var logDirectory: String { root + Identifiers.logDirectory }
    public var logFile: String { root + Identifiers.logFilePath }
}
