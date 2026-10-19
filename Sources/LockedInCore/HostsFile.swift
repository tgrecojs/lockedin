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

    /// Removes every LockedIn section and every legacy SelfControl section, plus any stray
    /// `0.0.0.0 name` / `:: name` lines for the given names (what is left when only the marker
    /// lines were deleted). Normalizes CRLF to LF. An unterminated section is removed through
    /// the end of the file.
    public static func strip(_ text: String, names: [String] = []) -> String {
        let ours = Set(names)
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var kept: [Substring] = []
        var endMarker: String? = nil
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let end = endMarker {
                if trimmed == end { endMarker = nil }
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
            if !ours.isEmpty, isBlockLine(trimmed, names: ours) { continue }
            kept.append(line)
        }
        var result = kept.joined(separator: "\n")
        if normalized.hasSuffix("\n"), !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
        return result
    }

    /// The file contents with exactly one LockedIn section, at the end. Empty `names` means no section.
    public static func merged(original: String, names: [String]) -> String {
        var base = strip(original, names: names)
        if !base.isEmpty, !base.hasSuffix("\n") { base += "\n" }
        return names.isEmpty ? base : base + renderSection(names: names)
    }

    /// A line of exactly our form, `0.0.0.0<ws>name` or `::<ws>name`, for one of our names.
    static func isBlockLine(_ trimmed: String, names: Set<String>) -> Bool {
        let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 2, parts[0] == "0.0.0.0" || parts[0] == "::" else { return false }
        return names.contains(String(parts[1]))
    }

    /// True when the file already is exactly what `merged` would produce.
    public static func isCurrent(_ text: String, names: [String]) -> Bool {
        text == merged(original: text, names: names)
    }
}
