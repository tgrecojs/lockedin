import Foundation
import LockedInCore

public enum ClientError: Error, LocalizedError, Equatable {
    case daemonNotRunning
    case permissionDenied
    case timeout
    case connectionFailed(String)
    case protocolError(String)
    case daemon(ErrorInfo)

    public var errorDescription: String? {
        switch self {
        case .daemonNotRunning:
            return "the LockedIn daemon is not running (install it with: sudo make install)"
        case .permissionDenied:
            return "permission denied: only administrators can talk to the LockedIn daemon"
        case .timeout:
            return "the LockedIn daemon did not answer in time"
        case .connectionFailed(let detail):
            return "could not reach the LockedIn daemon: \(detail)"
        case .protocolError(let detail):
            return "unexpected reply from the daemon: \(detail)"
        case .daemon(let info):
            return info.message
        }
    }
}

/// Synchronous client for the daemon's unix socket. One request per connection.
public struct SocketClient: Sendable {
    public var path: String

    public init(path: String = RuntimePaths.current.socket) {
        self.path = path
    }

    public func send(_ request: Request, timeout: TimeInterval = 2) throws -> Response {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.connectionFailed(Self.errnoText()) }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw ClientError.connectionFailed("socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            for (i, byte) in pathBytes.enumerated() { buffer[i] = byte }
            buffer[pathBytes.count] = 0
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        if rc != 0 {
            switch errno {
            case ENOENT, ECONNREFUSED: throw ClientError.daemonNotRunning
            case EACCES, EPERM: throw ClientError.permissionDenied
            default: throw ClientError.connectionFailed(Self.errnoText())
            }
        }

        let payload = try NDJSON.encodeLine(request)
        try payload.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
                if n < 0 {
                    if errno == EAGAIN { throw ClientError.timeout }
                    throw ClientError.connectionFailed(Self.errnoText())
                }
                sent += n
            }
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        reading: while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EAGAIN { throw ClientError.timeout }
                throw ClientError.connectionFailed(Self.errnoText())
            }
            if n == 0 { break }
            buffer.append(chunk, count: n)
            if chunk[..<n].contains(0x0A) { break reading }
            if buffer.count > Identifiers.maxRequestBytes * 4 { throw ClientError.protocolError("reply too large") }
        }

        guard let newline = buffer.firstIndex(of: 0x0A) else {
            throw ClientError.protocolError(buffer.isEmpty ? "empty reply" : "unterminated reply")
        }
        let line = Data(buffer[..<newline])
        let response: Response
        do {
            response = try NDJSON.decode(Response.self, from: line)
        } catch {
            throw ClientError.protocolError(String(decoding: line.prefix(200), as: UTF8.self))
        }
        if !response.ok {
            throw ClientError.daemon(response.error ?? ErrorInfo(code: .internalError, message: "unknown daemon error"))
        }
        return response
    }

    private static func errnoText() -> String {
        String(cString: strerror(errno))
    }
}
