import Foundation

public enum EntryError: Error, Equatable, Sendable, CustomStringConvertible {
    case empty
    case wildcard(String)
    case localhost(String)
    case loopback(String)
    case invalidHost(String)
    case invalidPort(String)
    case invalidPrefix(String)
    case conflictingScope(String)

    public var description: String {
        switch self {
        case .empty: return "empty entry"
        case .wildcard(let s): return "\"\(s)\": wildcards are not supported; list each subdomain instead"
        case .localhost(let s): return "\"\(s)\": localhost cannot be blocked"
        case .loopback(let s): return "\"\(s)\": loopback and unspecified addresses cannot be blocked"
        case .invalidHost(let s): return "\"\(s)\": not a valid host name or IP address"
        case .invalidPort(let s): return "\"\(s)\": port must be 1-65535"
        case .invalidPrefix(let s):
            return "\"\(s)\": a network prefix needs an IP address and 1-32 (IPv4) or 1-128 (IPv6) bits"
        case .conflictingScope(let s): return "\"\(s)\": ~ (hosts-only) cannot be combined with a port"
        }
    }
}

/// One thing to block: a host name, an IP address, or a network, optionally limited to one port.
/// A `~` prefix means "hosts file only" (no firewall rule for the resolved IPs).
public struct BlockEntry: Hashable, Sendable, CustomStringConvertible {
    public enum Target: Hashable, Sendable {
        case host(String)
        case address(IPAddress)
        case network(IPNetwork)
    }

    public let target: Target
    public let port: UInt16?
    public let hostsOnly: Bool

    public init(target: Target, port: UInt16? = nil, hostsOnly: Bool = false) {
        self.target = target
        self.port = port
        self.hostsOnly = hostsOnly
    }

    public var hostName: String? {
        if case .host(let h) = target { return h }
        return nil
    }

    /// Canonical text form; parsing it again yields an equal entry.
    public var description: String {
        var s = hostsOnly ? "~" : ""
        switch target {
        case .host(let h): s += h
        case .address(let a): s += (a.family == .v6 && port != nil) ? "[\(a)]" : a.description
        case .network(let n): s += n.description
        }
        if let port { s += ":\(port)" }
        return s
    }

    /// Accepts "host", "host:port", "1.2.3.4", "10.0.0.0/8[:port]", "[v6]:port", "~host",
    /// and pasted URLs (scheme, user info, path, and query are dropped). Lowercases the host.
    public static func parse(_ raw: String) throws(EntryError) -> BlockEntry {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { throw EntryError.empty }

        var hostsOnly = false
        if s.hasPrefix("~") {
            hostsOnly = true
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { throw EntryError.empty }
        }

        if let scheme = s.range(of: "://") { s = String(s[scheme.upperBound...]) }
        if let cut = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<cut]) }
        if let at = s.lastIndex(of: "@") {
            let slash = s.firstIndex(of: "/") ?? s.endIndex
            if at < slash { s = String(s[s.index(after: at)...]) }
        }

        var prefix: Int? = nil
        var portText: String? = nil
        if let slash = s.firstIndex(of: "/") {
            var after = String(s[s.index(after: slash)...])
            s = String(s[..<slash])
            if let colon = after.firstIndex(of: ":") {
                portText = String(after[after.index(after: colon)...])
                after = String(after[..<colon])
            }
            if !after.isEmpty, after.allSatisfy(\.isNumber) {
                prefix = Int(after)
            } else {
                portText = nil  // it was a URL path, not a network prefix
            }
        }

        if portText == nil {
            if s.hasPrefix("[") {
                guard let close = s.firstIndex(of: "]") else { throw EntryError.invalidHost(raw) }
                let inner = String(s[s.index(after: s.startIndex)..<close])
                let rest = String(s[s.index(after: close)...])
                if rest.hasPrefix(":") {
                    portText = String(rest.dropFirst())
                } else if !rest.isEmpty {
                    throw EntryError.invalidHost(raw)
                }
                s = inner
            } else if s.filter({ $0 == ":" }).count == 1, let colon = s.firstIndex(of: ":") {
                portText = String(s[s.index(after: colon)...])
                s = String(s[..<colon])
            }
        }

        var port: UInt16? = nil
        if let text = portText {
            guard let p = UInt16(text), p >= 1 else { throw EntryError.invalidPort(text.isEmpty ? raw : text) }
            port = p
        }

        if s.hasSuffix(".") { s = String(s.dropLast()) }
        if s.isEmpty || s == "*" {
            throw (s.isEmpty && port == nil) ? EntryError.empty : EntryError.wildcard(raw)
        }
        if s.contains("*") { throw EntryError.wildcard(raw) }

        if let ip = IPAddress(s) {
            if ip.isLoopback || ip.isUnspecified { throw EntryError.loopback(raw) }
            if let prefix {
                guard prefix >= 1, prefix <= ip.maxPrefix else { throw EntryError.invalidPrefix(raw) }
                return BlockEntry(target: .network(IPNetwork(address: ip, prefix: prefix)), port: port)
            }
            return BlockEntry(target: .address(ip), port: port)
        }

        if prefix != nil { throw EntryError.invalidPrefix(raw) }
        guard isValidHostname(s) else { throw EntryError.invalidHost(raw) }
        if s == "localhost" || s.hasSuffix(".localhost") { throw EntryError.localhost(raw) }
        if hostsOnly && port != nil { throw EntryError.conflictingScope(raw) }
        return BlockEntry(target: .host(s), port: port, hostsOnly: hostsOnly)
    }

    static func isValidHostname(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 253 else { return false }
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return false }
            guard label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return false }
            guard label.first != "-", label.last != "-" else { return false }
        }
        if let last = labels.last, last.allSatisfy(\.isNumber) { return false }
        return true
    }
}
