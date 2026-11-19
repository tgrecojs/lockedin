import Foundation
import Testing

@testable import LockedInCore

@Suite("Allowlist entries and plans")
struct AllowlistPlanTests {
    @Test func refusesWhatOnlyMeansSomethingInABlocklist() {
        #expect(throws: EntryError.hostsOnlyInAllowlist("~reddit.com")) {
            try BlockEntry.parse("~reddit.com", for: .allowlist)
        }
        #expect(throws: EntryError.portInAllowlist("example.com:8080")) {
            try BlockEntry.parse("example.com:8080", for: .allowlist)
        }
        #expect(throws: EntryError.portInAllowlist("[2001:db8::1]:443")) {
            try BlockEntry.parse("[2001:db8::1]:443", for: .allowlist)
        }
        // Loopback is always reachable in an allowlist, so the blocklist wording would mislead.
        #expect(throws: EntryError.alwaysReachable("localhost")) { try BlockEntry.parse("localhost", for: .allowlist) }
        #expect(throws: EntryError.alwaysReachable("127.0.0.1")) { try BlockEntry.parse("127.0.0.1", for: .allowlist) }
        #expect(throws: EntryError.localhost("localhost")) { try BlockEntry.parse("localhost", for: .blocklist) }
        // The general rules still apply first.
        #expect(throws: EntryError.self) { try BlockEntry.parse("*.example.com", for: .allowlist) }
    }

    @Test func acceptsSitesAddressesAndURLs() throws {
        for raw in ["github.com", "203.0.113.7", "203.0.113.0/24", "https://docs.swift.org/swift-book/"] {
            #expect(try BlockEntry.parse(raw, for: .allowlist) == BlockEntry.parse(raw))
        }
    }

    @Test func blocklistRulesAreUnchanged() throws {
        #expect(try BlockEntry.parse("~reddit.com", for: .blocklist).hostsOnly)
        #expect(try BlockEntry.parse("example.com:8080", for: .blocklist).port == 8080)
    }

    @Test func compilesToFirewallOnly() throws {
        let entries = try ["github.com", "youtube.com", "203.0.113.0/24"].map {
            try BlockEntry.parse($0, for: .allowlist)
        }
        let plan = BlockPlan.compile(entries, expand: true, mode: .allowlist)
        #expect(plan.mode == .allowlist)
        #expect(plan.hostsNames.isEmpty)
        #expect(plan.hostsOnlyNames.isEmpty)
        #expect(plan.portGroups.isEmpty)
        // Google-family names are allowed by IP like any other; in a blocklist they are hosts-only.
        #expect(plan.pfNames.contains("youtube.com"))
        #expect(plan.pfNames.contains("www.github.com"))
        #expect(plan.networks.map(\.description) == ["203.0.113.0/24"])
        #expect(plan.namesToResolve.allSatisfy { $0.port == nil })
        #expect(plan.entries == ["github.com", "youtube.com", "203.0.113.0/24"])
    }

    @Test func addingKeepsTheMode() throws {
        let plan = BlockPlan.compile([try BlockEntry.parse("github.com")], expand: false, mode: .allowlist)
        #expect(plan.adding([try BlockEntry.parse("swift.org")]).mode == .allowlist)
    }
}

@Suite("Allowlist pf rules")
struct AllowlistRulesTests {
    @Test func rendersPassesThenACatchAllBlock() {
        let expected = """
            # LockedIn pf anchor -- loaded into "com.apple/300.lockedin" by com.tgreco.lockedin.daemon; \
            regenerated automatically; do not edit
            table <lockedin_allowed> persist
            pass out quick on lo0 all no state
            pass out quick proto { tcp udp } from any to any port 53
            pass out quick inet proto udp from any port 68 to any port 67
            pass out quick inet6 proto udp from any port 546 to any port 547
            pass out quick from any to { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, \
            169.254.0.0/16, 224.0.0.0/4, 255.255.255.255, ::1, fe80::/10, fc00::/7, ff00::/8 }
            pass out quick from any to <lockedin_allowed>
            block return out quick all

            """
        #expect(PFAnchor.render(mode: .allowlist, ports: []) == expected)
        // Ports never apply to an allowlist; they cannot add rules after the catch-all.
        #expect(PFAnchor.render(mode: .allowlist, ports: [8080]) == expected)
    }

    @Test func eachModeOnlyRecognisesItsOwnRules() {
        let allow = "pass out quick from any to <lockedin_allowed> flags S/SA keep state"
        let block = "block return out quick from any to <lockedin_blocked>"
        #expect(PFAnchor.anchorRulesLoaded(allow, mode: .allowlist, ports: []))
        #expect(!PFAnchor.anchorRulesLoaded(block, mode: .allowlist, ports: []))
        #expect(!PFAnchor.anchorRulesLoaded(allow, mode: .blocklist, ports: []))
        #expect(PFAnchor.anchorRulesLoaded(block, mode: .blocklist, ports: []))
    }

    @Test func resolvedAddressesGoInTheAllowTable() throws {
        #expect(PFAnchor.table(mode: .allowlist, port: nil) == "lockedin_allowed")
        #expect(PFAnchor.table(mode: .blocklist, port: nil) == "lockedin_blocked")
        #expect(PFAnchor.table(mode: .blocklist, port: 8080) == "lockedin_blocked_p8080")
        let plan = BlockPlan.compile(
            try ["github.com", "203.0.113.0/24"].map { try BlockEntry.parse($0) }, expand: false, mode: .allowlist)
        let tables = PFAnchor.expectedTables(plan: plan, resolved: ResolvedSets(all: ["140.82.112.4"]))
        #expect(tables == ["lockedin_allowed": ["140.82.112.4", "203.0.113.0/24"]])
    }

    @Test func networkContainment() {
        let lan = IPNetwork("192.168.0.0/16")!
        #expect(lan.contains(IPAddress("192.168.1.20")!))
        #expect(!lan.contains(IPAddress("192.169.0.1")!))
        #expect(!lan.contains(IPAddress("::ffff:192.168.1.20")!))
        #expect(IPNetwork("fe80::/10")!.contains(IPAddress("fe80::1")!))
    }

    @Test func picksOutboundConnectionsToDrop() {
        let states = """
            ALL tcp 192.168.1.20:52345 -> 140.82.112.4:443       ESTABLISHED:ESTABLISHED
            ALL tcp 192.168.1.20:52346 -> 140.82.112.4:443       ESTABLISHED:ESTABLISHED
            ALL udp 192.168.1.20:61000 -> 192.168.1.1:53       MULTIPLE:SINGLE
            ALL udp 192.168.1.20:5353 -> 224.0.0.251:5353       MULTIPLE:SINGLE
            ALL tcp 2601:1c0::5[50000] -> 2606:4700::6810:84e5[443]       ESTABLISHED:ESTABLISHED
            ALL tcp fe80::1%lo0[49152] -> fe80::1%lo0[8021]       ESTABLISHED:ESTABLISHED
            ALL tcp 192.168.1.20:22 <- 192.168.1.50:61234       ESTABLISHED:ESTABLISHED
            ALL tcp 10.0.0.2:5000 (100.64.0.9:6000) -> 151.101.1.69:443       ESTABLISHED:ESTABLISHED
            No ALTQ support in kernel
            """
        #expect(
            PFAnchor.outboundDestinations(statesOutput: states, outside: PFAnchor.alwaysAllowed)
                == ["140.82.112.4", "151.101.1.69", "2606:4700::6810:84e5"])
        #expect(
            PFAnchor.outboundDestinations(
                statesOutput: states, outside: PFAnchor.alwaysAllowed + [IPNetwork("140.82.112.0/20")!])
                == ["151.101.1.69", "2606:4700::6810:84e5"])
    }
}
