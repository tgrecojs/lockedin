import Foundation
import LockedInCore

/// The user's saved blocklist at ~/.config/lockedin/blocklist.txt, shared by the CLI and the app.
public struct BlocklistStore: Sendable {
    public let path: String

    public init(path: String? = nil) {
        self.path = path ?? Self.defaultPath()
    }

    /// ~/.config/lockedin/blocklist.txt, or LOCKEDIN_BLOCKLIST when set (used by tests).
    public static func defaultPath() -> String {
        if let override = ProcessInfo.processInfo.environment["LOCKEDIN_BLOCKLIST"], !override.isEmpty {
            return override
        }
        return homeDirectory() + "/" + Identifiers.userBlocklistRelativePath
    }

    /// The invoking user's home, even under sudo.
    static func homeDirectory() -> String {
        let environment = ProcessInfo.processInfo.environment
        if let sudoUser = environment["SUDO_USER"], let record = getpwnam(sudoUser), let dir = record.pointee.pw_dir {
            return String(cString: dir)
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: path) }

    public func load() -> [String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return BlocklistFile.parse(text)
    }

    public func save(_ entries: [String]) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try BlocklistFile.serialize(entries).write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Entries saved by the original SelfControl app, if its preferences are still around.
    public static func legacySelfControlEntries() -> [String] {
        guard let defaults = UserDefaults(suiteName: Identifiers.Legacy.preferencesDomain) else { return [] }
        let raw = defaults.array(forKey: Identifiers.Legacy.preferencesBlocklistKey) as? [String] ?? []
        return raw.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// On first run, seeds the blocklist from SelfControl's old list. Returns what was imported.
    @discardableResult
    public func importLegacyIfNeeded() -> [String] {
        guard !exists else { return [] }
        let legacy = Self.legacySelfControlEntries()
        guard !legacy.isEmpty else { return [] }
        try? save(legacy)
        return legacy
    }
}
