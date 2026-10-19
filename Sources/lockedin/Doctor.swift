import ArgumentParser
import Foundation
import LockedInClient
import LockedInCore

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check that LockedIn is installed and healthy.")

    func run() throws {
        let fm = FileManager.default
        let paths = RuntimePaths.current
        var problems = 0
        func row(_ label: String, _ value: String, ok: Bool = true) {
            print("  \(label.padding(toLength: 18, withPad: " ", startingAt: 0)) \(ok ? "" : "!! ")\(value)")
            if !ok { problems += 1 }
        }

        print("LockedIn doctor (cli \(Identifiers.version))")
        if paths.isTestMode { print("  test mode: paths relocated under \(paths.root)") }

        let plistPresent = fm.fileExists(atPath: Identifiers.launchdPlistPath)
        let binaryPresent = fm.fileExists(atPath: Identifiers.daemonBinaryPath)
        if !paths.isTestMode {
            row("launchd plist", plistPresent ? "present" : "missing (run: sudo make install)", ok: plistPresent)
            row("daemon binary", binaryPresent ? "present" : "missing", ok: binaryPresent)
        }

        var live: StatusReport?
        do {
            let version = try SocketClient().send(Request(cmd: .version)).version
            let versionText = version.map { "\($0.version), up \(BlockDuration.words($0.uptimeSeconds))" } ?? "unknown"
            row("daemon", "answering (\(versionText))")
            if let version, version.version != Identifiers.version {
                row("version match", "cli \(Identifiers.version) vs daemon \(version.version): reinstall", ok: false)
            } else {
                row("version match", "ok")
            }
            live = try SocketClient().send(Request(cmd: .status)).status
        } catch {
            row("daemon", "not answering: \(error.localizedDescription)", ok: false)
        }

        if let saved = StateFileReader.read() {
            let text =
                saved.state == .active
                ? "active, \(BlockDuration.words(saved.block?.remainingSeconds ?? 0)) left (saved \(Output.relative(saved.savedAt)))"
                : "idle (saved \(Output.relative(saved.savedAt)))"
            row("state file", text)
        } else {
            row(
                "state file", fm.fileExists(atPath: paths.stateFile) ? "unreadable" : "missing",
                ok: live != nil ? false : true)
        }

        let hostsText = (try? String(contentsOfFile: paths.hosts, encoding: .utf8)) ?? ""
        let hasSection = HostsFile.containsSection(hostsText)
        if let live {
            if live.isActive {
                let expected = HostsFile.isCurrent(hostsText, names: live.hostsNames)
                row(
                    "hosts section",
                    expected
                        ? "present and correct (\(live.hostsNames.count) names)"
                        : "wrong or missing (daemon re-applies every 15 s)", ok: expected)
                if let pf = live.pf {
                    let text =
                        pf.simulated
                        ? "simulated (test mode)"
                        : (pf.healthy ? "enabled, anchor loaded, tables ok" : Output.describe(pf))
                    row("pf", text, ok: pf.simulated || pf.healthy)
                }
            } else {
                row(
                    "hosts section", hasSection ? "present while idle (daemon should remove it)" : "none (idle)",
                    ok: !hasSection)
            }
        } else {
            row("hosts section", hasSection ? "present" : "none")
        }
        if hostsText.contains(Identifiers.legacyHostsBeginMarker) {
            row("legacy hosts", "SelfControl section still present (install cleans it)", ok: false)
        }

        if !paths.isTestMode {
            let leftovers = [
                Identifiers.Legacy.launchdPlistPath, Identifiers.Legacy.helperPath,
                Identifiers.Legacy.oldLaunchdPlistPath,
                Identifiers.Legacy.oldHelperPath, Identifiers.Legacy.pfAnchorFilePath, Identifiers.Legacy.pfTokenPath,
                Identifiers.Legacy.lockPath,
            ].filter { fm.fileExists(atPath: $0) }
            row(
                "old SelfControl",
                leftovers.isEmpty ? "no leftovers" : "leftovers: " + leftovers.joined(separator: " "),
                ok: leftovers.isEmpty)
        }

        let store = BlocklistStore()
        row(
            "blocklist",
            store.exists ? "\(store.path) (\(store.load().count) sites)" : "\(store.path) (not created yet)")

        if !paths.isTestMode {
            print("  note: System Settings › General › Login Items & Extensions must keep LockedIn's daemon allowed.")
        }
        print(problems == 0 ? "Everything looks fine." : "\(problems) problem(s) found.")
        if problems > 0 { throw ExitCode.failure }
    }
}
