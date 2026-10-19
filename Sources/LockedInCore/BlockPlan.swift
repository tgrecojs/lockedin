import Foundation

/// Entries limited to one port, grouped by port. These get firewall rules only.
public struct PortGroup: Codable, Equatable, Sendable {
    public var port: UInt16
    public var names: [String]
    public var networks: [IPNetwork]

    public init(port: UInt16, names: [String], networks: [IPNetwork]) {
        self.port = port
        self.names = names
        self.networks = networks
    }
}

/// The compiled form of a blocklist: which names go in the hosts file, which names get
/// resolved for the firewall, and which raw networks are blocked outright.
public struct BlockPlan: Codable, Equatable, Sendable {
    /// Canonical input entries, deduplicated, in the order given.
    public var entries: [String]
    public var expand: Bool
    /// Every plain host name, sorted. All of these get hosts-file lines.
    public var hostsNames: [String]
    /// Host names that are also resolved and blocked by IP, sorted.
    public var pfNames: [String]
    /// Host names blocked by the hosts file only (`~` entries and Google-family names), sorted.
    public var hostsOnlyNames: [String]
    /// Raw addresses and networks blocked on every port, sorted.
    public var networks: [IPNetwork]
    public var portGroups: [PortGroup]

    public var ports: [UInt16] { portGroups.map(\.port) }

    public static func compile(_ entries: [BlockEntry], expand: Bool) -> BlockPlan {
        let expanded = Expansion.expandAll(entries, enabled: expand)
        var hosts = Set<String>()
        var pf = Set<String>()
        var hostsOnly = Set<String>()
        var networks = Set<IPNetwork>()
        var groups: [UInt16: (names: Set<String>, networks: Set<IPNetwork>)] = [:]

        for entry in expanded {
            switch (entry.target, entry.port) {
            case (.host(let h), nil):
                hosts.insert(h)
                if entry.hostsOnly || GoogleFamily.contains(h) { hostsOnly.insert(h) } else { pf.insert(h) }
            case (.host(let h), let p?):
                groups[p, default: (names: [], networks: [])].names.insert(h)
            case (.address(let a), nil):
                networks.insert(IPNetwork(host: a))
            case (.address(let a), let p?):
                groups[p, default: (names: [], networks: [])].networks.insert(IPNetwork(host: a))
            case (.network(let n), nil):
                networks.insert(n)
            case (.network(let n), let p?):
                groups[p, default: (names: [], networks: [])].networks.insert(n)
            }
        }

        var seen = Set<String>()
        let canonical = entries.map(\.description).filter { seen.insert($0).inserted }
        let portGroups = groups.keys.sorted().map { port in
            PortGroup(port: port, names: groups[port]!.names.sorted(), networks: groups[port]!.networks.sorted())
        }
        return BlockPlan(
            entries: canonical, expand: expand, hostsNames: hosts.sorted(), pfNames: pf.sorted(),
            hostsOnlyNames: hostsOnly.sorted(), networks: networks.sorted(), portGroups: portGroups)
    }

    /// A new plan with extra entries added (removals are never possible during a block).
    public func adding(_ newEntries: [BlockEntry]) -> BlockPlan {
        let existing = entries.compactMap { try? BlockEntry.parse($0) }
        return BlockPlan.compile(existing + newEntries, expand: expand)
    }

    /// Every name the daemon needs to resolve: pf names plus port-limited names.
    public var namesToResolve: [(name: String, port: UInt16?)] {
        pfNames.map { ($0, nil) } + portGroups.flatMap { group in group.names.map { ($0, group.port) } }
    }
}
