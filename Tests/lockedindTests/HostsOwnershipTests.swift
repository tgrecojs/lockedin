import Foundation
import LockedInCore
import Testing

@testable import lockedind

/// Runs a real BlockController under a relocated root (the LOCKEDIN_TEST_ROOT harness, pf simulated)
/// and checks that a block never rewrites or removes hosts lines outside its own section.
@Suite("Hosts ownership (relocated root)")
@MainActor
struct HostsOwnershipTests {
    let stock = "##\n# Host Database\n##\n127.0.0.1\tlocalhost\n"
    let section = HostsFile.renderSection(names: ["example.com"])

    /// Starts a hosts-only block of example.com on `hosts`, ends it, and returns the file during and after.
    func runBlock(on hosts: String) throws -> (during: String, after: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lockedin-\(UUID())").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = RuntimePaths(root: root)
        try FileManager.default.createDirectory(
            atPath: (paths.hosts as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try hosts.write(toFile: paths.hosts, atomically: true, encoding: .utf8)

        let controller = BlockController(paths: paths)
        _ = try controller.start(entries: ["~example.com"], seconds: 60, expand: false)  // ~: no dig
        let during = try String(contentsOfFile: paths.hosts, encoding: .utf8)
        controller.expire()
        let after = try String(contentsOfFile: paths.hosts, encoding: .utf8)
        return (during, after)
    }

    @Test func noSectionPresent() throws {
        let original = stock + "0.0.0.0 example.com\n" + "10.0.0.5\tnas.local\n"
        let (during, after) = try runBlock(on: original)
        #expect(during == original + section)
        #expect(after == original)
    }

    @Test func truncatedSection() throws {
        let truncated = Identifiers.hostsBeginLine + "\n0.0.0.0\texample.com\n::\texample.com\n"
        let user = stock + "0.0.0.0 example.com\n"
        let (during, after) = try runBlock(on: user + truncated + "10.0.0.5\tnas.local\n")
        #expect(during == user + section + "10.0.0.5\tnas.local\n")
        #expect(after == user + "10.0.0.5\tnas.local\n")
    }

    @Test func crlfFileRoundTripsByteForByte() throws {
        let original = "##\r\n127.0.0.1\tlocalhost\r\n0.0.0.0 example.com\r\n"
        let (during, after) = try runBlock(on: original)
        let crlfSection = HostsFile.renderSection(names: ["example.com"], terminator: "\r\n")
        #expect(Array(during.utf8) == Array((original + crlfSection).utf8))
        #expect(Array(after.utf8) == Array(original.utf8))
    }

    @Test func sameSiteInsideAndOutsideTheSection() throws {
        // The user's line is byte-identical to one of ours; it still is not ours to remove.
        let user = stock + "0.0.0.0\texample.com\n"
        let (during, after) = try runBlock(on: user + section)
        #expect(during == user + section)
        #expect(after == user)
    }
}
