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
