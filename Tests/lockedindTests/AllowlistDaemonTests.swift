import Foundation
import LockedInCore
import Testing

@testable import lockedind

/// A real BlockController running an allowlist block under a relocated root (pf simulated).
/// Entries are IP addresses so nothing is resolved over the network.
@Suite("Allowlist block (relocated root)")
@MainActor
struct AllowlistDaemonTests {
    let hosts = "##\n127.0.0.1\tlocalhost\n"

    func makePaths() throws -> RuntimePaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lockedin-\(UUID())").path
        let paths = RuntimePaths(root: root)
        try FileManager.default.createDirectory(
            atPath: (paths.hosts as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try hosts.write(toFile: paths.hosts, atomically: true, encoding: .utf8)
        return paths
    }

    @Test func runsOnTheFirewallAloneAndCannotBeLoosened() throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(atPath: paths.root) }
        let controller = BlockController(paths: paths)
        let status = try controller.start(entries: ["203.0.113.7"], seconds: 600, expand: true, mode: .allowlist)
        defer { controller.expire() }

        #expect(status.mode == .allowlist)
        #expect(status.hostsNames.isEmpty)
        // No hosts section: the file is untouched.
        #expect(try String(contentsOfFile: paths.hosts, encoding: .utf8) == hosts)
        #expect(
            try String(contentsOfFile: paths.pfAnchorFile, encoding: .utf8)
                == PFAnchor.render(mode: .allowlist, ports: []))

        // Adding a site would loosen the block. Extending only makes it longer.
        #expect(throws: DaemonError.self) { try controller.add(entries: ["198.51.100.1"]) }
        #expect(controller.block?.plan.entries == ["203.0.113.7"])
        #expect(try controller.extend(seconds: 60).remainingSeconds ?? 0 > 600)
    }

    @Test func refusesEntriesThatOnlyMeanSomethingInABlocklist() throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(atPath: paths.root) }
        let controller = BlockController(paths: paths)
        #expect(throws: DaemonError.self) {
            try controller.start(entries: ["~reddit.com"], seconds: 600, expand: true, mode: .allowlist)
        }
        #expect(throws: DaemonError.self) {
            try controller.start(entries: ["example.com:8080"], seconds: 600, expand: true, mode: .allowlist)
        }
        #expect(!controller.isActive)
    }

    @Test func modeSurvivesADaemonRestart() throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(atPath: paths.root) }
        let first = BlockController(paths: paths)
        _ = try first.start(entries: ["203.0.113.7"], seconds: 600, expand: true, mode: .allowlist)

        let second = BlockController(paths: paths)
        second.loadAndResume()
        defer { second.expire() }
        #expect(second.isActive)
        #expect(second.status().mode == .allowlist)
    }
}
