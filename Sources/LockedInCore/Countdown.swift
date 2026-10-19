/// Remaining time tracked against a monotonic clock, so wall-clock edits cannot shorten a block.
/// Timestamps are CLOCK_MONOTONIC nanoseconds (keeps counting through sleep on macOS).
public struct Countdown: Equatable, Sendable {
    public private(set) var anchorRemaining: Double
    public private(set) var anchorMonotonicNs: UInt64

    public init(remaining: Double, nowNs: UInt64) {
        anchorRemaining = remaining
        anchorMonotonicNs = nowNs
    }

    public func remaining(nowNs: UInt64) -> Double {
        guard nowNs >= anchorMonotonicNs else { return anchorRemaining }
        return anchorRemaining - Double(nowNs - anchorMonotonicNs) / 1_000_000_000
    }

    public mutating func reanchor(nowNs: UInt64) {
        anchorRemaining = remaining(nowNs: nowNs)
        anchorMonotonicNs = nowNs
    }

    public mutating func extend(by seconds: Double, nowNs: UInt64) {
        reanchor(nowNs: nowNs)
        anchorRemaining += seconds
    }

    /// Remaining time to resume from a saved state. Within the same boot the daemon's downtime is
    /// subtracted; after a reboot the saved value is used as is (a reboot never shortens a block).
    public static func resumedRemaining(
        savedRemaining: Double, savedMonotonicNs: UInt64, savedBootUUID: String,
        currentBootUUID: String, nowNs: UInt64
    ) -> Double {
        guard !savedBootUUID.isEmpty, savedBootUUID == currentBootUUID, nowNs >= savedMonotonicNs else {
            return savedRemaining
        }
        return savedRemaining - Double(nowNs - savedMonotonicNs) / 1_000_000_000
    }
}
