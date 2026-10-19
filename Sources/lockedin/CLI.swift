import ArgumentParser
import Foundation
import LockedInClient
import LockedInCore

struct CLIError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

@main
struct LockedInCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lockedin",
        abstract: "Block distracting websites for a set time. Once a block starts, nothing stops it early.",
        discussion: """
            Examples:
              lockedin start 2h youtube.com reddit.com   block two sites for two hours
              lockedin start 25m                         block the saved blocklist for 25 minutes
              lockedin status --watch                    live countdown
              lockedin add x.com                         add a site to the running block
              lockedin list add news.ycombinator.com     save a site to the blocklist

            The saved blocklist lives at ~/.config/lockedin/blocklist.txt.
            """,
        version: Identifiers.version,
        subcommands: [
            Start.self, Status.self, Add.self, Extend.self, ListCommand.self, Preview.self,
            Doctor.self, Install.self, Uninstall.self, IdentifiersCommand.self, VersionCommand.self,
        ],
        defaultSubcommand: Status.self)
}

// MARK: - Shared helpers

enum Client {
    static func send(_ request: Request, timeout: TimeInterval = 2) throws -> Response {
        try SocketClient().send(request, timeout: timeout)
    }

    /// Live status from the daemon, or the last saved state when the daemon is unreachable.
    static func status() throws -> (report: StatusReport, live: Bool) {
        do {
            guard let report = try send(Request(cmd: .status)).status else {
                throw CLIError("the daemon sent no status")
            }
            return (report, true)
        } catch ClientError.daemonNotRunning, ClientError.permissionDenied, ClientError.timeout {
            if let saved = StateFileReader.read() {
                let report: StatusReport
                if saved.state == .active, let block = saved.block {
                    report = StatusReport(
                        state: .active, remainingSeconds: block.remainingSeconds,
                        expectedEnd: saved.savedAt.addingTimeInterval(block.remainingSeconds),
                        startedAt: block.startedAt,
                        initialSeconds: block.initialSeconds, entries: block.plan.entries,
                        hostsNames: block.plan.hostsNames,
                        pfNames: block.plan.pfNames, ports: block.plan.ports, ipCount: block.resolved.count,
                        lastBlockEndedAt: saved.lastBlockEndedAt, daemonVersion: saved.daemonVersion)
                } else {
                    report = StatusReport(
                        state: .idle, lastBlockEndedAt: saved.lastBlockEndedAt, daemonVersion: saved.daemonVersion)
                }
                return (report, false)
            }
            throw CLIError(
                "LockedIn's daemon is not running and no saved state exists. Install it with: sudo make install")
        }
    }

    static func parseDuration(_ text: String) throws -> Int {
        guard let seconds = BlockDuration.parse(text) else {
            throw CLIError("\"\(text)\" is not a duration; try 25m, 2h, 1h30m, or a number of minutes")
        }
        return seconds
    }

    static func validate(_ entries: [String]) throws {
        for (index, entry) in entries.enumerated() {
            do {
                _ = try BlockEntry.parse(entry)
            } catch {
                throw CLIError("entry \(index + 1): \(error)")
            }
        }
    }

    /// Touch ID / password, unless running as root or in test mode.
    static func authorize(prompt: String) throws -> ClientAuthorization? {
        if geteuid() == 0 || RuntimePaths.current.isTestMode { return nil }
        do {
            return try ClientAuthorization(prompt: prompt)
        } catch ClientAuthorizationError.canceled {
            throw CLIError("canceled")
        }
    }
}

enum Output {
    static func status(_ report: StatusReport, live: Bool) -> String {
        var lines: [String] = []
        switch report.state {
        case .idle:
            var line = "LockedIn: idle"
            if let ended = report.lastBlockEndedAt { line += " (last block ended \(relative(ended)))" }
            lines.append(line)
        case .active:
            let remaining = report.remainingSeconds ?? 0
            var line = "LockedIn: ACTIVE — \(BlockDuration.words(remaining)) left"
            if let end = report.expectedEnd { line += ", ends at \(timeOfDay(end))" }
            lines.append(line)
            lines.append("  sites: " + report.entries.joined(separator: " "))
            lines.append(
                "  \(report.hostsNames.count) names in /etc/hosts, \(report.ipCount) addresses in the firewall"
                    + (report.ports.isEmpty ? "" : ", ports \(report.ports.map(String.init).joined(separator: ","))"))
            if live {
                let hosts = report.hostsOK.map { $0 ? "ok" : "DRIFTED" } ?? "unchecked"
                let pf =
                    report.pf.map { $0.simulated ? "simulated" : ($0.healthy ? "ok" : "DRIFTED (\(describe($0)))") }
                    ?? "unchecked"
                lines.append("  hosts: \(hosts)   pf: \(pf)")
            }
        }
        if !live { lines.append("  (daemon unreachable; showing the last saved state — run `lockedin doctor`)") }
        return lines.joined(separator: "\n")
    }

    static func describe(_ pf: PFStatus) -> String {
        [
            pf.enabled ? nil : "disabled", pf.mainAnchorPresent ? nil : "main anchor missing",
            pf.anchorLoaded ? nil : "anchor not loaded", pf.tablesOK ? nil : "tables incomplete",
        ]
        .compactMap { $0 }.joined(separator: ", ")
    }

    static func relative(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        return BlockDuration.words(seconds) + " ago"
    }

    static func timeOfDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
        return formatter.string(from: date)
    }

    static func json<T: Encodable>(_ value: T) throws -> String {
        try NDJSON.prettyJSON(value)
    }
}

// MARK: - Commands

struct Start: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start a block. It cannot be stopped early.")

    @Argument(help: "How long: 25m, 2h, 1h30m, or a number of minutes.")
    var duration: String

    @Argument(
        help:
            "Sites to block (youtube.com, example.com:8080, 203.0.113.0/24, ~reddit.com). Without any, the saved blocklist is used."
    )
    var entries: [String] = []

    @Option(name: .customLong("list"), help: "Read sites from this file instead of the saved blocklist.")
    var listPath: String?

    @Flag(name: .customLong("no-expand"), help: "Do not add www./m. variants or known aliases.")
    var noExpand = false

    @Flag(help: "Print the resulting status as JSON.")
    var json = false

    func run() throws {
        let seconds = try Client.parseDuration(duration)
        var sites = entries
        if sites.isEmpty {
            let store = BlocklistStore(path: listPath)
            let imported = store.importLegacyIfNeeded()
            if !imported.isEmpty {
                print("Imported \(imported.count) site(s) from SelfControl's old preferences into \(store.path).")
            }
            sites = store.load()
            guard !sites.isEmpty else {
                throw ValidationError("nothing to block: pass sites, or save some with `lockedin list add youtube.com`")
            }
        }
        try Client.validate(sites)

        let prompt =
            "Start a \(BlockDuration.words(Double(seconds))) block of \(sites.count) site\(sites.count == 1 ? "" : "s")? It cannot be stopped early."
        let authorization = try Client.authorize(prompt: prompt)
        let request = Request(
            cmd: .start, entries: sites, seconds: seconds, expand: !noExpand, auth: authorization?.externalFormBase64)
        let response = try Client.send(request, timeout: 120)
        withExtendedLifetime(authorization) {}
        guard let status = response.status else { throw CLIError("the daemon sent no status") }

        if json {
            print(try Output.json(status))
            return
        }
        print(
            "Block started for \(BlockDuration.words(Double(seconds)))"
                + (status.expectedEnd.map { ", ends at \(Output.timeOfDay($0))" } ?? "") + ".")
        print("  sites: " + status.entries.joined(separator: " "))
        print(
            "  \(status.hostsNames.count) names go in /etc/hosts; firewall addresses fill in over the next few seconds."
        )
        print("There is no stop button.")
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show whether a block is running and how long is left.")

    @Flag(help: "Print JSON.")
    var json = false

    @Flag(help: "Refresh every second until the block ends.")
    var watch = false

    func run() throws {
        while true {
            let (report, live) = try Client.status()
            if json {
                print(try Output.json(report))
            } else {
                print(Output.status(report, live: live))
            }
            guard watch, report.isActive else {
                if !live { throw ExitCode(2) }
                return
            }
            sleep(1)
            print()
        }
    }
}

struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Add sites to the running block (sites can never be removed).")

    @Argument(help: "Sites to add.")
    var entries: [String]

    @Flag(help: "Also save them to the blocklist for next time.")
    var save = false

    func run() throws {
        try Client.validate(entries)
        let response = try Client.send(Request(cmd: .add, entries: entries), timeout: 30)
        let added = response.added ?? []
        if added.isEmpty {
            print("Nothing new: those sites were already in the block.")
        } else {
            print("Added to the running block: " + added.joined(separator: " "))
        }
        if save {
            let store = BlocklistStore()
            var saved = store.load()
            for entry in entries where !saved.contains(where: { $0.lowercased() == entry.lowercased() }) {
                saved.append(entry)
            }
            try store.save(saved)
            print("Saved to \(store.path).")
        }
    }
}

struct Extend: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Add time to the running block.")

    @Argument(help: "How much longer: 15m, 1h, …")
    var duration: String

    func run() throws {
        let seconds = try Client.parseDuration(duration)
        let response = try Client.send(Request(cmd: .extend, seconds: seconds))
        guard let status = response.status, let remaining = status.remainingSeconds else {
            throw CLIError("the daemon sent no status")
        }
        print(
            "Extended. \(BlockDuration.words(remaining)) left"
                + (status.expectedEnd.map { ", ends at \(Output.timeOfDay($0))" } ?? "") + ".")
    }
}

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Show or edit the saved blocklist used by `lockedin start` and the app.",
        subcommands: [ListAdd.self, ListRemove.self, ListPath.self])

    func run() throws {
        let store = BlocklistStore()
        let imported = store.importLegacyIfNeeded()
        if !imported.isEmpty { print("Imported \(imported.count) site(s) from SelfControl's old preferences.") }
        let entries = store.load()
        if entries.isEmpty {
            print("The blocklist is empty (\(store.path)). Add sites with: lockedin list add youtube.com")
        } else {
            entries.forEach { print($0) }
        }
    }
}

struct ListAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Save sites to the blocklist.")

    @Argument var entries: [String]

    func run() throws {
        try Client.validate(entries)
        let store = BlocklistStore()
        store.importLegacyIfNeeded()
        var saved = store.load()
        var added: [String] = []
        for entry in entries where !saved.contains(where: { $0.lowercased() == entry.lowercased() }) {
            saved.append(entry)
            added.append(entry)
        }
        try store.save(saved)
        print(added.isEmpty ? "Already in the blocklist." : "Saved: " + added.joined(separator: " "))
    }
}

struct ListRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove", abstract: "Remove sites from the saved blocklist (not from a running block).")

    @Argument var entries: [String]

    func run() throws {
        let store = BlocklistStore()
        let before = store.load()
        let lowered = Set(entries.map { $0.lowercased() })
        let after = before.filter { !lowered.contains($0.lowercased()) }
        try store.save(after)
        print("Removed \(before.count - after.count) site(s). \(after.count) left in \(store.path).")
    }
}

struct ListPath: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "path", abstract: "Print the blocklist file path.")

    func run() {
        print(BlocklistStore().path)
    }
}

struct Preview: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show what a set of sites would block, without starting anything.")

    @Argument(help: "Sites to preview. Without any, the saved blocklist is used.")
    var entries: [String] = []

    @Flag(name: .customLong("no-expand"))
    var noExpand = false

    func run() throws {
        var sites = entries
        if sites.isEmpty { sites = BlocklistStore().load() }
        guard !sites.isEmpty else { throw ValidationError("nothing to preview") }
        var parsed: [BlockEntry] = []
        for (index, site) in sites.enumerated() {
            do { parsed.append(try BlockEntry.parse(site)) } catch {
                throw ValidationError("entry \(index + 1): \(error)")
            }
        }
        let plan = BlockPlan.compile(parsed, expand: !noExpand)
        print("Names written to /etc/hosts (\(plan.hostsNames.count)):")
        plan.hostsNames.forEach { print("  \($0)" + (plan.hostsOnlyNames.contains($0) ? "   (hosts only)" : "")) }
        print("Names resolved and blocked by IP (\(plan.pfNames.count)):")
        plan.pfNames.forEach { print("  \($0)") }
        if !plan.networks.isEmpty {
            print("Addresses blocked outright: " + plan.networks.map(\.description).joined(separator: " "))
        }
        for group in plan.portGroups {
            print(
                "Port \(group.port) only: " + (group.names + group.networks.map(\.description)).joined(separator: " "))
        }
        if !plan.hostsOnlyNames.isEmpty {
            print(
                "Note: Google-family names and ~entries are blocked by name only, because their IPs are shared with other services."
            )
        }
    }
}

struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "version", abstract: "Print the version.")

    @Flag(help: "Only the version number.")
    var short = false

    func run() {
        if short {
            print(Identifiers.version)
        } else {
            print("lockedin \(Identifiers.version) (protocol \(Identifiers.protocolVersion))")
        }
    }
}

struct IdentifiersCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "identifiers", abstract: "Print every name and path LockedIn uses (for scripts).")

    @Flag var json = false

    func run() throws {
        if json {
            var dict: [String: String] = [:]
            for (key, value) in Identifiers.all { dict[key] = value }
            print(try Output.json(dict))
        } else {
            for (key, value) in Identifiers.all { print("\(key)=\(value)") }
        }
    }
}
