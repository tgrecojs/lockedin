import Foundation

/// Renders, detects, and strips the LockedIn section of /etc/hosts (and the old SelfControl one).
public enum HostsFile {
    public static func renderSection(names: [String]) -> String {
        var out = Identifiers.hostsBeginLine + "\n"
        for name in Set(names).sorted() {
            out += "0.0.0.0\t\(name)\n::\t\(name)\n"
        }
        out += Identifiers.hostsEndMarker + "\n"
        return out
    }

    public static func containsSection(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(Identifiers.hostsBeginMarker)
        }
    }

    /// Removes every LockedIn section and every legacy SelfControl section. Nothing outside the
    /// markers is touched, so a `0.0.0.0 name` line someone wrote themselves always survives.
    /// An unterminated section owns only the run of `0.0.0.0 name` / `:: name` lines right after
    /// its begin marker; the first other line and everything after it are kept. Normalizes CRLF to LF.
    public static func strip(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var kept: [Substring] = []
        var endMarker: String? = nil
        var inside: [Substring] = []
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let end = endMarker {
                if trimmed == end {
                    endMarker = nil
                    inside = []
                } else {
                    inside.append(line)
                }
                continue
            }
            if trimmed.hasPrefix(Identifiers.hostsBeginMarker) {
                endMarker = Identifiers.hostsEndMarker
                continue
            }
            if trimmed.hasPrefix(Identifiers.legacyHostsBeginMarker) {
                endMarker = Identifiers.legacyHostsEndMarker
                continue
            }
            kept.append(line)
        }
        if endMarker != nil { kept += inside.drop { isBlockLine($0.trimmingCharacters(in: .whitespaces)) } }
        var result = kept.joined(separator: "\n")
        if normalized.hasSuffix("\n"), !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
        return result
    }

    /// The file contents with exactly one LockedIn section, at the end. Empty `names` means no section.
    public static func merged(original: String, names: [String]) -> String {
        var base = strip(original)
        if !base.isEmpty, !base.hasSuffix("\n") { base += "\n" }
        return names.isEmpty ? base : base + renderSection(names: names)
    }

    /// A line of the form LockedIn writes: `0.0.0.0<ws>name` or `::<ws>name`.
    static func isBlockLine(_ trimmed: String) -> Bool {
        let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
        return parts.count == 2 && (parts[0] == "0.0.0.0" || parts[0] == "::")
    }

    /// True when the file already is exactly what `merged` would produce.
    public static func isCurrent(_ text: String, names: [String]) -> Bool {
        text == merged(original: text, names: names)
    }
}
