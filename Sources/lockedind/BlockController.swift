import Foundation
import LockedInCore

struct DaemonError: Error {
    let code: ErrorCode
    let message: String
    let index: Int?

    init(_ code: ErrorCode, _ message: String, index: Int? = nil) {
        self.code = code
        self.message = message
        self.index = index
    }

    var info: ErrorInfo { ErrorInfo(code: code, message: message, index: index) }
}

/// The block state machine: idle or active. Active blocks count down on the monotonic clock,
/// are re-applied whenever hosts or pf drift, and end only when the countdown reaches zero.
@MainActor
final class BlockController {
    let paths: RuntimePaths
    let store: StateStore
    let hosts: HostsManager
    let pf: PFManager
    let bootUUID: String

    private(set) var block: ActiveBlock?
    private var countdown: Countdown?
    private var timer: DispatchSourceTimer?
    private var lastPersistNs: UInt64 = 0
    private var lastCheckNs: UInt64 = 0
    private var lastResolveNs: UInt64 = 0
    private var lastMainReloadNs: UInt64 = 0
    private var resolveInFlight = false
    private var unresolvedWarned: Set<String> = []
    private var lastBlockEndedAt: Date?
    private var lastPFStatus: PFStatus?
    private var lastHostsOK: Bool?
    private var lastCheckAt: Date?

    init(paths: RuntimePaths) {
        self.paths = paths
        store = StateStore(path: paths.stateFile)
        hosts = HostsManager(path: paths.hosts, simulated: paths.isTestMode)
        pf = PFManager(paths: paths)
        bootUUID = BootSession.uuid()
    }

    var isActive: Bool { block != nil }

    var currentRemaining: Double {
        guard let countdown else { return 0 }
        return max(0, countdown.remaining(nowNs: MonotonicClock.nowNs()))
    }

    // MARK: - Lifecycle

    func loadAndResume() {
        switch store.load() {
        case .document(let document):
            lastBlockEndedAt = document.lastBlockEndedAt
            guard document.state == .active, var active = document.block else {
                ensureClean()
                return
            }
            let now = MonotonicClock.nowNs()
            let remaining = Countdown.resumedRemaining(
                savedRemaining: active.remainingSeconds, savedMonotonicNs: document.savedMonotonicNs,
                savedBootUUID: document.bootUUID, currentBootUUID: bootUUID, nowNs: now)
            active.remainingSeconds = max(0, remaining)
            block = active
            countdown = Countdown(remaining: remaining, nowNs: now)
            if remaining <= 0 {
                Log.info("saved block had already expired; cleaning up")
                expire()
                return
            }
            Log.info("resuming block: \(BlockDuration.words(remaining)) left, \(active.plan.entries.count) entries")
            applyAll()
            persist()
            startTimer()
            scheduleResolve(force: true)
        case .missing:
            Log.info("no saved state; starting idle")
            ensureClean()
            persist()
        case .corrupt:
            Log.error("state is unreadable and no backup exists; staying idle without touching hosts or pf")
        }
    }

    /// Idle housekeeping: remove anything a previous run left behind.
    func ensureClean() {
        if hosts.stripAll() {
            hosts.flushDNSCache()
            Log.info("removed a leftover hosts section")
        }
        if !pf.simulated, pf.anchorRulesLoaded(ports: []) {
            pf.flushAnchor()
            Log.info("flushed a leftover pf anchor")
        }
    }

    // MARK: - Requests

    func status() -> StatusReport {
        guard let block, let countdown else {
            return StatusReport(state: .idle, lastBlockEndedAt: lastBlockEndedAt, testMode: paths.isTestMode)
        }
        let remaining = max(0, countdown.remaining(nowNs: MonotonicClock.nowNs()))
        return StatusReport(
            state: .active, remainingSeconds: remaining, expectedEnd: Date().addingTimeInterval(remaining),
            startedAt: block.startedAt, initialSeconds: block.initialSeconds, entries: block.plan.entries,
            hostsNames: block.plan.hostsNames, pfNames: block.plan.pfNames, ports: block.plan.ports,
            ipCount: block.resolved.count, lastResolveAt: block.lastResolveAt, lastCheckAt: lastCheckAt,
            pf: lastPFStatus, hostsOK: lastHostsOK, lastBlockEndedAt: lastBlockEndedAt, testMode: paths.isTestMode)
    }

    func start(entries rawEntries: [String], seconds: Int, expand: Bool) throws(DaemonError) -> StatusReport {
        guard block == nil else {
            throw DaemonError(
                .blockActive, "a block is already running (\(BlockDuration.words(currentRemaining)) left)")
        }
        guard seconds >= Identifiers.minBlockSeconds else {
            throw DaemonError(.invalidDuration, "a block must last at least \(Identifiers.minBlockSeconds) seconds")
        }
        guard seconds <= Identifiers.maxBlockSeconds else {
            throw DaemonError(
                .tooLong, "a block can last at most \(BlockDuration.words(Double(Identifiers.maxBlockSeconds)))")
        }
        let parsed = try parseEntries(rawEntries)
        guard !parsed.isEmpty else { throw DaemonError(.invalidEntry, "nothing to block") }

        let plan = BlockPlan.compile(parsed, expand: expand)
        let now = MonotonicClock.nowNs()
        block = ActiveBlock(
            startedAt: Date(), initialSeconds: seconds, remainingSeconds: Double(seconds),
            plan: plan, resolved: ResolvedSets(), pfTokens: [], lastResolveAt: nil)
        countdown = Countdown(remaining: Double(seconds), nowNs: now)
        unresolvedWarned = []
        Log.info("block started for \(BlockDuration.words(Double(seconds))): \(plan.entries.joined(separator: " "))")
        applyAll()
        persist()
        startTimer()
        scheduleResolve(force: true)
        return status()
    }

    func add(entries rawEntries: [String]) throws(DaemonError) -> (StatusReport, [String]) {
        guard var current = block else { throw DaemonError(.noBlock, "no block is running") }
        let parsed = try parseEntries(rawEntries)
        let before = Set(current.plan.entries)
        let newPlan = current.plan.adding(parsed)
        let added = newPlan.entries.filter { !before.contains($0) }
        guard !added.isEmpty else { return (status(), []) }
        guard newPlan.entries.count <= Identifiers.maxEntries else {
            throw DaemonError(.tooManyEntries, "a block can hold at most \(Identifiers.maxEntries) entries")
        }
        current.plan = newPlan
        block = current
        Log.info("added to the block: \(added.joined(separator: " "))")
        applyAll()
        persist()
        scheduleResolve(force: true)
        return (status(), added)
    }

    func extend(seconds: Int) throws(DaemonError) -> StatusReport {
        guard block != nil, var current = countdown else { throw DaemonError(.noBlock, "no block is running") }
        guard seconds > 0 else { throw DaemonError(.invalidDuration, "extension must be positive") }
        let now = MonotonicClock.nowNs()
        let newRemaining = current.remaining(nowNs: now) + Double(seconds)
        guard newRemaining <= Double(Identifiers.maxBlockSeconds) else {
            throw DaemonError(
                .tooLong,
                "a block can last at most \(BlockDuration.words(Double(Identifiers.maxBlockSeconds))) in total")
        }
        current.extend(by: Double(seconds), nowNs: now)
        countdown = current
        Log.info("block extended by \(BlockDuration.words(Double(seconds))); \(BlockDuration.words(newRemaining)) left")
        persist()
        return status()
    }

    private func parseEntries(_ raw: [String]) throws(DaemonError) -> [BlockEntry] {
        guard raw.count <= Identifiers.maxEntries else {
            throw DaemonError(.tooManyEntries, "a block can hold at most \(Identifiers.maxEntries) entries")
        }
        var out: [BlockEntry] = []
        for (index, text) in raw.enumerated() {
            do {
                out.append(try BlockEntry.parse(text))
            } catch {
                throw DaemonError(.invalidEntry, error.description, index: index)
            }
        }
        return out
    }

    // MARK: - Tick loop

    private func startTimer() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard block != nil, let countdown else {
            stopTimer()
            return
        }
        let now = MonotonicClock.nowNs()
        if countdown.remaining(nowNs: now) <= 0 {
            expire()
            return
        }
        if elapsed(since: lastPersistNs, now: now) >= Double(Identifiers.persistIntervalSeconds) { persist() }
        if elapsed(since: lastCheckNs, now: now) >= Double(Identifiers.integrityIntervalSeconds) {
            lastCheckNs = now
            verify()
        }
        if elapsed(since: lastResolveNs, now: now) >= Double(Identifiers.resolveIntervalSeconds) {
            scheduleResolve(force: false)
        }
    }

    private func elapsed(since: UInt64, now: UInt64) -> Double {
        since == 0 || now < since ? .infinity : Double(now - since) / 1_000_000_000
    }

    func forceVerify() {
        guard block != nil else { return }
        lastCheckNs = MonotonicClock.nowNs()
        verify()
    }

    func hostsChanged() {
        guard let block else { return }
        if !hosts.isCurrent(names: block.plan.hostsNames) {
            Log.warn("hosts file changed from outside; re-applying the block")
            applyHosts(block)
        }
    }

    // MARK: - Enforcement

    private func applyAll() {
        guard let block else { return }
        applyHosts(block)
        applyPF(block, newAddresses: [])
        lastCheckAt = Date()
    }

    private func applyHosts(_ block: ActiveBlock) {
        if hosts.ensure(names: block.plan.hostsNames) {
            hosts.flushDNSCache()
            Log.info("hosts section applied (\(block.plan.hostsNames.count) names)")
        }
        lastHostsOK = hosts.isCurrent(names: block.plan.hostsNames)
    }

    private func applyPF(_ block: ActiveBlock, newAddresses: Set<String>) {
        let tables = PFAnchor.expectedTables(plan: block.plan, resolved: block.resolved)
        pf.writeAnchorFile(ports: block.plan.ports)
        guard pf.loadAnchor() else {
            Log.error("could not load the pf anchor; will retry on the next check")
            lastPFStatus = pf.status(ports: block.plan.ports, expectedTables: tables, tokens: block.pfTokens)
            return
        }
        for (table, addresses) in tables {
            _ = pf.replaceTable(table, with: addresses)
        }
        let holdsReference = !(self.block?.pfTokens.isEmpty ?? true)
        if !holdsReference || !pf.isEnabled() {
            if let token = pf.enable() {
                self.block?.pfTokens.append(token)
                Log.info("pf enabled (reference token \(token))")
            }
        }
        if !newAddresses.isEmpty { pf.killStates(to: newAddresses) }
        lastPFStatus = pf.status(ports: block.plan.ports, expectedTables: tables, tokens: self.block?.pfTokens ?? [])
    }

    private func verify() {
        guard let block else { return }
        lastCheckAt = Date()
        if hosts.isCurrent(names: block.plan.hostsNames) {
            lastHostsOK = true
        } else {
            Log.warn("hosts section drifted; re-applying")
            applyHosts(block)
        }

        guard !pf.simulated else {
            lastPFStatus = pf.status(ports: block.plan.ports, expectedTables: [:], tokens: block.pfTokens)
            return
        }
        let now = MonotonicClock.nowNs()
        if !pf.mainRulesetHasWildcardAnchor() {
            let uptime = MonotonicClock.uptimeSeconds()
            if uptime < 60 {
                Log.warn("main pf ruleset is not loaded yet (\(Int(uptime)) s after boot); waiting")
            } else if elapsed(since: lastMainReloadNs, now: now) > 60 {
                Log.warn(
                    "main pf ruleset lacks anchor \"\(Identifiers.pfWildcardAnchor)\"; reloading \(Identifiers.pfConfPath)"
                )
                pf.reloadMainRuleset()
                lastMainReloadNs = now
            }
        }
        let tables = PFAnchor.expectedTables(plan: block.plan, resolved: block.resolved)
        let status = pf.status(ports: block.plan.ports, expectedTables: tables, tokens: block.pfTokens)
        if status.healthy {
            lastPFStatus = status
        } else {
            Log.warn(
                "pf drifted (enabled=\(status.enabled) mainAnchor=\(status.mainAnchorPresent) anchor=\(status.anchorLoaded) tables=\(status.tablesOK)); re-applying"
            )
            applyPF(block, newAddresses: [])
        }
    }

    // MARK: - Resolution

    private func scheduleResolve(force: Bool) {
        guard let block, !resolveInFlight else { return }
        let targets = block.plan.namesToResolve
        lastResolveNs = MonotonicClock.nowNs()
        guard !targets.isEmpty else { return }
        resolveInFlight = true
        Task { @MainActor [weak self] in
            let results = await Resolver.resolve(targets)
            self?.applyResolved(results)
        }
    }

    private func applyResolved(_ results: [ResolvedName]) {
        resolveInFlight = false
        guard var current = block else { return }
        var newByTable: [String: Set<String>] = [:]
        for result in results where !result.addresses.isEmpty {
            let added = current.resolved.add(result.addresses, port: result.port)
            if !added.isEmpty {
                let table = result.port.map(Identifiers.pfPortTable) ?? Identifiers.pfTable
                newByTable[table, default: []].formUnion(added)
            }
        }
        current.lastResolveAt = Date()
        block = current

        let unresolved = results.filter { $0.addresses.isEmpty }.map(\.name).filter { !unresolvedWarned.contains($0) }
        if !unresolved.isEmpty {
            Log.warn("no addresses found for: \(unresolved.joined(separator: " "))")
            unresolvedWarned.formUnion(unresolved)
        }
        let allNew = newByTable.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        guard !allNew.isEmpty else { return }
        Log.info("resolved \(allNew.count) new address(es)")
        var needFullApply = false
        for (table, addresses) in newByTable where !pf.addToTable(table, addresses) {
            needFullApply = true
        }
        if needFullApply {
            applyPF(current, newAddresses: allNew)
        } else {
            pf.killStates(to: allNew)
        }
        persist()
    }

    // MARK: - Expiry and persistence

    private func expire() {
        guard let block else { return }
        Log.info("block ended after \(BlockDuration.words(Double(block.initialSeconds)))")
        stopTimer()
        tearDown(names: block.plan.hostsNames, tokens: block.pfTokens)
        unresolvedWarned = []
        self.block = nil
        countdown = nil
        lastPFStatus = nil
        lastHostsOK = nil
        lastBlockEndedAt = Date()
        persist()
    }

    private func tearDown(names: [String], tokens: [String]) {
        if hosts.remove(names: names) { Log.info("hosts section removed") }
        hosts.flushDNSCache()
        pf.flushAnchor()
        for token in tokens { pf.release(token: token) }
        pf.removeTableFiles()
    }

    func persist() {
        let now = MonotonicClock.nowNs()
        lastPersistNs = now
        var saved = block
        if var active = saved, let countdown {
            active.remainingSeconds = max(0, countdown.remaining(nowNs: now))
            saved = active
        }
        let document = StateDocument(
            state: saved == nil ? .idle : .active, savedAt: Date(), bootUUID: bootUUID,
            savedMonotonicNs: now, block: saved, lastBlockEndedAt: lastBlockEndedAt)
        store.save(document)
    }
}
