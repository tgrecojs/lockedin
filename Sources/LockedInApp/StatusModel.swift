import AppKit
import Foundation
import LockedInClient
import LockedInCore
import Observation

/// Polls the daemon and keeps a locally interpolated countdown for the menu bar.
@Observable
final class StatusModel {
    var report: StatusReport?
    var live = true
    var connectionError: String?
    var displayRemaining: Double = 0
    var busy = false
    var isPopoverVisible = false

    private var receivedAtNs: UInt64 = 0
    private var lastFetchNs: UInt64 = 0
    private var wasActive = false
    private var pollTask: Task<Void, Never>?

    var isActive: Bool { report?.isActive ?? false }

    init() {
        refresh()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    private static func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC) }

    private func tick() {
        let now = Self.nowNs()
        if let report, report.isActive, let remaining = report.remainingSeconds {
            displayRemaining = max(0, remaining - Double(now &- receivedAtNs) / 1_000_000_000)
            if displayRemaining <= 0.5 && Double(now &- lastFetchNs) / 1_000_000_000 >= 1 { refresh() }
        }
        let interval: Double = isPopoverVisible || !live ? 1 : 15
        if Double(now &- lastFetchNs) / 1_000_000_000 >= interval { refresh() }
    }

    func refresh() {
        lastFetchNs = Self.nowNs()
        Task { [weak self] in
            let result = await Self.fetchStatus()
            self?.apply(result)
        }
    }

    /// The socket call blocks for up to 2 s, so it runs off the main actor.
    @concurrent private nonisolated static func fetchStatus() async -> Result<StatusReport, any Error> {
        Result { try SocketClient().send(Request(cmd: .status)).status ?? StatusReport(state: .idle) }
    }

    private func apply(_ result: Result<StatusReport, any Error>) {
        switch result {
        case .success(let status):
            report = status
            live = true
            connectionError = nil
            receivedAtNs = Self.nowNs()
            displayRemaining = max(0, status.remainingSeconds ?? 0)
            if wasActive, !status.isActive { blockEnded() }
            wasActive = status.isActive
        case .failure(let error):
            live = false
            connectionError = error.localizedDescription
            if let saved = StateFileReader.read() {
                if saved.state == .active, let block = saved.block {
                    report = StatusReport(
                        state: .active, remainingSeconds: block.remainingSeconds,
                        expectedEnd: saved.savedAt.addingTimeInterval(block.remainingSeconds),
                        startedAt: block.startedAt, initialSeconds: block.initialSeconds,
                        entries: block.plan.entries, hostsNames: block.plan.hostsNames,
                        pfNames: block.plan.pfNames, ports: block.plan.ports, ipCount: block.resolved.count)
                    displayRemaining = block.remainingSeconds
                } else {
                    report = StatusReport(state: .idle, lastBlockEndedAt: saved.lastBlockEndedAt)
                }
                receivedAtNs = Self.nowNs()
            }
        }
    }

    private func blockEnded() {
        if UserDefaults.standard.object(forKey: "playEndSound") as? Bool ?? true {
            NSSound(named: "Glass")?.play()
        }
    }

    // MARK: - Actions (each one runs the socket call off the main thread)

    func start(entries: [String], seconds: Int, expand: Bool) async throws {
        busy = true
        defer { busy = false }
        let prompt =
            "Start a \(BlockDuration.words(Double(seconds))) block of \(entries.count) site\(entries.count == 1 ? "" : "s")? It cannot be stopped early."
        let response = try await Task.detached {
            let authorization = try ClientAuthorization(prompt: prompt)
            let request = Request(
                cmd: .start, entries: entries, seconds: seconds, expand: expand,
                auth: authorization.externalFormBase64)
            let response = try SocketClient().send(request, timeout: 120)
            withExtendedLifetime(authorization) {}
            return response
        }.value
        apply(.success(response.status ?? StatusReport(state: .idle)))
    }

    func add(entries: [String]) async throws -> [String] {
        busy = true
        defer { busy = false }
        let response = try await Task.detached {
            try SocketClient().send(Request(cmd: .add, entries: entries), timeout: 30)
        }.value
        apply(.success(response.status ?? StatusReport(state: .idle)))
        return response.added ?? []
    }

    func extend(seconds: Int) async throws {
        busy = true
        defer { busy = false }
        let response = try await Task.detached {
            try SocketClient().send(Request(cmd: .extend, seconds: seconds))
        }.value
        apply(.success(response.status ?? StatusReport(state: .idle)))
    }
}

/// The saved blocklist file, shared with the CLI.
@Observable
final class BlocklistModel {
    let store = BlocklistStore()
    var entries: [String] = []
    var importedCount = 0

    init() {
        importedCount = store.importLegacyIfNeeded().count
        entries = store.load()
    }

    func add(_ raw: String) throws {
        let entry = try BlockEntry.parse(raw)
        let text = entry.description
        guard !entries.contains(where: { $0.lowercased() == text }) else { return }
        entries.append(text)
        try store.save(entries)
    }

    func remove(_ entry: String) {
        entries.removeAll { $0 == entry }
        try? store.save(entries)
    }

    func reload() {
        entries = store.load()
    }
}
