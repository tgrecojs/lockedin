import Foundation
import LockedInCore

/// Every pfctl invocation the daemon makes. Only anchor-scoped flushes exist here on purpose:
/// never `-F all` or `-F states`, which would drop every connection on the Mac.
@MainActor
final class PFManager {
    let anchor = Identifiers.pfAnchor
    let anchorFilePath: String
    let tablesDirectory: String
    let simulated: Bool
    private let pfctl = "/sbin/pfctl"

    init(paths: RuntimePaths) {
        anchorFilePath = paths.pfAnchorFile
        tablesDirectory = paths.tablesDirectory
        simulated = paths.isTestMode
    }

    @discardableResult
    private func pf(_ arguments: [String], timeout: TimeInterval = 10, quietFailure: Bool = false) -> ShellResult {
        if simulated {
            Log.info("[simulated] pfctl \(arguments.joined(separator: " "))")
            return ShellResult(status: 0, output: "")
        }
        let result = Shell.run(pfctl, arguments, timeout: timeout)
        if !result.succeeded, !quietFailure {
            Log.warn("pfctl \(arguments.joined(separator: " ")) failed (\(result.status)): \(result.trimmedOutput)")
        }
        return result
    }

    /// Writes the anchor file when its content changed. Returns true when it wrote.
    @discardableResult
    func writeAnchorFile(ports: [UInt16]) -> Bool {
        let text = PFAnchor.render(ports: ports)
        if let existing = try? String(contentsOfFile: anchorFilePath, encoding: .utf8), existing == text {
            return false
        }
        do {
            let directory = (anchorFilePath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try text.write(toFile: anchorFilePath, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: anchorFilePath)
            return true
        } catch {
            Log.error("could not write \(anchorFilePath): \(error)")
            return false
        }
    }

    func loadAnchor() -> Bool {
        pf(["-q", "-a", anchor, "-f", anchorFilePath]).succeeded
    }

    func replaceTable(_ table: String, with addresses: Set<String>) -> Bool {
        if addresses.isEmpty {
            return pf(["-q", "-a", anchor, "-t", table, "-T", "flush"], quietFailure: true).succeeded
        }
        let file = tablesDirectory + "/" + table + ".txt"
        do {
            try FileManager.default.createDirectory(atPath: tablesDirectory, withIntermediateDirectories: true)
            try (addresses.sorted().joined(separator: "\n") + "\n").write(
                toFile: file, atomically: true, encoding: .utf8)
        } catch {
            Log.error("could not write \(file): \(error)")
            return false
        }
        return pf(["-q", "-a", anchor, "-t", table, "-T", "replace", "-f", file]).succeeded
    }

    func addToTable(_ table: String, _ addresses: Set<String>) -> Bool {
        guard !addresses.isEmpty else { return true }
        return pf(["-q", "-a", anchor, "-t", table, "-T", "add"] + addresses.sorted()).succeeded
    }

    func isEnabled() -> Bool {
        simulated ? true : PFAnchor.isEnabled(infoOutput: pf(["-s", "info"]).output)
    }

    /// Takes a pf enable reference. Returns its token.
    func enable() -> String? {
        if simulated { return "simulated-\(Int(Date().timeIntervalSince1970))" }
        let result = Shell.run(pfctl, ["-E"])
        guard let token = PFAnchor.token(from: result.output) else {
            Log.warn("pfctl -E returned no token: \(result.trimmedOutput)")
            return nil
        }
        return token
    }

    func release(token: String) {
        guard !token.hasPrefix("simulated") else { return }
        pf(["-X", token], quietFailure: true)
    }

    /// Drops existing connections to the given addresses so a site already open stops working.
    func killStates(to addresses: Set<String>) {
        for address in addresses.sorted() {
            guard let network = IPNetwork(address) else { continue }
            let wildcard = network.address.family == .v4 ? "0.0.0.0/0" : "::/0"
            pf(["-q", "-k", wildcard, "-k", address], timeout: 5, quietFailure: true)
        }
    }

    func mainRulesetHasWildcardAnchor() -> Bool {
        simulated
            ? true
            : PFAnchor.hasAnchorReference(
                rulesOutput: pf(["-s", "rules"]).output, anchor: Identifiers.pfWildcardAnchor)
    }

    func reloadMainRuleset() {
        pf(["-f", Identifiers.pfConfPath])
    }

    func anchorRulesLoaded(ports: [UInt16]) -> Bool {
        simulated
            ? true
            : PFAnchor.anchorRulesLoaded(pf(["-a", anchor, "-s", "rules"], quietFailure: true).output, ports: ports)
    }

    func tableContents(_ table: String) -> Set<String> {
        simulated
            ? []
            : PFAnchor.addresses(
                fromTableShow: pf(["-a", anchor, "-t", table, "-T", "show"], quietFailure: true).output)
    }

    func status(ports: [UInt16], expectedTables: [String: Set<String>], tokens: [String]) -> PFStatus {
        if simulated {
            return PFStatus(
                enabled: true, mainAnchorPresent: true, anchorLoaded: true, tablesOK: true, tokens: tokens,
                simulated: true)
        }
        let enabled = isEnabled()
        let main = mainRulesetHasWildcardAnchor()
        let loaded = anchorRulesLoaded(ports: ports)
        var tablesOK = true
        for (table, expected) in expectedTables where !expected.isEmpty {
            if !tableContents(table).isSuperset(of: expected) {
                tablesOK = false
                break
            }
        }
        return PFStatus(
            enabled: enabled, mainAnchorPresent: main, anchorLoaded: loaded, tablesOK: tablesOK, tokens: tokens,
            simulated: false)
    }

    func flushAnchor() {
        pf(["-q", "-a", anchor, "-F", "rules"], quietFailure: true)
        pf(["-q", "-a", anchor, "-F", "Tables"], quietFailure: true)
    }

    func removeTableFiles() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: tablesDirectory)) ?? [] {
            try? fm.removeItem(atPath: tablesDirectory + "/" + name)
        }
    }
}
