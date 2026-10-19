import Foundation

/// Renders the pf anchor file and parses pfctl output.
public enum PFAnchor {
    public static func render(ports: [UInt16]) -> String {
        var s = "# LockedIn pf anchor -- loaded into \"\(Identifiers.pfAnchor)\" by \(Identifiers.daemonLabel); "
        s += "regenerated automatically; do not edit\n"
        s += "table <\(Identifiers.pfTable)> persist\n"
        s += "block return out quick from any to <\(Identifiers.pfTable)>\n"
        for port in Set(ports).sorted() {
            let table = Identifiers.pfPortTable(port)
            s += "table <\(table)> persist\n"
            s += "block return out quick proto { tcp udp } from any to <\(table)> port \(port)\n"
        }
        return s
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
    public static func anchorRulesLoaded(_ anchorRulesOutput: String, ports: [UInt16]) -> Bool {
        guard anchorRulesOutput.contains("<\(Identifiers.pfTable)>") else { return false }
        for port in ports where !anchorRulesOutput.contains("<\(Identifiers.pfPortTable(port))>") {
            return false
        }
        return true
    }

    /// Table name -> the addresses it must contain, given the plan and what has been resolved so far.
    public static func expectedTables(plan: BlockPlan, resolved: ResolvedSets) -> [String: Set<String>] {
        var tables: [String: Set<String>] = [:]
        tables[Identifiers.pfTable] = Set(resolved.all).union(plan.networks.map(\.description))
        for group in plan.portGroups {
            tables[Identifiers.pfPortTable(group.port)] =
                Set(resolved.ips(port: group.port)).union(group.networks.map(\.description))
        }
        return tables
    }
}
