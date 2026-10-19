import Foundation

/// CLOCK_MONOTONIC keeps counting while the Mac sleeps and cannot be set by the user.
enum MonotonicClock {
    static func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC) }
    static func uptimeSeconds() -> Double { Double(nowNs()) / 1_000_000_000 }
}

enum BootSession {
    /// Changes on every boot; lets a same-boot daemon restart subtract its own downtime.
    static func uuid() -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return "" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
