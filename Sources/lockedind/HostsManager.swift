import Foundation
import LockedInCore

/// Owns the LockedIn section of /etc/hosts: writes it atomically, watches for outside edits,
/// and flushes the DNS cache after changes.
@MainActor
final class HostsManager {
    let path: String
    let simulated: Bool
    private var source: DispatchSourceFileSystemObject?
    private var onChange: (@MainActor () -> Void)?
    private var pendingNotify: Task<Void, Never>?

    init(path: String, simulated: Bool) {
        self.path = path
        self.simulated = simulated
    }

    func currentText() -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    func isCurrent(names: [String]) -> Bool {
        currentText().map { HostsFile.isCurrent($0, names: names) } ?? false
    }

    /// Rewrites the file only when it differs from the wanted state. Returns true when it wrote.
    @discardableResult
    func ensure(names: [String]) -> Bool {
        guard let text = currentText() else {
            Log.error("cannot read \(path)")
            return false
        }
        if HostsFile.isCurrent(text, names: names) { return false }
        return write(HostsFile.merged(original: text, names: names))
    }

    /// Removes our section and any stray lines for `names`. Returns true when it wrote.
    @discardableResult
    func remove(names: [String]) -> Bool {
        guard let text = currentText() else {
            Log.error("cannot read \(path)")
            return false
        }
        let cleaned = HostsFile.strip(text, names: names)
        if cleaned == text { return false }
        return write(cleaned)
    }

    @discardableResult
    func stripAll() -> Bool { remove(names: []) }

    private func write(_ text: String) -> Bool {
        let fm = FileManager.default
        let temporary = path + ".lockedin.tmp"
        do {
            var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o644]
            if let existing = try? fm.attributesOfItem(atPath: path) {
                for key in [FileAttributeKey.posixPermissions, .ownerAccountID, .groupOwnerAccountID] {
                    if let value = existing[key] { attributes[key] = value }
                }
            }
            try text.write(toFile: temporary, atomically: false, encoding: .utf8)
            try? fm.setAttributes(attributes, ofItemAtPath: temporary)
            guard rename(temporary, path) == 0 else {
                Log.error("could not replace \(path): \(String(cString: strerror(errno)))")
                try? fm.removeItem(atPath: temporary)
                return false
            }
            Log.info("wrote \(path) (\(text.utf8.count) bytes)")
            rearmWatcher()
            return true
        } catch {
            Log.error("could not write \(path): \(error)")
            return false
        }
    }

    func flushDNSCache() {
        guard !simulated else { return }
        _ = Shell.run("/usr/bin/dscacheutil", ["-flushcache"], timeout: 5)
        _ = Shell.run("/usr/bin/killall", ["-HUP", "mDNSResponder"], timeout: 5)
    }

    func startWatching(_ handler: @escaping @MainActor () -> Void) {
        onChange = handler
        rearmWatcher()
    }

    private func rearmWatcher() {
        source?.cancel()
        source = nil
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            Log.warn("cannot watch \(path): \(String(cString: strerror(errno)))")
            return
        }
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke], queue: .main)
        newSource.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = self.source?.data ?? []
            self.fileChanged(replaced: !flags.intersection([.delete, .rename, .revoke]).isEmpty)
        }
        newSource.setCancelHandler { close(fd) }
        newSource.resume()
        source = newSource
    }

    private func fileChanged(replaced: Bool) {
        pendingNotify?.cancel()
        pendingNotify = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(replaced ? 600 : 300))
            guard !Task.isCancelled, let self else { return }
            if replaced { self.rearmWatcher() }
            self.onChange?()
        }
    }
}
