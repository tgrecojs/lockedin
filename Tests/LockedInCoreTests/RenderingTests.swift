import Foundation
import Testing

@testable import LockedInCore

@Suite("Hosts rendering")
struct HostsRenderingTests {
    /// Comments, blank lines, mixed whitespace, trailing spaces, and two other tools' marked sections,
    /// one of them listing names LockedIn also blocks.
    let foreign =
        "##\n# Host Database\n##\n127.0.0.1\tlocalhost\n255.255.255.255\tbroadcasthost\n::1             localhost\n"
        + "\n# BEGIN SOMEOTHERTOOL\n0.0.0.0 reddit.com   \n0.0.0.0\tnews.ycombinator.com\n# END SOMEOTHERTOOL\n"
        + "# Added by Docker Desktop\n192.168.1.20 host.docker.internal\n# End of section\n\n"

    @Test func markerContract() {
        // Changing these orphans every section already written to a live /etc/hosts.
        #expect(Identifiers.hostsBeginMarker == "# BEGIN LOCKEDIN BLOCK")
        #expect(Identifiers.hostsEndMarker == "# END LOCKEDIN BLOCK")
        #expect(Identifiers.hostsBeginLine.hasPrefix(Identifiers.hostsBeginMarker))
    }

    @Test func sectionIsSortedDedupedAndExact() {
        #expect(
            HostsFile.renderSection(names: ["b.com", "a.com", "a.com"])
                == Identifiers.hostsBeginLine + "\n0.0.0.0\ta.com\n::\ta.com\n0.0.0.0\tb.com\n::\tb.com\n"
                + Identifiers.hostsEndMarker + "\n")
        #expect(HostsFile.merged(original: foreign, names: []) == foreign)
    }

    @Test func foreignContentSurvivesByteForByte() {
        for names in [["example.com"], ["reddit.com"], ["reddit.com", "news.ycombinator.com"]] {
            let merged = HostsFile.merged(original: foreign, names: names)
            #expect(merged == foreign + HostsFile.renderSection(names: names))
            #expect(HostsFile.strip(merged) == foreign)
        }
    }

    @Test func ourSectionCanSitBetweenForeignContent() {
        let head = "127.0.0.1\tlocalhost\n"
        let tail = "# BEGIN SOMEOTHERTOOL\n0.0.0.0 x.com\n# END SOMEOTHERTOOL\n"
        #expect(HostsFile.strip(head + HostsFile.renderSection(names: ["x.com"]) + tail) == head + tail)
    }

    @Test func mergeIsIdempotentAndKeepsOneSection() {
        let once = HostsFile.merged(original: foreign, names: ["a.com"])
        #expect(HostsFile.merged(original: once, names: ["a.com"]) == once)
        #expect(HostsFile.isCurrent(once, names: ["a.com"]))
        #expect(!HostsFile.isCurrent(once, names: ["a.com", "b.com"]))
        let grown = HostsFile.merged(original: once, names: ["a.com", "b.com"])
        #expect(grown == foreign + HostsFile.renderSection(names: ["a.com", "b.com"]))
        #expect(grown.components(separatedBy: Identifiers.hostsBeginMarker).count == 2)
    }
}

@Suite("pf rendering")
struct PFRenderingTests {
    @Test func exactAnchorFile() {
        let header =
            "# LockedIn pf anchor -- loaded into \"\(Identifiers.pfAnchor)\" by \(Identifiers.daemonLabel); "
            + "regenerated automatically; do not edit\n"
        #expect(
            PFAnchor.render(ports: [443])
                == header
                + "table <lockedin_blocked> persist\n"
                + "block return out quick from any to <lockedin_blocked>\n"
                + "table <lockedin_blocked_p443> persist\n"
                + "block return out quick proto { tcp udp } from any to <lockedin_blocked_p443> port 443\n")
    }

    @Test func portOrderAndDuplicatesDoNotChangeTheFile() {
        // The daemon skips rewriting the anchor when the text is unchanged, so render must be deterministic.
        #expect(PFAnchor.render(ports: [443, 80]) == PFAnchor.render(ports: [80, 443, 80]))
    }

    @Test func everyTableIsDeclaredBeforeUse() {
        var declared = Set<String>()
        for line in PFAnchor.render(ports: [22, 8080]).split(separator: "\n") where !line.hasPrefix("#") {
            let table = line.split(separator: "<").dropFirst().first?.split(separator: ">").first.map(String.init)
            guard let table else { continue }
            if line.hasPrefix("table ") {
                #expect(line.hasSuffix(" persist"))
                declared.insert(table)
            } else {
                #expect(declared.contains(table), "\(line) uses <\(table)> before declaring it")
            }
        }
        #expect(declared == ["lockedin_blocked", "lockedin_blocked_p22", "lockedin_blocked_p8080"])
    }

    @Test func checkerAcceptsWhatTheRendererWrites() {
        #expect(PFAnchor.anchorRulesLoaded(PFAnchor.render(ports: [22, 8080]), ports: [22, 8080]))
        #expect(!PFAnchor.anchorRulesLoaded(PFAnchor.render(ports: [22]), ports: [22, 8080]))
    }

    @Test func expectedTablesWithNothingResolved() throws {
        let plan = BlockPlan.compile([try BlockEntry.parse("example.com")], expand: false)
        #expect(PFAnchor.expectedTables(plan: plan, resolved: ResolvedSets()) == ["lockedin_blocked": []])
    }
}
