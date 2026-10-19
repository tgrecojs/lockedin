import ArgumentParser
import Foundation
import LockedInClient
import LockedInCore

struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install the daemon, CLI, and app (needs sudo). Also removes SelfControl leftovers.")

    @Option(
        name: .customLong("from"),
        help: "Directory holding the built lockedind and lockedin binaries (default: next to this executable).")
    var from: String?

    @Option(name: .customLong("app"), help: "Path to a built LockedIn.app to copy into /Applications.")
    var app: String?

    @Flag(name: .customLong("no-cli"), help: "Do not install /usr/local/bin/lockedin.")
    var noCLI = false

    func run() throws {
        let directory =
            from
            ?? (URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
                .path)
        try Installer().install(from: directory, appPath: app, installCLI: !noCLI)
    }
}

struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove LockedIn (needs sudo). Refused while a block is running.")

    @Flag(name: .customLong("keep-app"), help: "Leave /Applications/LockedIn.app in place.")
    var keepApp = false

    func run() throws {
        try Installer().uninstall(keepApp: keepApp)
    }
}

struct Installer {
    let fm = FileManager.default

    func say(_ message: String) { print("  " + message) }

    func requireRoot() throws {
        guard geteuid() == 0 else {
            throw CLIError("this needs root: sudo lockedin \(CommandLine.arguments.dropFirst().joined(separator: " "))")
        }
    }

    @discardableResult
    func run(_ path: String, _ arguments: [String]) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (false, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus == 0,
            String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    @discardableResult
    func launchctl(_ arguments: [String]) -> (ok: Bool, output: String) { run("/bin/launchctl", arguments) }

    // MARK: install

    func install(from directory: String, appPath: String?, installCLI: Bool) throws {
        try requireRoot()
        let daemonSource = directory + "/" + Identifiers.daemonExecutableName
        let cliSource = directory + "/" + Identifiers.cliExecutableName
        guard fm.isExecutableFile(atPath: daemonSource) else {
            throw CLIError("\(daemonSource) not found. Build first: swift build -c release")
        }

        print("Cleaning up the old SelfControl app, if present")
        cleanUpSelfControl()

        print("Installing the LockedIn daemon")
        if launchctl(["print", "system/\(Identifiers.daemonLabel)"]).ok {
            launchctl(["bootout", "system/\(Identifiers.daemonLabel)"])
            say("stopped the running daemon (a running block resumes after the upgrade)")
            usleep(500_000)
        }
        for directory in [Identifiers.supportDirectory, Identifiers.tablesDirectory, Identifiers.logDirectory] {
            try fm.createDirectory(
                atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            try fm.setAttributes([.ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: directory)
        }
        try installExecutable(daemonSource, to: Identifiers.daemonBinaryPath)
        say("daemon at \(Identifiers.daemonBinaryPath)")
        if installCLI {
            try fm.createDirectory(
                atPath: (Identifiers.cliInstallPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try installExecutable(cliSource, to: Identifiers.cliInstallPath)
            say("cli at \(Identifiers.cliInstallPath)")
        }

        try fm.createDirectory(
            atPath: (Identifiers.pfAnchorFilePath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        if !fm.fileExists(atPath: Identifiers.pfAnchorFilePath) {
            try PFAnchor.render(ports: []).write(
                toFile: Identifiers.pfAnchorFilePath, atomically: true, encoding: .utf8)
        }
        try fm.setAttributes(
            [.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0],
            ofItemAtPath: Identifiers.pfAnchorFilePath)
        let syntax = run("/sbin/pfctl", ["-n", "-a", Identifiers.pfAnchor, "-f", Identifiers.pfAnchorFilePath])
        if syntax.ok {
            say("pf anchor file at \(Identifiers.pfAnchorFilePath) (syntax ok)")
        } else {
            say("warning: pfctl rejected the anchor file: \(syntax.output)")
        }

        try writeLaunchdPlist()
        let lint = run("/usr/bin/plutil", ["-lint", Identifiers.launchdPlistPath])
        guard lint.ok else { throw CLIError("the generated launchd plist is invalid: \(lint.output)") }
        say("launchd plist at \(Identifiers.launchdPlistPath)")

        launchctl(["enable", "system/\(Identifiers.daemonLabel)"])
        let boot = launchctl(["bootstrap", "system", Identifiers.launchdPlistPath])
        guard boot.ok else {
            throw CLIError(
                "launchctl bootstrap failed: \(boot.output)\nIf System Settings › General › Login Items & Extensions lists LockedIn, allow it there and run the install again."
            )
        }
        var version: VersionInfo?
        for _ in 0..<40 {
            if let v = try? SocketClient().send(Request(cmd: .version)).version { version = v; break }
            usleep(250_000)
        }
        guard let version else {
            throw CLIError("the daemon did not answer within 10 s; see \(Identifiers.logFilePath)")
        }
        say("daemon \(version.version) is running")

        if let appPath {
            print("Installing the app")
            try installApp(from: appPath)
        }

        print("Done. Next: lockedin start 25m youtube.com   (or open LockedIn from Applications)")
        print("macOS lists the daemon under System Settings › General › Login Items & Extensions; leave it allowed.")
    }

    func installExecutable(_ source: String, to destination: String) throws {
        let temporary = destination + ".new"
        try? fm.removeItem(atPath: temporary)
        try fm.copyItem(atPath: source, toPath: temporary)
        try fm.setAttributes(
            [.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: temporary)
        if !run("/usr/bin/codesign", ["--verify", temporary]).ok {
            run("/usr/bin/codesign", ["--force", "--sign", "-", temporary])
        }
        guard rename(temporary, destination) == 0 else {
            throw CLIError("could not install \(destination): \(String(cString: strerror(errno)))")
        }
    }

    func writeLaunchdPlist() throws {
        let binary = Identifiers.daemonBinaryPath
        let plist: [String: Any] = [
            "Label": Identifiers.daemonLabel,
            "Program": binary,
            "ProgramArguments": [binary],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 5,
            "ExitTimeOut": 15,
            "ProcessType": "Standard",
            "EnvironmentVariables": ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            "StandardOutPath": Identifiers.logFilePath,
            "StandardErrorPath": Identifiers.logFilePath,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: Identifiers.launchdPlistPath))
        try fm.setAttributes(
            [.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0],
            ofItemAtPath: Identifiers.launchdPlistPath)
    }

    func installApp(from source: String) throws {
        guard fm.fileExists(atPath: source + "/Contents/MacOS/LockedIn") else {
            throw CLIError("\(source) is not a LockedIn app bundle (build it with: make app)")
        }
        let destination = Identifiers.appInstallPath
        if fm.fileExists(atPath: destination) {
            run("/usr/bin/pkill", ["-x", "LockedIn"])
            try fm.removeItem(atPath: destination)
        }
        let copy = run("/usr/bin/ditto", [source, destination])
        guard copy.ok else { throw CLIError("could not copy the app: \(copy.output)") }
        if let user = ProcessInfo.processInfo.environment["SUDO_USER"], let record = getpwnam(user) {
            run("/usr/sbin/chown", ["-R", "\(record.pointee.pw_uid):\(record.pointee.pw_gid)", destination])
        }
        say("app at \(destination)")
    }

    // MARK: SelfControl cleanup

    func cleanUpSelfControl() {
        let legacy = Identifiers.Legacy.self
        var found = false
        for label in [legacy.daemonLabel, legacy.oldDaemonLabel] where launchctl(["print", "system/\(label)"]).ok {
            launchctl(["bootout", "system/\(label)"])
            say("stopped SelfControl's daemon \(label)")
            found = true
        }
        for path in [
            legacy.launchdPlistPath, legacy.helperPath, legacy.oldLaunchdPlistPath, legacy.oldHelperPath,
            legacy.pfAnchorFilePath, legacy.pfTokenPath, legacy.lockPath,
        ] where fm.fileExists(atPath: path) {
            if (try? fm.removeItem(atPath: path)) != nil { say("removed \(path)"); found = true }
        }
        if let pfConf = try? String(contentsOfFile: Identifiers.pfConfPath, encoding: .utf8),
            pfConf.contains(legacy.pfAnchorName)
        {
            let cleaned = pfConf.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.contains(legacy.pfAnchorName) }
                .joined(separator: "\n")
            let temporary = Identifiers.pfConfPath + ".lockedin.tmp"
            if (try? cleaned.write(toFile: temporary, atomically: false, encoding: .utf8)) != nil,
                run("/sbin/pfctl", ["-n", "-f", temporary]).ok, rename(temporary, Identifiers.pfConfPath) == 0
            {
                run("/sbin/pfctl", ["-f", Identifiers.pfConfPath])
                say("removed SelfControl's anchor lines from \(Identifiers.pfConfPath)")
                found = true
            } else {
                try? fm.removeItem(atPath: temporary)
                say("warning: could not clean \(Identifiers.pfConfPath); remove the org.eyebeam lines by hand")
            }
        }
        if let hosts = try? String(contentsOfFile: Identifiers.hostsPath, encoding: .utf8),
            hosts.contains(legacy.pfAnchorName) == false,
            hosts.contains(Identifiers.legacyHostsBeginMarker)
        {
            let stripped = HostsFile.strip(hosts)
            let temporary = Identifiers.hostsPath + ".lockedin.tmp"
            if (try? stripped.write(toFile: temporary, atomically: false, encoding: .utf8)) != nil {
                try? fm.setAttributes(
                    [.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: temporary)
                if rename(temporary, Identifiers.hostsPath) == 0 {
                    run("/usr/bin/dscacheutil", ["-flushcache"])
                    run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
                    say("removed SelfControl's section from /etc/hosts")
                    found = true
                }
            }
        }
        if let names = try? fm.contentsOfDirectory(atPath: legacy.settingsDirectory) {
            for name in names where name.hasPrefix(".") && name.hasSuffix(".plist") && name.count == 47 {
                let path = legacy.settingsDirectory + "/" + name
                guard let data = fm.contents(atPath: path),
                    let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                    plist["BlockIsRunning"] != nil
                else { continue }
                if (try? fm.removeItem(atPath: path)) != nil {
                    say("removed SelfControl's settings file \(path)"); found = true
                }
            }
        }
        if !found { say("nothing to clean up") }
    }

    // MARK: uninstall

    func uninstall(keepApp: Bool) throws {
        try requireRoot()
        if let status = try? SocketClient().send(Request(cmd: .status)).status, status.isActive {
            throw CLIError(
                "a block is running (\(BlockDuration.words(status.remainingSeconds ?? 0)) left). Uninstall is refused until it ends."
            )
        }
        if let saved = StateFileReader.read(), saved.state == .active, let block = saved.block {
            throw CLIError(
                "the saved state says a block is running (\(BlockDuration.words(block.remainingSeconds)) left). Uninstall is refused until it ends."
            )
        }

        print("Removing LockedIn")
        if launchctl(["print", "system/\(Identifiers.daemonLabel)"]).ok {
            launchctl(["bootout", "system/\(Identifiers.daemonLabel)"])
            say("stopped the daemon")
        }
        if let hosts = try? String(contentsOfFile: Identifiers.hostsPath, encoding: .utf8),
            HostsFile.containsSection(hosts)
        {
            let temporary = Identifiers.hostsPath + ".lockedin.tmp"
            try HostsFile.strip(hosts).write(toFile: temporary, atomically: false, encoding: .utf8)
            try fm.setAttributes(
                [.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: temporary)
            if rename(temporary, Identifiers.hostsPath) == 0 {
                run("/usr/bin/dscacheutil", ["-flushcache"])
                run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
                say("removed the hosts section")
            }
        }
        run("/sbin/pfctl", ["-q", "-a", Identifiers.pfAnchor, "-F", "rules"])
        run("/sbin/pfctl", ["-q", "-a", Identifiers.pfAnchor, "-F", "Tables"])
        if let saved = StateFileReader.read(), let tokens = saved.block?.pfTokens {
            for token in tokens { run("/sbin/pfctl", ["-X", token]) }
        }
        var paths = [
            Identifiers.launchdPlistPath, Identifiers.daemonBinaryPath, Identifiers.pfAnchorFilePath,
            Identifiers.socketPath, Identifiers.supportDirectory, Identifiers.logDirectory, Identifiers.cliInstallPath,
        ]
        if !keepApp { paths.append(Identifiers.appInstallPath) }
        for path in paths where fm.fileExists(atPath: path) {
            if path == Identifiers.appInstallPath { run("/usr/bin/pkill", ["-x", "LockedIn"]) }
            do {
                try fm.removeItem(atPath: path)
                say("removed \(path)")
            } catch {
                say("could not remove \(path): \(error.localizedDescription)")
            }
        }
        print("Done. Your blocklist at ~/.config/lockedin was left in place.")
    }
}
