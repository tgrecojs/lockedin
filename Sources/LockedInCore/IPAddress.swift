import Foundation

/// An IPv4 or IPv6 address, normalized through inet_pton/inet_ntop so equal addresses compare equal.
public struct IPAddress: Hashable, Sendable, Comparable, CustomStringConvertible, Codable {
    public enum Family: String, Sendable, Codable { case v4, v6 }

    public let family: Family
    public let bytes: [UInt8]

    init(family: Family, bytes: [UInt8]) {
        self.family = family
        self.bytes = bytes
    }

    public init?(_ text: String) {
        var v4 = in_addr()
        if text.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            self.init(family: .v4, bytes: withUnsafeBytes(of: v4) { Array($0) })
            return
        }
        var v6 = in6_addr()
        if text.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            self.init(family: .v6, bytes: withUnsafeBytes(of: v6) { Array($0) })
            return
        }
        return nil
    }

    public var maxPrefix: Int { family == .v4 ? 32 : 128 }
    public var isUnspecified: Bool { bytes.allSatisfy { $0 == 0 } }
    public var isLoopback: Bool {
        switch family {
        case .v4: return bytes.first == 127
        case .v6: return bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        }
    }

    /// The address with all bits beyond `prefix` cleared.
    public func masked(prefix: Int) -> IPAddress {
        var out = bytes
        for i in out.indices {
            let kept = max(0, min(8, prefix - i * 8))
            let mask: UInt8 = kept == 0 ? 0 : UInt8(truncatingIfNeeded: 0xFF << (8 - kept))
            out[i] &= mask
        }
        return IPAddress(family: family, bytes: out)
    }

    public var description: String {
        let af: Int32 = family == .v4 ? AF_INET : AF_INET6
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let ok = bytes.withUnsafeBytes { raw -> Bool in
            buffer.withUnsafeMutableBufferPointer { out in
                inet_ntop(af, raw.baseAddress, out.baseAddress, socklen_t(out.count)) != nil
            }
        }
        guard ok else { return "?" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    public static func < (a: IPAddress, b: IPAddress) -> Bool {
        if a.family != b.family { return a.family == .v4 }
        return a.bytes.lexicographicallyPrecedes(b.bytes)
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let ip = IPAddress(text) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "invalid IP address: \(text)"))
        }
        self = ip
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// An address plus prefix length (CIDR). A full-length prefix is a single host.
public struct IPNetwork: Hashable, Sendable, Comparable, CustomStringConvertible, Codable {
    public let address: IPAddress
    public let prefix: Int

    public init(address: IPAddress, prefix: Int) {
        let clamped = max(0, min(prefix, address.maxPrefix))
        self.address = address.masked(prefix: clamped)
        self.prefix = clamped
    }

    public init(host: IPAddress) {
        self.init(address: host, prefix: host.maxPrefix)
    }

    /// Parses "a.b.c.d", "a.b.c.d/n", "::1", or "2001:db8::/32".
    public init?(_ text: String) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard let first = parts.first, let ip = IPAddress(String(first)) else { return nil }
        if parts.count == 1 {
            self.init(host: ip)
            return
        }
        guard parts.count == 2, let p = Int(parts[1]), p >= 0, p <= ip.maxPrefix else { return nil }
        self.init(address: ip, prefix: p)
    }

    public var isSingleHost: Bool { prefix == address.maxPrefix }

    public var description: String {
        isSingleHost ? address.description : "\(address.description)/\(prefix)"
    }

    public static func < (a: IPNetwork, b: IPNetwork) -> Bool {
        if a.address != b.address { return a.address < b.address }
        return a.prefix < b.prefix
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let net = IPNetwork(text) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "invalid network: \(text)"))
        }
        self = net
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
