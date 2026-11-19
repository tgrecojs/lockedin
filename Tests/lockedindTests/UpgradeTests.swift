import Foundation
import LockedInCore
import Testing

@testable import lockedind

/// `make install` during a block replaces the daemon, and the new one must resume what the old one
/// saved. If it cannot decode the file, it stays idle, and the next restart cleans the block up:
/// a block ended early (invariant 1). Every field added to the saved state must keep this test passing.
@Suite("Upgrade mid-block (relocated root)")
@MainActor
struct UpgradeTests {
    /// Written by the v0.1.0 daemon in test mode (`lockedin start 2h youtube.com example.com:8080
    /// 203.0.113.0/24 ~reddit.com`), reformatted, with `bootUUID` zeroed so it is never the current boot.
    /// Do not edit it to match new code: it is the old format.
    static let v010State = """
        {
          "block" : {
            "initialSeconds" : 7200,
            "lastResolveAt" : "2026-11-16T22:56:26Z",
            "pfTokens" : [ "simulated-1794869786" ],
            "plan" : {
              "entries" : [ "youtube.com", "example.com:8080", "203.0.113.0/24", "~reddit.com" ],
              "expand" : true,
              "hostsNames" : [
                "i.redd.it", "m.reddit.com", "m.youtube.com", "new.reddit.com", "old.reddit.com", "redd.it",
                "reddit.com", "sh.reddit.com", "v.redd.it", "www.reddit.com", "www.youtube-nocookie.com",
                "www.youtube.com", "youtu.be", "youtube-nocookie.com", "youtube.com", "youtubei.googleapis.com"
              ],
              "hostsOnlyNames" : [
                "i.redd.it", "m.reddit.com", "m.youtube.com", "new.reddit.com", "old.reddit.com", "redd.it",
                "reddit.com", "sh.reddit.com", "v.redd.it", "www.reddit.com", "www.youtube-nocookie.com",
                "www.youtube.com", "youtu.be", "youtube-nocookie.com", "youtube.com", "youtubei.googleapis.com"
              ],
              "networks" : [ "203.0.113.0/24" ],
              "pfNames" : [ ],
              "portGroups" : [ { "names" : [ "example.com" ], "networks" : [ ], "port" : 8080 } ]
            },
            "remainingSeconds" : 7195.982508,
            "resolved" : {
              "all" : [ ],
              "byPort" : [
                {
                  "ips" : [ "104.20.23.154", "172.66.147.243", "2606:4700:10::6814:179a", "2606:4700:10::ac42:93f3" ],
                  "port" : 8080
                }
              ]
            },
            "startedAt" : "2026-11-16T22:56:26Z"
          },
          "bootUUID" : "00000000-0000-0000-0000-000000000000",
          "daemonVersion" : "0.1.0",
          "savedAt" : "2026-11-16T22:56:30Z",
          "savedMonotonicNs" : 552145753159000,
          "schema" : 1,
          "state" : "active"
        }
        """

    @Test func resumesABlockSavedByV010() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lockedin-\(UUID())").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = RuntimePaths(root: root)
        for path in [paths.stateFile, paths.hosts] {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        }
        try Self.v010State.write(toFile: paths.stateFile, atomically: true, encoding: .utf8)
        try "127.0.0.1\tlocalhost\n".write(toFile: paths.hosts, atomically: true, encoding: .utf8)

        let controller = BlockController(paths: paths)
        controller.loadAndResume()
        defer { controller.expire() }

        // Another boot, so it resumes from the saved remaining time rather than subtracting downtime.
        #expect(controller.isActive)
        #expect((7190...7196).contains(controller.currentRemaining))
        #expect(controller.block?.plan.mode == .blocklist)
        #expect(controller.block?.plan.entries == ["youtube.com", "example.com:8080", "203.0.113.0/24", "~reddit.com"])
        #expect(try String(contentsOfFile: paths.hosts, encoding: .utf8).contains("0.0.0.0\tyoutube.com"))
    }
}
