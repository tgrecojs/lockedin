import Foundation
import LockedInCore
import os

/// Timestamped lines on stderr (launchd sends them to /Library/Logs/LockedIn/lockedind.log) plus os_log.
enum Log {
    private static let logger = Logger(subsystem: Identifiers.logSubsystem, category: "daemon")
    private static let lock = NSLock()

    static func info(_ message: String) {
        write("INFO", message)
        logger.info("\(message, privacy: .public)")
    }

    static func warn(_ message: String) {
        write("WARN", message)
        logger.warning("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        write("ERROR", message)
        logger.error("\(message, privacy: .public)")
    }

    private static func write(_ level: String, _ message: String) {
        let line = "\(Date().formatted(.iso8601)) [\(level)] \(message)\n"
        lock.withLock { FileHandle.standardError.write(Data(line.utf8)) }
    }
}
