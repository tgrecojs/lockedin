/// Who may talk to the daemon: root, or any member of the admin group.
public enum PeerPolicy {
    public static func isAuthorized(uid: UInt32, groups: [UInt32]) -> Bool {
        uid == 0 || groups.contains(Identifiers.adminGroupID)
    }
}
