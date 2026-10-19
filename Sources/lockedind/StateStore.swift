import Foundation
import LockedInCore

/// Atomic JSON persistence for the daemon state, with a backup copy and corrupt-file quarantine.
@MainActor
final class StateStore {
    let path: String
    var backupPath: String { path + ".bak" }

    init(path: String) {
        self.path = path
    }

    enum LoadResult {
        case document(StateDocument)
        case missing
        case corrupt
    }

    func load() -> LoadResult {
        let fm = FileManager.default
        if let data = fm.contents(atPath: path) {
            if let document = decode(data) { return .document(document) }
            let quarantine = path + ".corrupt-\(Int(Date().timeIntervalSince1970))"
            Log.error("state file is unreadable; moving it to \(quarantine)")
            try? fm.moveItem(atPath: path, toPath: quarantine)
            if let backup = fm.contents(atPath: backupPath), let document = decode(backup) {
                Log.warn("recovered state from \(backupPath)")
                return .document(document)
            }
            return .corrupt
        }
        if let backup = fm.contents(atPath: backupPath), let document = decode(backup) {
            Log.warn("state file missing; recovered from \(backupPath)")
            return .document(document)
        }
        return .missing
    }

    func save(_ document: StateDocument) {
        let fm = FileManager.default
        do {
            let encoder = NDJSON.makeEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            let data = try encoder.encode(document)
            let directory = (path as NSString).deletingLastPathComponent
            try fm.createDirectory(
                atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            let temporary = path + ".tmp"
            try data.write(to: URL(fileURLWithPath: temporary))
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: temporary)
            if fm.fileExists(atPath: path) {
                try? fm.removeItem(atPath: backupPath)
                try? fm.copyItem(atPath: path, toPath: backupPath)
            }
            guard rename(temporary, path) == 0 else {
                Log.error("could not replace state file: \(String(cString: strerror(errno)))")
                return
            }
        } catch {
            Log.error("could not save state: \(error)")
        }
    }

    private func decode(_ data: Data) -> StateDocument? {
        guard let document = try? NDJSON.makeDecoder().decode(StateDocument.self, from: data) else { return nil }
        guard document.schema == StateDocument.currentSchema else {
            Log.error("state schema \(document.schema) is not supported")
            return nil
        }
        return document
    }
}
