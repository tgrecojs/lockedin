import Foundation
import LockedInCore

enum ServerError: Error, CustomStringConvertible {
    case socket(Int32)
    case bind(Int32)
    case listen(Int32)
    case pathTooLong(String)

    var description: String {
        switch self {
        case .socket(let e): return "socket(): \(String(cString: strerror(e)))"
        case .bind(let e): return "bind(): \(String(cString: strerror(e)))"
        case .listen(let e): return "listen(): \(String(cString: strerror(e)))"
        case .pathTooLong(let p): return "socket path too long: \(p)"
        }
    }
}

/// Unix-socket server. Accepts admin-only peers and hands each request line to the handler.
@MainActor
final class Server {
    typealias Handler = @MainActor (Request, PeerCredentials) async -> Response

    let path: String
    let allowAnyPeer: Bool
    private let handler: Handler
    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]

    init(path: String, allowAnyPeer: Bool, handler: @escaping Handler) {
        self.path = path
        self.allowAnyPeer = allowAnyPeer
        self.handler = handler
    }

    func start() throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socket(errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw ServerError.pathTooLong(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (i, byte) in bytes.enumerated() { buffer[i] = byte }
            buffer[bytes.count] = 0
        }

        let previousMask = umask(0o117)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousMask)
        guard bound == 0 else {
            let error = errno
            close(fd)
            throw ServerError.bind(error)
        }
        chmod(path, 0o660)
        if geteuid() == 0 { chown(path, 0, gid_t(Identifiers.adminGroupID)) }
        guard listen(fd, 16) == 0 else {
            let error = errno
            close(fd)
            throw ServerError.listen(error)
        }
        Self.setNonBlocking(fd)
        listenFd = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()
        acceptSource = source
        Log.info("listening on \(path)")
    }

    private func acceptPending() {
        while true {
            let clientFd = accept(listenFd, nil, nil)
            if clientFd < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    Log.warn("accept failed: \(String(cString: strerror(errno)))")
                }
                return
            }
            Self.setNonBlocking(clientFd)
            var one: Int32 = 1
            setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

            let credentials = PeerCredentialsReader.read(fd: clientFd) ?? PeerCredentials(uid: uid_t.max, groups: [])
            guard allowAnyPeer || PeerPolicy.isAuthorized(uid: credentials.uid, groups: credentials.groups) else {
                Log.warn("rejected a connection from uid \(credentials.uid) (not an administrator)")
                Connection.writeResponse(
                    fd: clientFd,
                    .failure(ErrorInfo(code: .unauthorized, message: "only administrators can use LockedIn")))
                close(clientFd)
                continue
            }
            let connection = Connection(fd: clientFd, credentials: credentials, handler: handler) { [weak self] fd in
                self?.connections[fd] = nil
            }
            connections[clientFd] = connection
            connection.start()
        }
    }

    static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }
}

/// One client connection: reads a single request line, answers, closes.
@MainActor
final class Connection {
    private let fd: Int32
    private let credentials: PeerCredentials
    private let handler: Server.Handler
    private let onClose: @MainActor (Int32) -> Void
    private var buffer = Data()
    private var readSource: DispatchSourceRead?
    private var idleTimer: DispatchSourceTimer?
    private var awaitingResponse = false
    private var peerGone = false
    private var closed = false

    init(
        fd: Int32, credentials: PeerCredentials, handler: @escaping Server.Handler,
        onClose: @escaping @MainActor (Int32) -> Void
    ) {
        self.fd = fd
        self.credentials = credentials
        self.handler = handler
        self.onClose = onClose
    }

    func start() {
        let descriptor = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.readable() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        readSource = source

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5)
        timer.setEventHandler { [weak self] in
            guard let self, !self.awaitingResponse else { return }
            self.fail(.badRequest, "timed out waiting for a request line")
        }
        timer.resume()
        idleTimer = timer
    }

    private func readable() {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                dropConnection()
                return
            }
            if n == 0 {
                dropConnection()
                return
            }
            if awaitingResponse { continue }  // discard anything after the request line
            buffer.append(chunk, count: n)
            if buffer.count > Identifiers.maxRequestBytes {
                fail(.tooLarge, "request larger than \(Identifiers.maxRequestBytes) bytes")
                return
            }
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                dispatch(line)
                return
            }
        }
    }

    private func dispatch(_ line: Data) {
        awaitingResponse = true
        idleTimer?.cancel()
        idleTimer = nil
        let request: Request
        do {
            request = try NDJSON.decode(Request.self, from: line)
        } catch {
            fail(.badRequest, "could not parse request: \(error)")
            return
        }
        guard request.v == Identifiers.protocolVersion else {
            fail(.badRequest, "unsupported protocol version \(request.v)")
            return
        }
        Task { @MainActor [self] in
            let response = await self.handler(request, self.credentials)
            self.send(response)
        }
    }

    private func fail(_ code: ErrorCode, _ message: String) {
        send(.failure(ErrorInfo(code: code, message: message)))
    }

    private func send(_ response: Response) {
        guard !closed else { return }
        closed = true
        if !peerGone { Self.writeResponse(fd: fd, response) }
        tearDown()
    }

    /// The peer hung up. If a response is still pending it will be discarded.
    private func dropConnection() {
        if awaitingResponse {
            peerGone = true
            readSource?.cancel()
            readSource = nil
            return
        }
        guard !closed else { return }
        closed = true
        tearDown()
    }

    private func tearDown() {
        idleTimer?.cancel()
        idleTimer = nil
        if let source = readSource {
            source.cancel()  // the cancel handler closes the descriptor
            readSource = nil
        }
        onClose(fd)
    }

    /// Writes one response line. The descriptor stays open; the caller closes it.
    nonisolated static func writeResponse(fd: Int32, _ response: Response) {
        guard let data = try? NDJSON.encodeLine(response) else { return }
        let deadline = Date().addingTimeInterval(5)
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                    continue
                }
                if n < 0, errno == EINTR { continue }
                if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    guard Date() < deadline else { return }
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&descriptor, 1, 500)
                    continue
                }
                return
            }
        }
    }
}
