import Foundation

public struct PortIPs: Codable, Sendable, Equatable {
    public var port: UInt16
    public var ips: [String]

    public init(port: UInt16, ips: [String]) {
        self.port = port
        self.ips = ips
    }
}

/// Every IP resolved during a block. Addresses are only ever added, never removed, so a site
/// that rotates its IPs stays blocked.
public struct ResolvedSets: Codable, Sendable, Equatable {
    public var all: [String]
    public var byPort: [PortIPs]

    public init(all: [String] = [], byPort: [PortIPs] = []) {
        self.all = all
        self.byPort = byPort
    }

    public func ips(port: UInt16) -> [String] {
        byPort.first { $0.port == port }?.ips ?? []
    }

    public var count: Int { all.count + byPort.reduce(0) { $0 + $1.ips.count } }

    /// Adds addresses and returns the ones that were new.
    @discardableResult
    public mutating func add(_ ips: Set<String>, port: UInt16?) -> Set<String> {
        if let port {
            if let i = byPort.firstIndex(where: { $0.port == port }) {
                let new = ips.subtracting(byPort[i].ips)
                byPort[i].ips = Set(byPort[i].ips).union(new).sorted()
                return new
            }
            byPort.append(PortIPs(port: port, ips: ips.sorted()))
            byPort.sort { $0.port < $1.port }
            return ips
        }
        let new = ips.subtracting(all)
        all = Set(all).union(new).sorted()
        return new
    }
}

public struct ActiveBlock: Codable, Sendable, Equatable {
    public var startedAt: Date
    public var initialSeconds: Int
    public var remainingSeconds: Double
    public var plan: BlockPlan
    public var resolved: ResolvedSets
    public var pfTokens: [String]
    public var lastResolveAt: Date?

    public init(
        startedAt: Date, initialSeconds: Int, remainingSeconds: Double, plan: BlockPlan,
        resolved: ResolvedSets, pfTokens: [String], lastResolveAt: Date?
    ) {
        self.startedAt = startedAt
        self.initialSeconds = initialSeconds
        self.remainingSeconds = remainingSeconds
        self.plan = plan
        self.resolved = resolved
        self.pfTokens = pfTokens
        self.lastResolveAt = lastResolveAt
    }
}

/// The daemon's persisted state (root-owned JSON). Readable by everyone for display.
public struct StateDocument: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    public var schema: Int
    public var daemonVersion: String
    public var state: Phase
    public var savedAt: Date
    public var bootUUID: String
    public var savedMonotonicNs: UInt64
    public var block: ActiveBlock?
    public var lastBlockEndedAt: Date?

    public init(
        schema: Int = StateDocument.currentSchema, daemonVersion: String = Identifiers.version,
        state: Phase, savedAt: Date, bootUUID: String, savedMonotonicNs: UInt64,
        block: ActiveBlock?, lastBlockEndedAt: Date?
    ) {
        self.schema = schema
        self.daemonVersion = daemonVersion
        self.state = state
        self.savedAt = savedAt
        self.bootUUID = bootUUID
        self.savedMonotonicNs = savedMonotonicNs
        self.block = block
        self.lastBlockEndedAt = lastBlockEndedAt
    }
}
