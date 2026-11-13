import Foundation

/// Renders, detects, and splices the LockedIn section of /etc/hosts (and removes the old SelfControl one).
///
/// Everything outside the markers is copied byte for byte: line endings, whitespace, a missing final
/// newline. Only the bytes from the begin marker through the end marker's terminator are replaced.
public enum HostsFile {
    public static func renderSection(names: [String], terminator: String = "\n") -> String {
        var out = Identifiers.hostsBeginLine + terminator
        for name in Set(names).sorted() {
            out += "0.0.0.0\t\(name)" + terminator + "::\t\(name)" + terminator
        }
        out += Identifiers.hostsEndMarker + terminator
        return out
    }

    public static func containsSection(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(Identifiers.hostsBeginMarker)
        }
    }

    /// Removes every LockedIn section. Nothing outside the markers changes, byte for byte.
    /// An unterminated section owns only the run of `0.0.0.0 name` / `:: name` lines right after
    /// its begin marker; the first other line and everything after it are kept.
    public static func strip(_ text: String) -> String {
        splice(text, begin: Identifiers.hostsBeginMarker, end: Identifiers.hostsEndMarker, replacement: nil)
    }

    /// Removes the old SelfControl section the same way. Only the installer calls this: it is a one-time
    /// migration, not something the daemon does to a file it otherwise leaves alone.
    public static func stripLegacy(_ text: String) -> String {
        splice(
            text, begin: Identifiers.legacyHostsBeginMarker, end: Identifiers.legacyHostsEndMarker, replacement: nil)
    }

    /// The file with exactly one LockedIn section: in place of the first existing one, otherwise at the end.
    /// The section uses the file's dominant line ending. Empty `names` means no section.
    public static func merged(original: String, names: [String]) -> String {
        let outside = strip(original)
        guard !names.isEmpty else { return outside }
        let terminator = dominantTerminator(outside)
        return splice(
            original, begin: Identifiers.hostsBeginMarker, end: Identifiers.hostsEndMarker,
            replacement: renderSection(names: names, terminator: terminator), terminator: terminator)
    }

    /// True when the file already is exactly what `merged` would produce.
    public static func isCurrent(_ text: String, names: [String]) -> Bool {
        text == merged(original: text, names: names)
    }

    /// "\r\n" when more lines end that way than with a bare "\n"; otherwise "\n".
    static func dominantTerminator(_ text: String) -> String {
        var lf = 0
        var crlf = 0
        var previous: UInt8 = 0
        for byte in text.utf8 {
            if byte == 0x0A { if previous == 0x0D { crlf += 1 } else { lf += 1 } }
            previous = byte
        }
        return crlf > lf ? "\r\n" : "\n"
    }

    /// A line of the form LockedIn writes: `0.0.0.0<ws>name` or `::<ws>name`.
    static func isBlockLine(_ trimmed: String) -> Bool {
        let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
        return parts.count == 2 && (parts[0] == "0.0.0.0" || parts[0] == "::")
    }

    /// Each line as its exact bytes (`raw`, terminator included) and its text without the terminator.
    /// Splits on the "\n" byte, which never occurs inside a multi-byte UTF-8 sequence.
    static func lines(_ text: String) -> [(raw: String, content: String)] {
        let bytes = Array(text.utf8)
        var out: [(raw: String, content: String)] = []
        var start = 0
        while start < bytes.count {
            let newline = bytes[start...].firstIndex(of: 0x0A)
            let end = newline.map { $0 + 1 } ?? bytes.count
            var contentEnd = newline ?? bytes.count
            if contentEnd > start, bytes[contentEnd - 1] == 0x0D { contentEnd -= 1 }
            out.append(
                (
                    String(decoding: bytes[start..<end], as: UTF8.self),
                    String(decoding: bytes[start..<contentEnd], as: UTF8.self)
                ))
            start = end
        }
        return out
    }

    /// Copies `text` line by line, verbatim, dropping every `begin`...`end` section. `replacement`, if
    /// given, goes where the first section started, or at the end (after `terminator` if the file
    /// lacks a final newline).
    static func splice(
        _ text: String, begin: String, end: String, replacement: String?, terminator: String = "\n"
    ) -> String {
        var out = ""
        var placed = replacement == nil
        var inSection = false
        var pending: [(raw: String, content: String)] = []
        for line in lines(text) {
            let trimmed = line.content.trimmingCharacters(in: .whitespaces)
            if inSection {
                if trimmed == end {
                    inSection = false
                    pending = []
                } else {
                    pending.append(line)
                }
                continue
            }
            if trimmed.hasPrefix(begin) {
                if !placed, let replacement {
                    out += replacement
                    placed = true
                }
                inSection = true
                continue
            }
            out += line.raw
        }
        if inSection {
            out += pending.drop { isBlockLine($0.content.trimmingCharacters(in: .whitespaces)) }.map(\.raw).joined()
        }
        if !placed, let replacement {
            if let last = out.utf8.last, last != 0x0A { out += terminator }
            out += replacement
        }
        return out
    }
}
