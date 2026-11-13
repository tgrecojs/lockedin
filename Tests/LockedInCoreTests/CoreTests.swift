import Foundation
import Testing
@testable import LockedInCore

@Suite("BlockEntry parsing")
struct BlockEntryParsingTests {
    @Test func plainHostIsLowercasedAndCanonical() throws {
        let e = try BlockEntry.parse("  YouTube.com. ")
        #expect(e.hostName == "youtube.com")
        #expect(e.port == nil)
        #expect(e.hostsOnly == false)
        #expect(e.description == "youtube.com")
    }

    @Test func pastedURLKeepsHostAndPort() throws {
        #expect(
            try BlockEntry.parse("https://user:pw@www.Example.com:8443/path?q=1#frag").description
                == "www.example.com:8443")
        #expect(try BlockEntry.parse("https://www.youtube.com/watch?v=abc").description == "www.youtube.com")
        #expect(try BlockEntry.parse("http://reddit.com/").description == "reddit.com")
    }

    @Test func hostsOnlyPrefix() throws {
        let e = try BlockEntry.parse("~reddit.com")
        #expect(e.hostsOnly)
        #expect(e.description == "~reddit.com")
    }

    @Test func ipAndCIDR() throws {
        #expect(try BlockEntry.parse("198.51.100.1").description == "198.51.100.1")
        #expect(try BlockEntry.parse("10.0.0.0/8").description == "10.0.0.0/8")
        #expect(try BlockEntry.parse("10.1.2.3/8").description == "10.0.0.0/8")
        #expect(try BlockEntry.parse("10.0.0.0/8:443").description == "10.0.0.0/8:443")
        #expect(try BlockEntry.parse("2001:DB8::1").description == "2001:db8::1")
        #expect(try BlockEntry.parse("[2001:db8::1]:443").description == "[2001:db8::1]:443")
        #expect(try BlockEntry.parse("2001:db8::/32").description == "2001:db8::/32")
    }

    @Test func rejections() {
        #expect(throws: EntryError.empty) { try BlockEntry.parse("   ") }
        #expect(throws: EntryError.empty) { try BlockEntry.parse("~") }
        for bad in [
            "*.example.com", "*", ":443", "localhost", "dev.localhost", "127.0.0.1", "::1", "0.0.0.0",
            "10.0.0.0/0", "example.com:0", "example.com:70000", "example.com:abc", "exa mple.com",
            "-bad.com", "example.com/8", "~example.com:443", "1.2.3",
        ] {
            #expect(throws: EntryError.self, "\(bad) should be rejected") { try BlockEntry.parse(bad) }
        }
    }

    @Test func canonicalRoundTrip() throws {
        for s in [
            "youtube.com", "~reddit.com", "example.com:8080", "10.0.0.0/8", "198.51.100.7:22",
            "[2001:db8::1]:443", "2001:db8::/32:443",
        ] {
            let e = try BlockEntry.parse(s)
            #expect(try BlockEntry.parse(e.description) == e)
        }
    }
}

@Suite("Expansion")
struct ExpansionTests {
    @Test func wwwMobileAndAliases() throws {
        let names = Expansion.expansions(of: try BlockEntry.parse("youtube.com")).map(\.description)
        #expect(names.first == "youtube.com")
        #expect(names.contains("www.youtube.com"))
        #expect(names.contains("m.youtube.com"))
        #expect(names.contains("youtubei.googleapis.com"))
        #expect(names.contains("youtu.be"))
    }

    @Test func wwwPrefixedInputExpandsToBase() throws {
        let names = Expansion.expansions(of: try BlockEntry.parse("www.reddit.com")).map(\.description)
        #expect(names.contains("reddit.com"))
        #expect(names.contains("old.reddit.com"))
    }

    @Test func threeLabelHostGetsNoMobileToggle() throws {
        let names = Expansion.expansions(of: try BlockEntry.parse("news.ycombinator.com")).map(\.description)
        #expect(names.contains("www.news.ycombinator.com"))
        #expect(!names.contains("m.news.ycombinator.com"))
    }

    @Test func aliasesWorkBothWays() throws {
        #expect(Expansion.expansions(of: try BlockEntry.parse("twitter.com")).map(\.description).contains("x.com"))
        #expect(Expansion.expansions(of: try BlockEntry.parse("x.com")).map(\.description).contains("twitter.com"))
    }

    @Test func noExpansionForIPsOrPorts() throws {
        #expect(Expansion.expansions(of: try BlockEntry.parse("example.com:443")).count == 1)
        #expect(Expansion.expansions(of: try BlockEntry.parse("198.51.100.1")).count == 1)
    }

    @Test func hostsOnlyIsInherited() throws {
        #expect(Expansion.expansions(of: try BlockEntry.parse("~reddit.com")).allSatisfy(\.hostsOnly))
    }

    @Test func expandAllDedupesAndKeepsOrder() throws {
        let entries = try ["youtube.com", "www.youtube.com", "reddit.com"].map(BlockEntry.parse)
        let all = Expansion.expandAll(entries, enabled: true).map(\.description)
        #expect(all.first == "youtube.com")
        #expect(Set(all).count == all.count)
        #expect(
            Expansion.expandAll(entries, enabled: false).map(\.description) == [
                "youtube.com", "www.youtube.com", "reddit.com",
            ])
    }
}

@Suite("Google family")
struct GoogleFamilyTests {
    @Test func detection() {
        for yes in [
            "youtube.com", "m.youtube.com", "mail.google.com", "google.co.uk", "google.de", "youtubei.googleapis.com",
        ] {
            #expect(GoogleFamily.contains(yes), "\(yes)")
        }
        for no in ["notgoogle.com", "reddit.com", "googlefan.net", "nytimes.com"] {
            #expect(!GoogleFamily.contains(no), "\(no)")
        }
    }
}

@Suite("BlockPlan")
struct BlockPlanTests {
    @Test func partitionsHostsAndPF() throws {
        let input = [
            "youtube.com", "~reddit.com", "example.com:8080", "203.0.113.0/24", "198.51.100.7:22", "nytimes.com",
        ]
        let plan = BlockPlan.compile(try input.map(BlockEntry.parse), expand: true)
        #expect(plan.hostsNames.contains("youtube.com"))
        #expect(plan.hostsNames.contains("www.nytimes.com"))
        #expect(!plan.pfNames.contains("youtube.com"))
        #expect(!plan.pfNames.contains("reddit.com"))
        #expect(plan.pfNames.contains("nytimes.com"))
        #expect(!plan.hostsNames.contains("example.com"))
        #expect(plan.ports == [22, 8080])
        #expect(plan.portGroups.first { $0.port == 8080 }?.names == ["example.com"])
        #expect(plan.portGroups.first { $0.port == 22 }?.networks.map(\.description) == ["198.51.100.7"])
        #expect(plan.networks.map(\.description) == ["203.0.113.0/24"])
        #expect(plan.hostsOnlyNames.contains("reddit.com"))
        #expect(plan.entries == input)
        #expect(plan.namesToResolve.contains { $0.name == "example.com" && $0.port == 8080 })
        #expect(plan.namesToResolve.contains { $0.name == "nytimes.com" && $0.port == nil })
    }

    @Test func addingRecompiles() throws {
        let plan = BlockPlan.compile(try ["nytimes.com"].map(BlockEntry.parse), expand: true)
        let bigger = plan.adding(try ["cnn.com"].map(BlockEntry.parse))
        #expect(bigger.pfNames.contains("cnn.com"))
        #expect(bigger.pfNames.contains("nytimes.com"))
        #expect(bigger.entries == ["nytimes.com", "cnn.com"])
    }
}

@Suite("Hosts file")
struct HostsFileTests {
    let stock =
        "##\n# Host Database\n##\n127.0.0.1\tlocalhost\n255.255.255.255\tbroadcasthost\n::1             localhost\n"

    @Test func renderIsExactAndSorted() {
        let s = HostsFile.renderSection(names: ["youtube.com", "m.youtube.com"])
        let expected =
            Identifiers.hostsBeginLine
            + "\n0.0.0.0\tm.youtube.com\n::\tm.youtube.com\n0.0.0.0\tyoutube.com\n::\tyoutube.com\n"
            + Identifiers.hostsEndMarker + "\n"
        #expect(s == expected)
    }

    @Test func mergeThenStripRoundTrips() {
        let merged = HostsFile.merged(original: stock, names: ["youtube.com"])
        #expect(merged.hasPrefix(stock))
        #expect(HostsFile.containsSection(merged))
        #expect(HostsFile.strip(merged) == stock)
        #expect(HostsFile.isCurrent(merged, names: ["youtube.com"]))
        #expect(!HostsFile.isCurrent(merged, names: ["youtube.com", "reddit.com"]))
        #expect(!HostsFile.isCurrent(stock, names: ["youtube.com"]))
        #expect(HostsFile.isCurrent(stock, names: []))
    }

    @Test func legacySectionIsLeftToTheInstaller() {
        let legacy =
            stock + "\n# BEGIN SELFCONTROL BLOCK\n0.0.0.0\tyoutube.com\n::\tyoutube.com\n# END SELFCONTROL BLOCK\n"
        #expect(HostsFile.strip(legacy) == legacy)
        let once = HostsFile.stripLegacy(legacy)
        #expect(once == stock + "\n")
        #expect(HostsFile.stripLegacy(once) == once)
    }

    @Test func unterminatedSectionOwnsOnlyItsLeadingBlockLines() {
        let atEOF = stock + Identifiers.hostsBeginLine + "\n0.0.0.0\tx.com\n::\tx.com\n"
        #expect(HostsFile.strip(atEOF) == stock)
        let foreign = "10.0.0.5\tnas.local\n0.0.0.0\tads.example.net\n"
        #expect(HostsFile.strip(atEOF + foreign) == stock + foreign)
    }

    @Test func missingTrailingNewlineAndCRLF() {
        let merged = HostsFile.merged(original: "127.0.0.1\tlocalhost", names: ["x.com"])
        #expect(merged.hasPrefix("127.0.0.1\tlocalhost\n" + Identifiers.hostsBeginLine))
        #expect(Array(HostsFile.strip("a\r\nb\r\n").utf8) == Array("a\r\nb\r\n".utf8))
    }

    @Test func linesOutsideTheSectionAreNeverTouched() {
        let own = stock + "0.0.0.0\tyoutube.com\n::\tyoutube.com\n"
        let merged = HostsFile.merged(original: own, names: ["youtube.com"])
        #expect(merged == own + HostsFile.renderSection(names: ["youtube.com"]))
        #expect(HostsFile.isCurrent(merged, names: ["youtube.com"]))
        #expect(HostsFile.strip(merged) == own)
    }

    @Test func crlfFileKeepsEveryByteAndGetsACRLFSection() {
        let crlf = "##\r\n127.0.0.1\tlocalhost\r\n0.0.0.0 example.com  \r\n"
        let merged = HostsFile.merged(original: crlf, names: ["x.com"])
        let section = HostsFile.renderSection(names: ["x.com"], terminator: "\r\n")
        #expect(Array(merged.utf8) == Array((crlf + section).utf8))
        #expect(HostsFile.isCurrent(merged, names: ["x.com"]))
        #expect(Array(HostsFile.strip(merged).utf8) == Array(crlf.utf8))
    }

    @Test func sectionUsesTheMajorityLineEnding() {
        #expect(HostsFile.dominantTerminator("a\r\nb\r\nc\n") == "\r\n")
        #expect(HostsFile.dominantTerminator("a\nb\nc\r\n") == "\n")
        #expect(HostsFile.dominantTerminator("a\r\nb\n") == "\n")
        #expect(HostsFile.dominantTerminator("") == "\n")
    }

    @Test func sectionIsReplacedInPlace() {
        // Two CRLF lines outside the section against one LF line: the new section is CRLF.
        let (head, tail) = ("a\r\nc\r\n", "b\n")
        let text = head + HostsFile.renderSection(names: ["old.com"]) + tail
        let merged = HostsFile.merged(original: text, names: ["new.com"])
        let expected = head + HostsFile.renderSection(names: ["new.com"], terminator: "\r\n") + tail
        #expect(Array(merged.utf8) == Array(expected.utf8))
    }

    @Test func foreignLinesAfterSectionArePreserved() {
        let text = stock + HostsFile.renderSection(names: ["x.com"]) + "10.0.0.5\tnas.local\n"
        #expect(HostsFile.strip(text) == stock + "10.0.0.5\tnas.local\n")
    }
}

@Suite("pf anchor")
struct PFAnchorTests {
    @Test func renderNoPorts() {
        let text = PFAnchor.render(ports: [])
        #expect(text.contains("table <lockedin_blocked> persist\n"))
        #expect(text.contains("block return out quick from any to <lockedin_blocked>\n"))
        #expect(!text.contains("port"))
    }

    @Test func renderWithPorts() {
        let text = PFAnchor.render(ports: [8080, 22, 22])
        #expect(
            text.contains(
                "table <lockedin_blocked_p22> persist\nblock return out quick proto { tcp udp } from any to <lockedin_blocked_p22> port 22\n"
            ))
        #expect(text.range(of: "p22")!.lowerBound < text.range(of: "p8080")!.lowerBound)
    }

    @Test func parsers() {
        #expect(
            PFAnchor.isEnabled(infoOutput: "Status: Enabled for 0 days 00:01:02           Debug: Urgent\n\nState Table")
        )
        #expect(!PFAnchor.isEnabled(infoOutput: "Status: Disabled for 3 days 01:00:00           Debug: Urgent"))
        #expect(PFAnchor.token(from: "pf enabled\nToken : 4295032832\n") == "4295032832")
        #expect(PFAnchor.token(from: "pf already enabled\nToken : 17\n") == "17")
        #expect(PFAnchor.token(from: "pfctl: pf already enabled") == nil)
        #expect(
            PFAnchor.addresses(fromTableShow: "   151.101.1.140\n   2A04:4E42::396\n   10.0.0.0/8\n   203.0.113.7/32\n")
                == ["151.101.1.140", "2a04:4e42::396", "10.0.0.0/8", "203.0.113.7"])
        #expect(
            PFAnchor.hasAnchorReference(
                rulesOutput: "scrub-anchor \"com.apple/*\" all fragment reassemble\nanchor \"com.apple/*\" all\n",
                anchor: "com.apple/*"))
        #expect(!PFAnchor.hasAnchorReference(rulesOutput: "anchor \"other\" all\n", anchor: "com.apple/*"))
        #expect(PFAnchor.anchorRulesLoaded("block return out quick from any to <lockedin_blocked>", ports: []))
        #expect(!PFAnchor.anchorRulesLoaded("block return out quick from any to <lockedin_blocked>", ports: [443]))
    }

    @Test func expectedTables() throws {
        let plan = BlockPlan.compile(
            try ["nytimes.com", "203.0.113.0/24", "example.com:8080", "198.51.100.7:8080"].map(BlockEntry.parse),
            expand: false)
        var resolved = ResolvedSets()
        resolved.add(["151.101.1.164"], port: nil)
        resolved.add(["93.184.216.34"], port: 8080)
        let tables = PFAnchor.expectedTables(plan: plan, resolved: resolved)
        #expect(tables["lockedin_blocked"] == ["151.101.1.164", "203.0.113.0/24"])
        #expect(tables["lockedin_blocked_p8080"] == ["93.184.216.34", "198.51.100.7"])
    }
}

@Suite("Durations")
struct DurationTests {
    @Test func parsing() {
        #expect(BlockDuration.parse("2h") == 7200)
        #expect(BlockDuration.parse("90m") == 5400)
        #expect(BlockDuration.parse("1h30m") == 5400)
        #expect(BlockDuration.parse("1d") == 86400)
        #expect(BlockDuration.parse("45s") == 45)
        #expect(BlockDuration.parse("25") == 1500)
        #expect(BlockDuration.parse("1:30") == 5400)
        #expect(BlockDuration.parse("2 hours 15 min") == 8100)
        #expect(BlockDuration.parse("0") == nil)
        #expect(BlockDuration.parse("-5m") == nil)
        #expect(BlockDuration.parse("abc") == nil)
        #expect(BlockDuration.parse("1h30") == nil)
        #expect(BlockDuration.parse("") == nil)
    }

    @Test func formatting() {
        #expect(BlockDuration.clock(6130) == "1:42:10")
        #expect(BlockDuration.clock(59.2) == "1:00")
        #expect(BlockDuration.clock(0) == "0:00")
        #expect(BlockDuration.words(5400) == "1h 30m")
        #expect(BlockDuration.words(90061) == "1d 1h 1m")
        #expect(BlockDuration.words(45) == "45s")
    }
}

@Suite("Countdown")
struct CountdownTests {
    let ns: UInt64 = 1_000_000_000

    @Test func decreasesWithMonotonicTime() {
        var c = Countdown(remaining: 100, nowNs: 50 * ns)
        #expect(c.remaining(nowNs: 60 * ns) == 90)
        c.reanchor(nowNs: 60 * ns)
        #expect(c.anchorRemaining == 90)
        c.extend(by: 30, nowNs: 70 * ns)
        #expect(c.remaining(nowNs: 70 * ns) == 110)
        #expect(c.remaining(nowNs: 200 * ns) < 0)
    }

    @Test func resumeSameBootSubtractsDowntime() {
        let r = Countdown.resumedRemaining(
            savedRemaining: 500, savedMonotonicNs: 100 * ns, savedBootUUID: "A", currentBootUUID: "A", nowNs: 160 * ns)
        #expect(r == 440)
    }

    @Test func resumeAfterRebootKeepsSavedRemaining() {
        let r = Countdown.resumedRemaining(
            savedRemaining: 500, savedMonotonicNs: 100 * ns, savedBootUUID: "A", currentBootUUID: "B", nowNs: 5 * ns)
        #expect(r == 500)
    }

    @Test func clockGoingBackwardsNeverExtends() {
        let c = Countdown(remaining: 100, nowNs: 50 * ns)
        #expect(c.remaining(nowNs: 10 * ns) == 100)
    }
}

@Suite("Protocol")
struct ProtocolTests {
    @Test func requestRoundTrip() throws {
        let req = Request(cmd: .start, entries: ["youtube.com"], seconds: 3600, expand: true, auth: "AAAA")
        let line = try NDJSON.encodeLine(req)
        #expect(line.last == 0x0A)
        #expect(try NDJSON.decode(Request.self, from: line) == req)
        #expect(
            try NDJSON.decode(Request.self, from: Data("{\"v\":1,\"cmd\":\"status\"}".utf8)) == Request(cmd: .status))
    }

    @Test func responseRoundTrip() throws {
        let status = StatusReport(
            state: .active, remainingSeconds: 12.5, expectedEnd: Date(timeIntervalSince1970: 1_800_000_000),
            entries: ["youtube.com"], hostsNames: ["youtube.com"], ipCount: 3, daemonVersion: "0.1.0")
        let ok = Response.success(status: status)
        #expect(try NDJSON.decode(Response.self, from: try NDJSON.encodeLine(ok)) == ok)
        let bad = Response.failure(ErrorInfo(code: .invalidEntry, message: "nope", index: 2))
        let decoded = try NDJSON.decode(Response.self, from: try NDJSON.encodeLine(bad))
        #expect(decoded.ok == false)
        #expect(decoded.error?.code == .invalidEntry)
        #expect(decoded.error?.index == 2)
        #expect(String(decoding: try NDJSON.encodeLine(bad), as: UTF8.self).contains("\"code\":\"invalid_entry\""))
    }

    @Test func unknownFieldsAreIgnored() throws {
        let data = Data("{\"v\":1,\"cmd\":\"status\",\"future\":true}".utf8)
        #expect(try NDJSON.decode(Request.self, from: data).cmd == .status)
    }
}

@Suite("State document")
struct StateDocumentTests {
    @Test func roundTrip() throws {
        let plan = BlockPlan.compile(try ["youtube.com"].map(BlockEntry.parse), expand: true)
        let block = ActiveBlock(
            startedAt: Date(timeIntervalSince1970: 1_800_000_000), initialSeconds: 7200, remainingSeconds: 5321.5,
            plan: plan, resolved: ResolvedSets(all: ["1.2.3.4"], byPort: [PortIPs(port: 443, ips: ["5.6.7.8"])]),
            pfTokens: ["42"], lastResolveAt: nil)
        let doc = StateDocument(
            state: .active, savedAt: Date(timeIntervalSince1970: 1_800_000_100), bootUUID: "B",
            savedMonotonicNs: 123, block: block, lastBlockEndedAt: nil)
        let data = try NDJSON.makeEncoder().encode(doc)
        #expect(try NDJSON.makeDecoder().decode(StateDocument.self, from: data) == doc)
    }

    @Test func resolvedSetsAddReportsNew() {
        var r = ResolvedSets()
        #expect(r.add(["1.1.1.1", "2.2.2.2"], port: nil) == ["1.1.1.1", "2.2.2.2"])
        #expect(r.add(["2.2.2.2", "3.3.3.3"], port: nil) == ["3.3.3.3"])
        #expect(r.all == ["1.1.1.1", "2.2.2.2", "3.3.3.3"])
        #expect(r.add(["9.9.9.9"], port: 443) == ["9.9.9.9"])
        #expect(r.ips(port: 443) == ["9.9.9.9"])
        #expect(r.count == 4)
    }
}

@Suite("Blocklist file and peer policy")
struct MiscTests {
    @Test func blocklistParseAndSerialize() {
        let text = "# comment\n\nyoutube.com\n  Reddit.com  \nyoutube.com\n~x.com\n"
        #expect(BlocklistFile.parse(text) == ["youtube.com", "Reddit.com", "~x.com"])
        let out = BlocklistFile.serialize(["a.com", "b.com"])
        #expect(out.hasSuffix("a.com\nb.com\n"))
        #expect(BlocklistFile.parse(out) == ["a.com", "b.com"])
    }

    @Test func peerPolicy() {
        #expect(PeerPolicy.isAuthorized(uid: 0, groups: []))
        #expect(PeerPolicy.isAuthorized(uid: 501, groups: [20, 12, 80]))
        #expect(!PeerPolicy.isAuthorized(uid: 502, groups: [20]))
    }
}
