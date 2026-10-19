import Foundation

/// The user's saved blocklist: one entry per line, `#` comments, blank lines ignored.
public enum BlocklistFile {
    public static let header = """
        # LockedIn blocklist -- one site per line. Lines starting with # are comments.
        # Examples: youtube.com   reddit.com   example.com:8080   203.0.113.0/24
        # Prefix a site with ~ to block it by name only (no firewall rule for its IPs).

        """

    public static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if seen.insert(line.lowercased()).inserted { out.append(line) }
        }
        return out
    }

    public static func serialize(_ entries: [String]) -> String {
        header + entries.joined(separator: "\n") + (entries.isEmpty ? "" : "\n")
    }
}
