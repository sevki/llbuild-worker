import CASProtocol
import Foundation

/// One scope's cache: what a build in that scope sees instead of the Worker.
///
/// - Objects are served from the local `ObjectCache`; a miss is fetched from
///   upstream once (concurrent requests share the fetch), stored, and the
///   object's references are fetched right behind it, because whoever asked for
///   an object is about to ask for what it points at.
/// - A looked-up action pulls its whole value closure the same way, so the
///   compiler's following reads are local.
/// - Writes are acknowledged once local. An action is forwarded upstream only
///   after everything it references is there (the Worker refuses an action whose
///   value it does not hold), by a background task that retries; the pending
///   actions are files, so a restart carries on where it stopped.
/// - Upstream trouble is a miss, never an error: a build without the remote is
///   slower, not broken.
public actor ScopeCache {
    public let objects: ObjectCache
    private let upstream: any CASUpstream
    private let actionDirectory: URL
    private let pendingDirectory: URL
    /// Objects a client stored that are not upstream yet. The object cache evicts
    /// whatever is least recently used, so it cannot be what an acknowledged write
    /// waits in: a file here stays until it has been uploaded.
    private let spoolDirectory: URL
    private let negativeTTL: Duration
    private let retryInterval: Duration
    private let sessionGap: Duration
    private let traceDebounce: Duration
    private let fetchSlots: AsyncSemaphore
    private let lookupSlots = AsyncSemaphore(4)
    private var retrier: Task<Void, Never>?
    /// Bumped by every action recorded, so a sweep can tell that one arrived while
    /// it was looking.
    private var pendingGeneration = 0
    private let log: @Sendable (String) -> Void

    private var actions: [CASDigest: CASDigest] = [:]
    private var misses: [CASDigest: ContinuousClock.Instant] = [:]
    /// Objects known to be upstream, so they are never asked about twice.
    private var uploaded = Set<CASDigest>() {
        didSet {
            // Forgetting only costs another upstream check, so a long-lived
            // daemon's set is kept from growing without bound.
            if uploaded.count > Self.maxKnownUpstream { uploaded.removeAll(keepingCapacity: false) }
        }
    }
    private static let maxKnownUpstream = 500_000
    private var fetching: [CASDigest: Task<CASBlob?, Never>] = [:]
    private var uploading: [CASDigest: Task<Bool, Never>] = [:]
    private var forwarding: [CASDigest: Task<Void, Never>] = [:]

    private var lookups = 0
    private var batches = 0
    private var objectFetches = 0
    private var objectBytes = 0
    private var objectFetchTime = Duration.zero
    private var maxObjectFetchesAtOnce = 0
    private var objectFetchesNow = 0
    private var uploadedObjects = 0
    private var uploadedActions = 0
    private var lookupTime = Duration.zero

    static let maxActionsInMemory = 500_000

    public init(
        directory: URL, maxBytes: Int64, upstream: any CASUpstream,
        maxActions: Int = 1_000_000, negativeTTL: Duration = .seconds(5), retryInterval: Duration = .seconds(60),
        sessionGap: Duration = .seconds(300), traceDebounce: Duration = .seconds(20), maxObjectFetches: Int = 32,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws {
        self.objects = try await ObjectCache.open(
            directory: directory.appendingPathComponent("objects"), maxBytes: maxBytes)
        self.upstream = upstream
        self.actionDirectory = directory.appendingPathComponent("actions")
        self.pendingDirectory = directory.appendingPathComponent("pending")
        self.spoolDirectory = directory.appendingPathComponent("spool")
        self.maxActionFiles = maxActions
        self.negativeTTL = negativeTTL
        self.retryInterval = retryInterval
        self.sessionGap = sessionGap
        self.traceDebounce = traceDebounce
        self.fetchSlots = AsyncSemaphore(maxObjectFetches)
        self.log = log
        try FileManager.default.createDirectory(at: actionDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: spoolDirectory, withIntermediateDirectories: true)
    }

    /// Re-queues the actions a previous run acknowledged but had not yet
    /// forwarded.
    public func resumePending() async {
        startRetrying()
        await sweepSpool()
        countActions()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: pendingDirectory.path)) ?? []
        for name in names {
            guard let key = CASDigest(hex: name), key.bytes.count == CASIdentity.digestSize,
                  let value = readAction(key) else {
                try? FileManager.default.removeItem(at: pendingDirectory.appendingPathComponent(name))
                continue
            }
            forward(key: key, value: value)
        }
    }

    // MARK: Retiring

    private var retired = false
    private var users = 0

    /// Marks the scope as in use (a connection, a request) so it is not retired under
    /// the user; false if it already has been, and the caller must look the scope up
    /// again.
    func beginUse() -> Bool {
        guard !retired else { return false }
        users += 1
        return true
    }

    func endUse() {
        users -= 1
    }

    /// Whether everything acknowledged here has reached upstream: nothing waits on
    /// disk and nothing is being forwarded.
    private var isIdle: Bool {
        users == 0 && forwarding.isEmpty
            && ((try? FileManager.default.contentsOfDirectory(atPath: pendingDirectory.path))?.isEmpty ?? true)
    }

    /// Stops this scope's background work and refuses further writes, if it has
    /// nothing pending; false, and no change, if it has. The daemon retires idle
    /// scopes to keep the number it holds open bounded.
    func retire() async -> Bool {
        guard isIdle else { return false }
        await flushTrace()
        retired = true
        retrier?.cancel()
        retrier = nil
        traceFlush?.cancel()
        return true
    }

    private func requireOpen() throws {
        if retired { throw CASServiceError.storageNotConfigured }
    }

    // MARK: Objects

    public func contains(_ digest: CASDigest) async -> Bool {
        if await objects.containsVerified(digest) || isSpooled(digest) { return true }
        if uploaded.contains(digest) { return true }
        guard let found = try? await upstream.contains(digest) else { return false }
        if found { uploaded.insert(digest) }
        return found
    }

    public func get(_ digest: CASDigest) async -> CASBlob? {
        if let blob = await objects.get(digest) ?? readSpool(digest) { return blob }
        if let inflight = fetching[digest] { return await inflight.value }
        let task = Task { [self] () -> CASBlob? in
            // The check above can be stale: another fetch may have stored this object
            // and finished while it was being made. Look once more, here, before going
            // upstream.
            if let local = await objects.get(digest) { return local }
            objectFetchesNow += 1
            maxObjectFetchesAtOnce = max(maxObjectFetchesAtOnce, objectFetchesNow)
            await fetchSlots.acquire()
            let started = ContinuousClock.now
            let blob = try? await upstream.get(digest)
            await fetchSlots.release()
            objectFetchesNow -= 1
            objectFetches += 1
            objectFetchTime += ContinuousClock.now - started
            objectBytes += blob?.data.count ?? 0
            if let blob, blob.digest == digest {
                await adopt(blob)
                return blob
            }
            return nil
        }
        fetching[digest] = task
        let blob = await task.value
        fetching[digest] = nil
        return blob
    }

    /// Keeps an object that came from upstream and starts on what it references.
    private func adopt(_ blob: CASBlob) async {
        let digest = blob.digest
        uploaded.insert(digest)
        _ = try? await objects.put(blob)
        prefetch(blob.refs)
    }

    private func prefetch(_ digests: [CASDigest]) {
        for digest in digests {
            Task { [self] in _ = await get(digest) }
        }
    }

    /// Stores an object a client made, acknowledged once it is on disk. It is
    /// forwarded with the action that first references it; until then it is kept in
    /// the spool, where the cache's eviction cannot take it.
    public func put(_ blob: CASBlob) async throws {
        try requireOpen()
        let digest = blob.digest
        await sweepSpoolIfDue()
        if !uploaded.contains(digest) { try writeSpool(blob) }
        _ = try await objects.put(blob)
    }

    // MARK: Actions

    public func actionGet(_ key: CASDigest) async -> CASDigest? {
        noteLookup(key)
        if let value = actions[key] ?? readAction(key) {
            actions[key] = value
            return value
        }
        if let since = misses[key], ContinuousClock.now - since < negativeTTL { return nil }
        let started = ContinuousClock.now
        let found = await lookUpstream(key)
        lookups += 1
        lookupTime += ContinuousClock.now - started
        let value: CASDigest
        switch found {
        case .failed:
            return nil
        case .miss:
            noteMiss(key)
            return nil
        case .hit(let hit):
            value = hit
        }
        remember(key: key, value: value)
        // The value and what it references follow, ahead of the compiler asking.
        prefetch([value])
        return value
    }

    // MARK: Traces

    /// The lookups of one build, as the daemon sees it: a build is a run of lookups
    /// with no pause longer than `sessionGap`. Its keys, in the order they were first
    /// asked, are uploaded under the first one (debounced, and when the build ends),
    /// so that the next build that starts with the same action can be prefetched.
    private struct Session {
        var first: CASDigest
        var keys: [CASDigest] = []
        var seen = Set<CASDigest>()
        var last = ContinuousClock.now
        /// The trace this session was prefetched from; uploading an identical one
        /// would change nothing.
        var loaded: [CASDigest]?
        var uploaded = false
    }

    private var session: Session?
    private var traceFlush: Task<Void, Never>?
    private var traceLookups = 0
    private var traceHits = 0
    private var tracesUploaded = 0

    private func noteLookup(_ key: CASDigest) {
        let now = ContinuousClock.now
        if let current = session, now - current.last > sessionGap {
            Task { [self] in await upload(trace: current) }
            session = nil
        }
        if session == nil {
            session = Session(first: key)
            startPrefetch(from: key)
        }
        session?.last = now
        guard var current = session, !current.seen.contains(key), current.keys.count < CASLimits.maxTraceKeys else { return }
        current.seen.insert(key)
        current.keys.append(key)
        current.uploaded = false
        session = current
        traceFlush?.cancel()
        traceFlush = Task { [self, traceDebounce] in
            try? await Task.sleep(for: traceDebounce)
            guard !Task.isCancelled else { return }
            await flushTrace()
        }
    }

    /// Uploads the current session's trace now, unless it is empty, unchanged since
    /// the last upload, or what it was prefetched from.
    public func flushTrace() async {
        guard let current = session else { return }
        await upload(trace: current)
        session?.uploaded = true
    }

    private func upload(trace current: Session) async {
        guard current.keys.count >= 2, !current.uploaded, current.keys != current.loaded else { return }
        if (try? await upstream.tracePut(current.first, keys: current.keys)) != nil { tracesUploaded += 1 }
    }

    /// At the start of a build, reads the trace an earlier one left under its first
    /// action and asks for everything in it, in order, ahead of the compiler.
    private func startPrefetch(from first: CASDigest) {
        Task { [self] in
            guard let trace = try? await upstream.traceGet(first), !trace.isEmpty else { return }
            session?.loaded = trace
            await prefetch(trace: trace)
        }
    }

    private func prefetch(trace: [CASDigest]) async {
        var wanted: [CASDigest] = []
        for key in trace where actions[key] == nil && readAction(key) == nil { wanted.append(key) }
        var chunks: [[CASDigest]] = []
        var index = 0
        while index < wanted.count {
            chunks.append(Array(wanted[index..<min(index + CASLimits.maxBatchKeys, wanted.count)]))
            index += CASLimits.maxBatchKeys
        }
        await withTaskGroup(of: Void.self) { group in
            for chunk in chunks {
                group.addTask { await self.prefetch(chunk: chunk) }
            }
        }
    }

    private func prefetch(chunk: [CASDigest]) async {
        await lookupSlots.acquire()
        let answers = try? await upstream.actionGetMany(chunk)
        await lookupSlots.release()
        guard let answers, answers.count == chunk.count else { return }
        traceLookups += chunk.count
        for (key, answer) in zip(chunk, answers) {
            if let value = answer {
                traceHits += 1
                remember(key: key, value: value)
                prefetchObjects(of: value)
            } else {
                noteMiss(key)
            }
        }
    }

    private func prefetchObjects(of value: CASDigest) {
        Task { [self] in _ = await get(value) }
    }

    // MARK: Batched lookups

    private enum Lookup: Sendable {
        case hit(CASDigest), miss, failed
    }

    private var waiting: [CASDigest: [CheckedContinuation<Lookup, Never>]] = [:]
    private var callsInFlight = 0
    private static let maxCallsInFlight = 2

    /// Lookups are batched by what piles up while a call is out, not by a timer: one
    /// that finds the upstream idle goes at once (no added latency), and while calls
    /// are in flight new ones accumulate and go together when one returns. So the
    /// longer the round trip, the larger the batches, which is when they pay.
    private func lookUpstream(_ key: CASDigest) async -> Lookup {
        await withCheckedContinuation { continuation in
            waiting[key, default: []].append(continuation)
            sendWaiting()
        }
    }

    private func sendWaiting() {
        while !waiting.isEmpty, callsInFlight < Self.maxCallsInFlight {
            var batch: [CASDigest: [CheckedContinuation<Lookup, Never>]] = [:]
            for key in waiting.keys.prefix(CASLimits.maxBatchKeys) { batch[key] = waiting.removeValue(forKey: key) }
            callsInFlight += 1
            batches += 1
            Task { [self] in
                await send(batch)
                callsInFlight -= 1
                sendWaiting()
            }
        }
    }

    private func send(_ batch: [CASDigest: [CheckedContinuation<Lookup, Never>]]) async {
        let keys = Array(batch.keys)
        let answers: [CASDigest?]?
        do {
            answers = try await upstream.actionGetMany(keys)
        } catch {
            answers = nil
        }
        for (index, key) in keys.enumerated() {
            let result: Lookup
            if let answers, answers.count == keys.count {
                result = answers[index].map { .hit($0) } ?? .miss
            } else {
                result = .failed
            }
            for waiter in batch[key] ?? [] { waiter.resume(returning: result) }
        }
    }

    /// Acknowledged when recorded locally; the upload happens behind it.
    /// Throws if it could not be recorded on disk (a full or unwritable cache
    /// directory): acknowledging it then would lose it on a restart.
    public func actionPut(_ key: CASDigest, value: CASDigest) throws {
        try requireOpen()
        // An action key is immutable, as at the Worker: the first value stays, a
        // repeat of it is fine, a different one is refused.
        if let existing = actions[key] ?? readAction(key), existing != value {
            throw CASServiceError.invalidDigest(key.hex)
        }
        // The pending marker first: pruning old records (inside `writeAction`) spares
        // what is pending, and this record must be spared too.
        try writePending(key)
        do {
            try writeAction(key, value)
        } catch {
            clearPending(key)
            throw error
        }
        actions[key] = value
        misses[key] = nil
        pendingGeneration += 1
        forward(key: key, value: value)
    }

    /// Waits until everything acknowledged so far has reached upstream (or
    /// given up); for shutdown and tests.
    public func drain() async {
        await flushTrace()
        while let task = forwarding.values.first {
            await task.value
        }
    }

    public var pendingCount: Int { forwarding.count }

    /// What this scope asked of the Worker, for a line in the daemon's log.
    public var summary: String {
        let lookupMean = lookups == 0 ? Duration.zero : lookupTime / lookups
        let fetchMean = objectFetches == 0 ? Duration.zero : objectFetchTime / objectFetches
        let trace = "trace: \(traceHits) of \(traceLookups) prefetched actions hit, \(tracesUploaded) uploaded; "
        return trace + "\(lookups) action lookups in \(batches) calls (mean \(lookupMean) each); "
            + "\(objectFetches) objects fetched, \(objectBytes) bytes, mean \(fetchMean) each, at most \(maxObjectFetchesAtOnce) at once"
    }

    private static let maxRememberedMisses = 20_000

    /// A miss is remembered briefly; past `maxRememberedMisses` the expired ones
    /// are dropped, and if the rest are all fresh the table starts over.
    private func noteMiss(_ key: CASDigest) {
        if misses.count >= Self.maxRememberedMisses {
            let now = ContinuousClock.now
            misses = misses.filter { now - $0.value < negativeTTL }
            if misses.count >= Self.maxRememberedMisses { misses.removeAll() }
        }
        misses[key] = .now
    }

    private func remember(key: CASDigest, value: CASDigest) {
        if actions.count >= Self.maxActionsInMemory { actions.removeAll(keepingCapacity: true) }
        actions[key] = value
        try? writeAction(key, value)
    }

    private func forward(key: CASDigest, value: CASDigest) {
        guard forwarding[key] == nil else { return }
        forwarding[key] = Task { [self] in
            var delay = Duration.milliseconds(250)
            for attempt in 1...3 {
                if await upload(value), (try? await upstream.actionPut(key, value: value)) != nil {
                    clearPending(key)
                    break
                }
                // Upstream may already hold a different value for this key (another
                // machine got there first): it wins, and this write is moot.
                if let held = try? await upstream.actionGet(key), held != value {
                    remember(key: key, value: held)
                    clearPending(key)
                    break
                }
                if attempt == 3 {
                    log("action \(key.hex) is queued on disk; it will be retried")
                    break
                }
                try? await Task.sleep(for: delay)
                delay *= 2
            }
            forwarding[key] = nil
        }
    }

    /// Re-queues what is still pending, every `retryInterval`, for as long as the
    /// daemon runs: a Worker that was unreachable for a while gets what it missed
    /// once it is back, without a restart.
    private func startRetrying() {
        guard retrier == nil else { return }
        retrier = Task { [weak self, retryInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: retryInterval)
                await self?.requeuePending()
            }
        }
    }

    private func requeuePending() {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: pendingDirectory.path)) ?? [] {
            guard let key = CASDigest(hex: name), key.bytes.count == CASIdentity.digestSize,
                  let value = actions[key] ?? readAction(key) else { continue }
            forward(key: key, value: value)
        }
    }

    /// Uploads `digest` and everything below it, children first. False if any
    /// of it could not be sent.
    private func upload(_ digest: CASDigest) async -> Bool {
        if uploaded.contains(digest) { return true }
        if let inflight = uploading[digest] { return await inflight.value }
        let task = Task { [self] () -> Bool in
            guard let blob = await objects.get(digest) ?? readSpool(digest) else {
                // Not here, but it need not be: an object that came from upstream was
                // never sent to us, and after a restart nothing remembers that. What
                // upstream holds has its references too.
                if (try? await upstream.contains(digest)) == true {
                    uploaded.insert(digest)
                    return true
                }
                log("cannot upload \(digest.hex): not local and not upstream")
                return false
            }
            let children = Set(blob.refs)
            let childrenSent = await withTaskGroup(of: Bool.self) { group in
                for child in children { group.addTask { await self.upload(child) } }
                var all = true
                for await sent in group where !sent { all = false }
                return all
            }
            guard childrenSent else { return false }
            do {
                if try await !upstream.contains(digest) { try await upstream.put(blob) }
            } catch {
                return false
            }
            uploaded.insert(digest)
            removeSpool(digest)
            return true
        }
        uploading[digest] = task
        let sent = await task.value
        uploading[digest] = nil
        return sent
    }

    // MARK: Files

    private func shard(_ directory: URL, _ name: String) -> URL {
        directory.appendingPathComponent(String(name.prefix(2)), isDirectory: true).appendingPathComponent(name)
    }

    private func readAction(_ key: CASDigest) -> CASDigest? {
        guard let data = FileManager.default.contents(atPath: shard(actionDirectory, key.hex).path),
              let text = String(data: data, encoding: .utf8),
              let value = CASDigest(hex: text), value.bytes.count == CASIdentity.digestSize else { return nil }
        return value
    }

    /// One small file per action. The count is capped (`maxActionFiles`): past it
    /// the oldest are deleted, except those still waiting to be forwarded.
    private func writeAction(_ key: CASDigest, _ value: CASDigest) throws {
        let file = shard(actionDirectory, key.hex)
        let existed = FileManager.default.fileExists(atPath: file.path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.hex.utf8).write(to: file, options: .atomic)
        guard !existed else { return }
        actionFiles += 1
        if actionFiles > maxActionFiles + maxActionFiles / 10 { pruneActions() }
    }

    private var actionFiles = 0
    private let maxActionFiles: Int

    private func actionFileList() -> [(url: URL, modified: Date)] {
        var found: [(URL, Date)] = []
        let files = FileManager.default.enumerator(
            at: actionDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
        while let file = files?.nextObject() as? URL {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            found.append((file, values?.contentModificationDate ?? .distantPast))
        }
        return found
    }

    private func countActions() {
        actionFiles = actionFileList().count
        if actionFiles > maxActionFiles { pruneActions() }
    }

    private func pruneActions() {
        let target = maxActionFiles * 9 / 10
        var excess = actionFileList().sorted { $0.modified < $1.modified }
        var remaining = excess.count
        excess.removeAll { FileManager.default.fileExists(atPath: pendingDirectory.appendingPathComponent($0.url.lastPathComponent).path) }
        for entry in excess where remaining > target {
            try? FileManager.default.removeItem(at: entry.url)
            if let key = CASDigest(hex: entry.url.lastPathComponent) { actions[key] = nil }
            remaining -= 1
        }
        actionFiles = remaining
    }

    private func writePending(_ key: CASDigest) throws {
        try Data().write(to: pendingDirectory.appendingPathComponent(key.hex), options: .atomic)
    }

    private func clearPending(_ key: CASDigest) {
        try? FileManager.default.removeItem(at: pendingDirectory.appendingPathComponent(key.hex))
    }

    // The spool

    /// Whether a good copy is spooled: a file that is cut short or is another object
    /// does not count, and is removed so it can be replaced.
    private func isSpooled(_ digest: CASDigest) -> Bool {
        let file = shard(spoolDirectory, digest.hex)
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        if readSpool(digest) != nil { return true }
        try? FileManager.default.removeItem(at: file)
        return false
    }

    private func writeSpool(_ blob: CASBlob) throws {
        let file = shard(spoolDirectory, blob.digest.hex)
        if isSpooled(blob.digest) {
            // Already held, but it now has a new claim on it: refresh its age so a
            // sweep that listed it as old does not take it (see `sweepSpool`).
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ObjectCache.encode(blob).write(to: file, options: .atomic)
    }

    private func readSpool(_ digest: CASDigest) -> CASBlob? {
        guard let data = FileManager.default.contents(atPath: shard(spoolDirectory, digest.hex).path),
              let blob = ObjectCache.decode(data), blob.digest == digest else { return nil }
        return blob
    }

    private func removeSpool(_ digest: CASDigest) {
        try? FileManager.default.removeItem(at: shard(spoolDirectory, digest.hex))
    }

    private var lastSweep = Date()
    private static let spoolMaxAge: TimeInterval = 24 * 3600

    /// Spooled objects that no action ever claimed (the client died between storing
    /// and recording) are dropped after a day, at start-up and then hourly while the
    /// daemon runs. What a pending action can still reach is kept however old.
    private func sweepSpool() async {
        lastSweep = Date()
        let cutoff = Date().addingTimeInterval(-Self.spoolMaxAge)
        var old: [URL] = []
        let files = FileManager.default.enumerator(
            at: spoolDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
        while let file = files?.nextObject() as? URL {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            if values?.isRegularFile == true, (values?.contentModificationDate ?? .distantFuture) < cutoff {
                old.append(file)
            }
        }
        guard !old.isEmpty else { return }
        // Walking what pending actions reach suspends, and an action recorded
        // meanwhile could claim one of these files. So: delete only if none arrived
        // during the walk (the deletion itself does not suspend), else look again,
        // and leave it for the next sweep if it keeps happening.
        for _ in 0..<3 {
            let generation = pendingGeneration
            let keep = await reachableFromPending()
            guard generation == pendingGeneration else { continue }
            for file in old where !keep.contains(file.lastPathComponent) {
                // Still as old as when it was listed? A PUT since then refreshed it.
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard let modified, modified < cutoff else { continue }
                try? FileManager.default.removeItem(at: file)
            }
            return
        }
    }

    /// Hex digests of everything the pending actions' values reach.
    private func reachableFromPending() async -> Set<String> {
        var seen = Set<String>()
        var queue: [CASDigest] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: pendingDirectory.path)) ?? [] {
            if let key = CASDigest(hex: name), let value = readAction(key) { queue.append(value) }
        }
        while let digest = queue.popLast() {
            guard seen.insert(digest.hex).inserted else { continue }
            if let blob = await objects.get(digest) ?? readSpool(digest) { queue.append(contentsOf: blob.refs) }
        }
        return seen
    }

    private func sweepSpoolIfDue() async {
        if Date().timeIntervalSince(lastSweep) > 3600 { await sweepSpool() }
    }
}
