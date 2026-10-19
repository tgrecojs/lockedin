import Foundation
import LockedInCore

enum RequestHandler {
    @MainActor
    static func handle(_ request: Request, peer: PeerCredentials, controller: BlockController, daemonStartNs: UInt64)
        async -> Response
    {
        switch request.cmd {
        case .status:
            return .success(status: controller.status())

        case .version:
            let uptime = Double(MonotonicClock.nowNs() &- daemonStartNs) / 1_000_000_000
            return .success(
                version: VersionInfo(
                    version: Identifiers.version, protocolVersion: Identifiers.protocolVersion,
                    uptimeSeconds: uptime, testMode: controller.paths.isTestMode))

        case .start:
            guard let entries = request.entries, let seconds = request.seconds else {
                return .failure(ErrorInfo(code: .badRequest, message: "start needs entries and seconds"))
            }
            if controller.isActive {
                return .failure(
                    ErrorInfo(
                        code: .blockActive,
                        message: "a block is already running (\(BlockDuration.words(controller.currentRemaining)) left)"
                    ))
            }
            if peer.uid != 0, !controller.paths.isTestMode {
                guard let auth = request.auth, !auth.isEmpty else {
                    return .failure(
                        ErrorInfo(
                            code: .unauthorized,
                            message: "starting a block requires authorization (Touch ID or password)"))
                }
                let verified = await Task.detached { AuthVerifier.verify(externalFormBase64: auth) }.value
                guard verified else {
                    return .failure(ErrorInfo(code: .unauthorized, message: "authorization was denied"))
                }
            }
            do {
                return .success(
                    status: try controller.start(entries: entries, seconds: seconds, expand: request.expand ?? true))
            } catch {
                return .failure(error.info)
            }

        case .add:
            guard let entries = request.entries else {
                return .failure(ErrorInfo(code: .badRequest, message: "add needs entries"))
            }
            do {
                let (status, added) = try controller.add(entries: entries)
                return .success(status: status, added: added)
            } catch {
                return .failure(error.info)
            }

        case .extend:
            guard let seconds = request.seconds else {
                return .failure(ErrorInfo(code: .badRequest, message: "extend needs seconds"))
            }
            do {
                return .success(status: try controller.extend(seconds: seconds))
            } catch {
                return .failure(error.info)
            }
        }
    }
}
