import Foundation

/// Parses "2h", "90m", "1h30m", "1d", "45s", "25" (minutes), "1:30" (h:mm) and formats countdowns.
public enum BlockDuration {
    public static func parse(_ text: String) -> Int? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }

        if s.allSatisfy(\.isNumber) {
            guard let minutes = Int(s), minutes > 0 else { return nil }
            return sum([(minutes, 60)])
        }

        if s.contains(":") {
            let parts = s.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
            guard parts.count == 2 || parts.count == 3, !parts.contains(nil) else { return nil }
            let v = parts.compactMap { $0 }
            let total = sum([(v[0], 3600), (v[1], 60)] + (v.count == 3 ? [(v[2], 1)] : []))
            return total.flatMap { $0 > 0 ? $0 : nil }
        }

        var total = 0
        var number = ""
        var unit = ""
        var sawUnit = false

        func flush() -> Bool {
            guard !unit.isEmpty else { return true }
            guard let n = Int(number) else { return false }
            let multiplier: Int
            switch unit.first {
            case "d": multiplier = 86_400
            case "h": multiplier = 3_600
            case "m": multiplier = 60
            case "s": multiplier = 1
            default: return false
            }
            guard let next = sum([(total, 1), (n, multiplier)]) else { return false }
            total = next
            number = ""
            unit = ""
            sawUnit = true
            return true
        }

        for ch in s {
            if ch.isNumber {
                if !unit.isEmpty { guard flush() else { return nil } }
                number.append(ch)
            } else if ch.isLetter {
                guard !number.isEmpty else { return nil }
                unit.append(ch)
            } else if ch == " " {
                continue
            } else {
                return nil
            }
        }
        guard flush(), number.isEmpty, sawUnit, total > 0 else { return nil }
        return total
    }

    /// Sum of `value * multiplier` terms, or nil on overflow, so absurd input is rejected instead of trapping.
    static func sum(_ terms: [(Int, Int)]) -> Int? {
        var total = 0
        for (value, multiplier) in terms {
            let (product, productOverflow) = value.multipliedReportingOverflow(by: multiplier)
            let (next, sumOverflow) = total.addingReportingOverflow(product)
            if productOverflow || sumOverflow { return nil }
            total = next
        }
        return total
    }

    /// "1:42:10" above an hour, otherwise "42:10". Rounds up so a block never shows 0:00 while active.
    public static func clock(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded(.up)))
        let h = t / 3600
        let m = (t % 3600) / 60
        let s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "1h 30m", "1d 1h 1m", "45s".
    public static func words(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded()))
        let d = t / 86_400
        let h = (t % 86_400) / 3600
        let m = (t % 3600) / 60
        let s = t % 60
        var parts: [String] = []
        if d > 0 { parts.append("\(d)d") }
        if h > 0 { parts.append("\(h)h") }
        if m > 0 { parts.append("\(m)m") }
        if parts.isEmpty || (d == 0 && h == 0 && s > 0) { parts.append("\(s)s") }
        return parts.joined(separator: " ")
    }
}
