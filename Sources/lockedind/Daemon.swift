import Foundation
import LockedInCore

/// lockedind: the root daemon launchd keeps alive. It applies and guards the block,
/// counts it down, and answers the CLI and app over a unix socket.
@main
@MainActor
struct Daemon {
    static var controller: BlockController?
    static var server: Server?
    static var signalSources: [DispatchSourceSignal] = []
    static let startNs = MonotonicClock.nowNs()

    static func main() {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        signal(SIGHUP, SIG_IGN)

        let paths = RuntimePaths.current
        Log.info(
            "lockedind \(Identifiers.version) starting (pid \(getpid()), euid \(geteuid()))"
                + (paths.isTestMode ? " [test mode, root \(paths.root)]" : ""))
        if geteuid() != 0, !paths.isTestMode {
            Log.error("lockedind must run as root (launchd does this); set LOCKEDIN_TEST_ROOT for unprivileged testing")
            exit(77)
        }
        prepareDirectories(paths)
        if !paths.isTestMode { AuthVerifier.registerRightIfNeeded() }

        let controller = BlockController(paths: paths)
        self.controller = controller
        controller.loadAndResume()

        let server = Server(path: paths.socket, allowAnyPeer: paths.isTestMode) { request, peer in
            await RequestHandler.handle(request, peer: peer, controller: controller, daemonStartNs: startNs)
        }
        do {
            try server.start()
        } catch {
            Log.error("cannot start the socket server: \(error)")
            exit(71)
        }
        self.server = server

        controller.hosts.startWatching { controller.hostsChanged() }
        signalSources = [
            makeSignalSource(SIGTERM) {
                controller.persist()
                Log.info("SIGTERM: state saved, exiting; the block stays in place")
                exit(0)
            },
            makeSignalSource(SIGINT) {
                controller.persist()
                Log.info("SIGINT: state saved, exiting; the block stays in place")
                exit(0)
            },
            makeSignalSource(SIGHUP) {
                Log.info("SIGHUP: running an integrity check now")
                controller.forceVerify()
            },
        ]
        Log.info("ready")
        // Keep the real main thread servicing the main queue (dispatchMain() would park it and
        // drain the queue on another thread, which breaks MainActor isolation checks).
        while true {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 60))
        }
    }

    static func makeSignalSource(_ number: Int32, _ handler: @escaping @MainActor () -> Void) -> DispatchSourceSignal {
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { handler() }
        source.resume()
        return source
    }

    static func prepareDirectories(_ paths: RuntimePaths) {
        let fm = FileManager.default
        for directory in [paths.supportDirectory, paths.tablesDirectory, paths.logDirectory] {
            try? fm.createDirectory(
                atPath: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
        }
        guard paths.isTestMode else { return }
        try? fm.createDirectory(
            atPath: (paths.hosts as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? fm.createDirectory(
            atPath: (paths.pfAnchorFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: paths.hosts) {
            let stock =
                "##\n# Host Database (LockedIn test copy)\n##\n127.0.0.1\tlocalhost\n255.255.255.255\tbroadcasthost\n::1             localhost\n"
            try? stock.write(toFile: paths.hosts, atomically: true, encoding: .utf8)
        }
    }
}
