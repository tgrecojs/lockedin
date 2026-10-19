import Foundation

struct PeerCredentials: Sendable {
    let uid: uid_t
    let groups: [gid_t]
}

/// Reads the connecting process's uid and groups (LOCAL_PEERCRED). The effective gid alone is
/// not enough: on macOS "admin" is a supplementary group, so the whole list is needed.
enum PeerCredentialsReader {
    private static let solLocal: Int32 = 0  // SOL_LOCAL
    private static let localPeerCred: Int32 = 1  // LOCAL_PEERCRED
    private static let maxGroups = 16  // NGROUPS in struct xucred

    static func read(fd: Int32) -> PeerCredentials? {
        var credentials = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, solLocal, localPeerCred, &credentials, &length) == 0 else { return nil }
        let count = max(0, min(Int(credentials.cr_ngroups), maxGroups))
        var groups = withUnsafeBytes(of: credentials.cr_groups) { raw -> [gid_t] in
            Array(raw.bindMemory(to: gid_t.self).prefix(count))
        }
        if count >= maxGroups, let complete = allGroups(of: credentials.cr_uid) {
            groups = complete
        }
        return PeerCredentials(uid: credentials.cr_uid, groups: groups)
    }

    static func allGroups(of uid: uid_t) -> [gid_t]? {
        guard let record = getpwuid(uid) else { return nil }
        var count: Int32 = 256
        var groups = [Int32](repeating: 0, count: Int(count))
        guard getgrouplist(record.pointee.pw_name, Int32(record.pointee.pw_gid), &groups, &count) >= 0 else {
            return nil
        }
        return groups.prefix(Int(count)).map { gid_t($0) }
    }
}
