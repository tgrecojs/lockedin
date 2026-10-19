import Foundation
import LockedInCore

struct ResolvedName: Sendable {
    let name: String
    let port: UInt16?
    let addresses: Set<String>
}

/// Resolves host names with `dig`, which asks the nameservers directly and ignores /etc/hosts
/// (the system resolver would hand back our own 0.0.0.0 entries once the block is in place).
enum Resolver {
    static let dig = "/usr/bin/dig"
    static let concurrency = 8

    static func resolve(_ targets: [(name: String, port: UInt16?)]) async -> [ResolvedName] {
        var results: [ResolvedName] = []
        var index = 0
        while index < targets.count {
            let batch = Array(targets[index..<min(index + concurrency, targets.count)])
            index += concurrency
            let batchResults = await withTaskGroup(of: ResolvedName.self, returning: [ResolvedName].self) { group in
                for target in batch {
                    group.addTask { await resolveOne(target.name, port: target.port) }
                }
                var out: [ResolvedName] = []
                for await result in group { out.append(result) }
                return out
            }
            results += batchResults
        }
        return results
    }

    static func resolveOne(_ name: String, port: UInt16?) async -> ResolvedName {
        async let a = Shell.runAsync(dig, ["+short", "+time=2", "+tries=1", "A", name], timeout: 8)
        async let aaaa = Shell.runAsync(dig, ["+short", "+time=2", "+tries=1", "AAAA", name], timeout: 8)
        var addresses = Set<String>()
        for output in await [a.output, aaaa.output] {
            for line in output.split(whereSeparator: \.isNewline) {
                if let ip = IPAddress(line.trimmingCharacters(in: .whitespaces)), !ip.isLoopback, !ip.isUnspecified {
                    addresses.insert(ip.description)
                }
            }
        }
        return ResolvedName(name: name, port: port, addresses: addresses)
    }
}
