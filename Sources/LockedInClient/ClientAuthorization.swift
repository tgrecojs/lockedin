import Foundation
import LockedInCore
import Security

public enum ClientAuthorizationError: Error, LocalizedError {
    case canceled
    case denied(OSStatus)
    case failed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .canceled: return "authorization canceled"
        case .denied(let status): return "authorization denied (\(status))"
        case .failed(let status): return "authorization failed (\(status))"
        }
    }
}

/// Acquires the "start a block" right from the user (Touch ID or password) and packages it for
/// the daemon. Keep the object alive until the daemon has answered: freeing it invalidates the
/// external form the daemon verifies.
public final class ClientAuthorization {
    private var ref: AuthorizationRef?
    public let externalFormBase64: String

    public init(prompt: String? = nil) throws {
        var created: AuthorizationRef?
        var status = AuthorizationCreate(nil, nil, [], &created)
        guard status == errAuthorizationSuccess, let authRef = created else {
            throw ClientAuthorizationError.failed(status)
        }

        status = Self.withPromptEnvironment(prompt) { environment -> OSStatus in
            Identifiers.authorizationRight.withCString { namePointer -> OSStatus in
                var item = AuthorizationItem(name: namePointer, valueLength: 0, value: nil, flags: 0)
                return withUnsafeMutablePointer(to: &item) { itemPointer -> OSStatus in
                    var rights = AuthorizationRights(count: 1, items: itemPointer)
                    return AuthorizationCopyRights(
                        authRef, &rights, environment, [.interactionAllowed, .extendRights], nil)
                }
            }
        }
        guard status == errAuthorizationSuccess else {
            AuthorizationFree(authRef, [])
            throw status == errAuthorizationCanceled
                ? ClientAuthorizationError.canceled : ClientAuthorizationError.denied(status)
        }

        var form = AuthorizationExternalForm()
        status = AuthorizationMakeExternalForm(authRef, &form)
        guard status == errAuthorizationSuccess else {
            AuthorizationFree(authRef, [])
            throw ClientAuthorizationError.failed(status)
        }
        self.ref = authRef
        self.externalFormBase64 = withUnsafeBytes(of: form) { Data($0) }.base64EncodedString()
    }

    deinit {
        if let ref { AuthorizationFree(ref, []) }
    }

    private static func withPromptEnvironment(
        _ prompt: String?, _ body: (UnsafePointer<AuthorizationEnvironment>?) -> OSStatus
    ) -> OSStatus {
        guard let prompt, !prompt.isEmpty else { return body(nil) }
        var promptBytes = Array(prompt.utf8)
        return promptBytes.withUnsafeMutableBufferPointer { promptBuffer -> OSStatus in
            "prompt".withCString { nameLiteral -> OSStatus in
                var envItem = AuthorizationItem(
                    name: nameLiteral, valueLength: promptBuffer.count,
                    value: UnsafeMutableRawPointer(promptBuffer.baseAddress), flags: 0)
                return withUnsafeMutablePointer(to: &envItem) { envItemPointer -> OSStatus in
                    var environment = AuthorizationEnvironment(count: 1, items: envItemPointer)
                    return withUnsafePointer(to: &environment) { body($0) }
                }
            }
        }
    }
}
