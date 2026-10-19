import Foundation
import LockedInCore
import Security

/// The "start a block" right: registered once by the daemon (root), verified on every start.
enum AuthVerifier {
    static let rule = "authenticate-admin"

    static func registerRightIfNeeded() {
        let right = Identifiers.authorizationRight
        if AuthorizationRightGet(right, nil) == errAuthorizationSuccess { return }
        var created: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &created) == errAuthorizationSuccess, let ref = created else {
            Log.error("AuthorizationCreate failed; cannot register \(right)")
            return
        }
        defer { AuthorizationFree(ref, []) }
        let status = AuthorizationRightSet(
            ref, right, rule as CFString, Identifiers.authorizationPrompt as CFString, nil, nil)
        if status == errAuthorizationSuccess {
            Log.info("registered authorization right \(right) (rule \(rule))")
        } else {
            Log.error("AuthorizationRightSet(\(right)) failed: \(status)")
        }
    }

    /// Verifies that the client's authorization carries the right. May show the system prompt
    /// if the client skipped it, so call this off the main thread.
    static func verify(externalFormBase64: String) -> Bool {
        guard let data = Data(base64Encoded: externalFormBase64),
            data.count == MemoryLayout<AuthorizationExternalForm>.size
        else { return false }
        var form = AuthorizationExternalForm()
        withUnsafeMutableBytes(of: &form) { $0.copyBytes(from: data) }
        var created: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&form, &created) == errAuthorizationSuccess, let ref = created else {
            return false
        }
        defer { AuthorizationFree(ref, []) }
        let status = Identifiers.authorizationRight.withCString { namePointer -> OSStatus in
            var item = AuthorizationItem(name: namePointer, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPointer -> OSStatus in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                return AuthorizationCopyRights(ref, &rights, nil, [.extendRights, .interactionAllowed], nil)
            }
        }
        return status == errAuthorizationSuccess
    }
}
