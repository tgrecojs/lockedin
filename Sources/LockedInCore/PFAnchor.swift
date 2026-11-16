import Foundation

/// Renders the pf anchor file and parses pfctl output.
public enum PFAnchor {
    /// Always reachable during an allowlist block. Without DNS even allowed sites cannot be looked up;
    /// without the local network the router, printers, and AirDrop stop. Loopback is listed because
    /// macOS's /etc/pf.conf has no `set skip on lo0`.
    public static let alwaysAllowed: [IPNetwork] = [
        "127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "224.0.0.0/4",
        "255.255.255.255/32", "::1/128", "fe80::/10", "fc00::/7", "ff00::/8",
    ].map { IPNetwork($0)! }

    public static func render(mode: BlockMode = .blocklist, ports: [UInt16]) -> String {
        var s = "# LockedIn pf anchor -- loaded into \"\(Identifiers.pfAnchor)\" by \(Identifiers.daemonLabel); "
        s += "regenerated automatically; do not edit\n"
        switch mode {
        case .blocklist:
            s += "table <\(Identifiers.pfTable)> persist\n"
            s += "block return out quick from any to <\(Identifiers.pfTable)>\n"
            for port in Set(ports).sorted() {
                let table = Identifiers.pfPortTable(port)
                s += "table <\(table)> persist\n"
                s += "block return out quick proto { tcp udp } from any to <\(table)> port \(port)\n"
            }
        case .allowlist:
            // First match wins (quick): the passes, then a catch-all block. `return` makes a blocked
            // connection fail at once instead of hanging until it times out.
            s += "table <\(Identifiers.pfAllowTable)> persist\n"
            s += "pass out quick on lo0 all\n"
            s += "pass out quick proto { tcp udp } from any to any port 53\n"
            s += "pass out quick inet proto udp from any port 68 to any port 67\n"
            s += "pass out quick inet6 proto udp from any port 546 to any port 547\n"
            s += "pass out quick from any to { \(alwaysAllowed.map(\.description).joined(separator: ", ")) }\n"
            s += "pass out quick from any to <\(Identifiers.pfAllowTable)>\n"
            s += "block return out quick all\n"
        }
        return s
    }

    /// The table a resolved address goes in.
    public static func table(mode: BlockMode, port: UInt16?) -> String {
        mode == .allowlist ? Identifiers.pfAllowTable : port.map(Identifiers.pfPortTable) ?? Identifiers.pfTable
    }

    /// `pfctl -s info` starts with "Status: Enabled for ..." or "Status: Disabled ...".
    public static func isEnabled(infoOutput: String) -> Bool {
        infoOutput.split(whereSeparator: \.isNewline).contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("Status: Enabled")
        }
    }

    /// The reference token printed by `pfctl -E` ("Token : 4295032832").
    public static func token(from output: String) -> String? { tokens(in: output).first }

    public static func tokens(in output: String) -> [String] {
        var found: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard let r = line.range(of: "token", options: .caseInsensitive) else { continue }
            let digits = line[r.upperBound...].drop { !$0.isNumber }.prefix { $0.isNumber }
            if !digits.isEmpty { found.append(String(digits)) }
        }
        return found
    }

    /// Normalized addresses from `pfctl -t <table> -T show`.
    public static func addresses(fromTableShow output: String) -> Set<String> {
        var set = Set<String>()
        for line in output.split(whereSeparator: \.isNewline) {
            if let net = IPNetwork(line.trimmingCharacters(in: .whitespaces)) { set.insert(net.description) }
        }
        return set
    }

    /// Whether `pfctl -s rules` (the main ruleset) references the given anchor.
    public static func hasAnchorReference(rulesOutput: String, anchor: String) -> Bool {
        let needle = "anchor \"\(anchor)\""
        return rulesOutput.split(whereSeparator: \.isNewline).contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(needle)
        }
    }

    /// Whether `pfctl -a <anchor> -s rules` shows our rules for every expected table.
    public static func anchorRulesLoaded(_ anchorRulesOutput: String, mode: BlockMode = .blocklist, ports: [UInt16])
        -> Bool
    {
        if mode == .allowlist { return anchorRulesOutput.contains("<\(Identifiers.pfAllowTable)>") }
        guard anchorRulesOutput.contains("<\(Identifiers.pfTable)>") else { return false }
        for port in ports where !anchorRulesOutput.contains("<\(Identifiers.pfPortTable(port))>") {
            return false
        }
        return true
    }

    /// Table name -> the addresses it must contain, given the plan and what has been resolved so far.
    public static func expectedTables(plan: BlockPlan, resolved: ResolvedSets) -> [String: Set<String>] {
        if plan.mode == .allowlist {
            return [Identifiers.pfAllowTable: Set(resolved.all).union(plan.networks.map(\.description))]
        }
        var tables: [String: Set<String>] = [:]
        tables[Identifiers.pfTable] = Set(resolved.all).union(plan.networks.map(\.description))
        for group in plan.portGroups {
            tables[Identifiers.pfPortTable(group.port)] =
                Set(resolved.ips(port: group.port)).union(group.networks.map(\.description))
        }
        return tables
    }

    /// Destinations of open outbound connections in `pfctl -s states` output that fall outside `keep`.
    /// pf only checks rules when a connection opens, so a video already streaming when an allowlist
    /// block starts would keep playing; the daemon drops these once, at the start.
    /// Lines look like `ALL tcp 192.168.1.20:52345 -> 140.82.112.4:443  ESTABLISHED:ESTABLISHED`,
    /// with IPv6 ports in brackets (`2001:db8::1[443]`). Inbound states (`<-`) are left alone.
    public static func outboundDestinations(statesOutput: String, outside keep: [IPNetwork]) -> [String] {
        var found = Set<IPAddress>()
        for line in statesOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let arrow = fields.firstIndex(of: "->"), arrow + 1 < fields.count else { continue }
            var text = fields[arrow + 1]
            if let bracket = text.firstIndex(of: "[") {
                text = text[..<bracket]
            } else if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
                text = text[..<colon]
            }
            if let percent = text.firstIndex(of: "%") { text = text[..<percent] }
            guard let ip = IPAddress(String(text)), !keep.contains(where: { $0.contains(ip) }) else { continue }
            found.insert(ip)
        }
        return found.sorted().map(\.description)
    }
}
