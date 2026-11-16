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

/// What a block's entries mean. An enum, not a flag: a third mode would otherwise become a second
/// boolean that can contradict the first.
public enum BlockMode: String, Codable, Sendable {
    /// The entries are blocked; everything else works.
    case blocklist
    /// The entries are the only sites that work; everything else is blocked.
    case allowlist
}

/// The compiled form of a block's entries: which names go in the hosts file, which names get
/// resolved for the firewall, and which raw networks are matched outright.
public struct BlockPlan: Codable, Equatable, Sendable {
    public var mode: BlockMode
    /// Canonical input entries, deduplicated, in the order given.
    public var entries: [String]
    public var expand: Bool
    /// Every plain host name, sorted. All of these get hosts-file lines. Empty in an allowlist.
    public var hostsNames: [String]
    /// Host names resolved and matched by IP (blocked, or in an allowlist allowed), sorted.
    public var pfNames: [String]
    /// Host names blocked by the hosts file only (`~` entries and Google-family names), sorted.
    /// Empty in an allowlist.
    public var hostsOnlyNames: [String]
    /// Raw addresses and networks matched on every port (blocked, or allowed), sorted.
    public var networks: [IPNetwork]
    /// Empty in an allowlist.
    public var portGroups: [PortGroup]

    public var ports: [UInt16] { portGroups.map(\.port) }

    init(
        mode: BlockMode, entries: [String], expand: Bool, hostsNames: [String], pfNames: [String],
        hostsOnlyNames: [String], networks: [IPNetwork], portGroups: [PortGroup]
    ) {
        self.mode = mode
        self.entries = entries
        self.expand = expand
        self.hostsNames = hostsNames
        self.pfNames = pfNames
        self.hostsOnlyNames = hostsOnlyNames
        self.networks = networks
        self.portGroups = portGroups
    }

    /// Plans saved before allowlist mode existed have no `mode`; they are blocklists. Decoding it as
    /// required would fail on a block saved by an older daemon, and a block the new daemon cannot
    /// read is a block that ends early.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(BlockMode.self, forKey: .mode) ?? .blocklist
        entries = try c.decode([String].self, forKey: .entries)
        expand = try c.decode(Bool.self, forKey: .expand)
        hostsNames = try c.decode([String].self, forKey: .hostsNames)
        pfNames = try c.decode([String].self, forKey: .pfNames)
        hostsOnlyNames = try c.decode([String].self, forKey: .hostsOnlyNames)
        networks = try c.decode([IPNetwork].self, forKey: .networks)
        portGroups = try c.decode([PortGroup].self, forKey: .portGroups)
    }

    public static func compile(_ entries: [BlockEntry], expand: Bool, mode: BlockMode = .blocklist) -> BlockPlan {
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
        if mode == .allowlist {
            // The firewall is the only mechanism, so every name is resolved and allowed by IP, Google's
            // included: allowing one Google site allows its shared front ends (README, Limits).
            // `BlockEntry.parse(_:for: .allowlist)` has already refused `~` and ports.
            return BlockPlan(
                mode: .allowlist, entries: canonical, expand: expand, hostsNames: [], pfNames: hosts.sorted(),
                hostsOnlyNames: [], networks: networks.sorted(), portGroups: [])
        }
        let portGroups = groups.keys.sorted().map { port in
            PortGroup(port: port, names: groups[port]!.names.sorted(), networks: groups[port]!.networks.sorted())
        }
        return BlockPlan(
            mode: mode, entries: canonical, expand: expand, hostsNames: hosts.sorted(), pfNames: pf.sorted(),
            hostsOnlyNames: hostsOnly.sorted(), networks: networks.sorted(), portGroups: portGroups)
    }

    /// A new plan with extra entries added (removals are never possible during a block).
    public func adding(_ newEntries: [BlockEntry]) -> BlockPlan {
        let existing = entries.compactMap { try? BlockEntry.parse($0) }
        return BlockPlan.compile(existing + newEntries, expand: expand, mode: mode)
    }

    /// Every name the daemon needs to resolve: pf names plus port-limited names.
    public var namesToResolve: [(name: String, port: UInt16?)] {
        pfNames.map { ($0, nil) } + portGroups.flatMap { group in group.names.map { ($0, group.port) } }
    }
}
