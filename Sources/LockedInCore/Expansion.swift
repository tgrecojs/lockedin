/// Adds the obvious variants of a host name: the www./bare toggle, m. for two-label names,
/// and the curated aliases. Only plain host entries (no port) expand; expansions inherit `~`.
public enum Expansion {
    public static func expansions(of entry: BlockEntry) -> [BlockEntry] {
        guard let host = entry.hostName, entry.port == nil else { return [entry] }
        let base = baseName(host)
        var extra: Set<String> = [base, "www." + base]
        if base.split(separator: ".").count == 2 { extra.insert("m." + base) }
        for alias in Aliases.table[base] ?? [] { extra.insert(alias) }
        extra.remove(host)
        return [entry] + extra.sorted().map { BlockEntry(target: .host($0), port: nil, hostsOnly: entry.hostsOnly) }
    }

    /// Expands every entry (when enabled), removing duplicates and keeping first-seen order.
    public static func expandAll(_ entries: [BlockEntry], enabled: Bool) -> [BlockEntry] {
        var seen = Set<BlockEntry>()
        var out: [BlockEntry] = []
        for entry in entries {
            for item in (enabled ? expansions(of: entry) : [entry]) where seen.insert(item).inserted {
                out.append(item)
            }
        }
        return out
    }

    static func baseName(_ host: String) -> String {
        for prefix in ["www.", "m."] where host.hasPrefix(prefix) {
            let rest = String(host.dropFirst(prefix.count))
            if rest.split(separator: ".").count >= 2 { return rest }
        }
        return host
    }
}
