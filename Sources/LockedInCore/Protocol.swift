import Foundation

// Newline-delimited JSON over the daemon's unix socket. One request per connection.
// There is intentionally no stop, cancel, or remove command.

public enum Command: String, Codable, Sendable {
    case status, start, add, extend, version
}

public struct Request: Codable, Sendable, Equatable {
    public var v: Int
    public var cmd: Command
    public var entries: [String]?
    public var seconds: Int?
    public var expand: Bool?
    /// Base64 AuthorizationExternalForm; required for `start` unless the peer is root.
    public var auth: String?

    public init(cmd: Command, entries: [String]? = nil, seconds: Int? = nil, expand: Bool? = nil, auth: String? = nil) {
        self.v = Identifiers.protocolVersion
        self.cmd = cmd
        self.entries = entries
        self.seconds = seconds
        self.expand = expand
        self.auth = auth
    }
}

public enum Phase: String, Codable, Sendable {
    case idle, active
}

public struct PFStatus: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var mainAnchorPresent: Bool
    public var anchorLoaded: Bool
    public var tablesOK: Bool
    public var tokens: [String]
    public var simulated: Bool

    public init(
        enabled: Bool, mainAnchorPresent: Bool, anchorLoaded: Bool, tablesOK: Bool, tokens: [String], simulated: Bool
    ) {
        self.enabled = enabled
        self.mainAnchorPresent = mainAnchorPresent
        self.anchorLoaded = anchorLoaded
        self.tablesOK = tablesOK
        self.tokens = tokens
        self.simulated = simulated
    }

    public var healthy: Bool { enabled && mainAnchorPresent && anchorLoaded && tablesOK }
}

public struct StatusReport: Codable, Sendable, Equatable {
    public var state: Phase
    public var remainingSeconds: Double?
    public var expectedEnd: Date?
    public var startedAt: Date?
    public var initialSeconds: Int?
    public var entries: [String]
    public var hostsNames: [String]
    public var pfNames: [String]
    public var ports: [UInt16]
    public var ipCount: Int
    public var lastResolveAt: Date?
    public var lastCheckAt: Date?
    public var pf: PFStatus?
    public var hostsOK: Bool?
    public var lastBlockEndedAt: Date?
    public var daemonVersion: String
    public var protocolVersion: Int
    public var testMode: Bool

    public init(
        state: Phase, remainingSeconds: Double? = nil, expectedEnd: Date? = nil, startedAt: Date? = nil,
        initialSeconds: Int? = nil, entries: [String] = [], hostsNames: [String] = [], pfNames: [String] = [],
        ports: [UInt16] = [], ipCount: Int = 0, lastResolveAt: Date? = nil, lastCheckAt: Date? = nil,
        pf: PFStatus? = nil, hostsOK: Bool? = nil, lastBlockEndedAt: Date? = nil,
        daemonVersion: String = Identifiers.version, protocolVersion: Int = Identifiers.protocolVersion,
        testMode: Bool = false
    ) {
        self.state = state
        self.remainingSeconds = remainingSeconds
        self.expectedEnd = expectedEnd
        self.startedAt = startedAt
        self.initialSeconds = initialSeconds
        self.entries = entries
        self.hostsNames = hostsNames
        self.pfNames = pfNames
        self.ports = ports
        self.ipCount = ipCount
        self.lastResolveAt = lastResolveAt
        self.lastCheckAt = lastCheckAt
        self.pf = pf
        self.hostsOK = hostsOK
        self.lastBlockEndedAt = lastBlockEndedAt
        self.daemonVersion = daemonVersion
        self.protocolVersion = protocolVersion
        self.testMode = testMode
    }

    public var isActive: Bool { state == .active }
}

public struct VersionInfo: Codable, Sendable, Equatable {
    public var version: String
    public var protocolVersion: Int
    public var uptimeSeconds: Double
    public var testMode: Bool

    public init(version: String, protocolVersion: Int, uptimeSeconds: Double, testMode: Bool) {
        self.version = version
        self.protocolVersion = protocolVersion
        self.uptimeSeconds = uptimeSeconds
        self.testMode = testMode
    }
}

public enum ErrorCode: String, Codable, Sendable {
    case blockActive = "block_active"
    case noBlock = "no_block"
    case invalidEntry = "invalid_entry"
    case invalidDuration = "invalid_duration"
    case tooLong = "too_long"
    case tooManyEntries = "too_many_entries"
    case unauthorized
    case badRequest = "bad_request"
    case tooLarge = "too_large"
    case internalError = "internal"
}

public struct ErrorInfo: Codable, Sendable, Equatable, Error, CustomStringConvertible {
    public var code: ErrorCode
    public var message: String
    public var index: Int?

    public init(code: ErrorCode, message: String, index: Int? = nil) {
        self.code = code
        self.message = message
        self.index = index
    }

    public var description: String { message }
}

public struct Response: Codable, Sendable, Equatable {
    public var v: Int
    public var ok: Bool
    public var status: StatusReport?
    public var version: VersionInfo?
    public var added: [String]?
    public var error: ErrorInfo?

    public init(
        ok: Bool, status: StatusReport? = nil, version: VersionInfo? = nil, added: [String]? = nil,
        error: ErrorInfo? = nil
    ) {
        self.v = Identifiers.protocolVersion
        self.ok = ok
        self.status = status
        self.version = version
        self.added = added
        self.error = error
    }

    public static func success(status: StatusReport, added: [String]? = nil) -> Response {
        Response(ok: true, status: status, added: added)
    }

    public static func success(version: VersionInfo) -> Response {
        Response(ok: true, version: version)
    }

    public static func failure(_ error: ErrorInfo) -> Response {
        Response(ok: false, error: error)
    }
}

public enum NDJSON {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try makeEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        try makeDecoder().decode(type, from: line)
    }

    public static func prettyJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = makeEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
