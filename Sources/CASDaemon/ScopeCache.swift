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
    private let batchWindow: Duration
    private let log: @Sendable (String) -> Void

    private var actions: [CASDigest: CASDigest] = [:]
    private var misses: [CASDigest: ContinuousClock.Instant] = [:]
    /// Objects known to be upstream, so they are never asked about twice.
    private var uploaded = Set<CASDigest>()
    private var fetching: [CASDigest: Task<CASBlob?, Never>] = [:]
    private var uploading: [CASDigest: Task<Bool, Never>] = [:]
    private var forwarding: [CASDigest: Task<Void, Never>] = [:]

    private var lookups = 0
    private var batches = 0
    private var lookupTime = Duration.zero
    private var lookupSummary: String {
        let mean = lookups == 0 ? Duration.zero : lookupTime / lookups
        return "upstream actionGet: \(lookups) lookups in \(batches) calls, mean \(mean) each"
    }

    static let maxActionsInMemory = 500_000

    public init(
        directory: URL, maxBytes: Int64, upstream: any CASUpstream,
        maxActions: Int = 1_000_000, negativeTTL: Duration = .seconds(5), batchWindow: Duration = .milliseconds(3),
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
        self.batchWindow = batchWindow
        self.log = log
        try FileManager.default.createDirectory(at: actionDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: spoolDirectory, withIntermediateDirectories: true)
    }

    /// Re-queues the actions a previous run acknowledged but had not yet
    /// forwarded.
    public func resumePending() {
        sweepSpool()
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

    // MARK: Objects

    public func contains(_ digest: CASDigest) async -> Bool {
        if await objects.contains(digest) || isSpooled(digest) { return true }
        if uploaded.contains(digest) { return true }
        guard let found = try? await upstream.contains(digest) else { return false }
        if found { uploaded.insert(digest) }
        return found
    }

    public func get(_ digest: CASDigest) async -> CASBlob? {
        if let blob = await objects.get(digest) ?? readSpool(digest) { return blob }
        if let inflight = fetching[digest] { return await inflight.value }
        let task = Task { [self] () -> CASBlob? in
            let blob = try? await upstream.get(digest)
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
        let digest = blob.digest
        if !uploaded.contains(digest) { try writeSpool(blob) }
        _ = try await objects.put(blob)
    }

    // MARK: Actions

    public func actionGet(_ key: CASDigest) async -> CASDigest? {
        if let value = actions[key] ?? readAction(key) {
            actions[key] = value
            return value
        }
        if let since = misses[key], ContinuousClock.now - since < negativeTTL { return nil }
        let started = ContinuousClock.now
        let found = await lookUpstream(key)
        lookups += 1
        lookupTime += ContinuousClock.now - started
        if lookups % 50 == 0 { log(lookupSummary) }
        let value: CASDigest
        switch found {
        case .failed:
            return nil
        case .miss:
            misses[key] = .now
            return nil
        case .hit(let hit):
            value = hit
        }
        remember(key: key, value: value)
        // The value and what it references follow, ahead of the compiler asking.
        prefetch([value])
        return value
    }

    // MARK: Batched lookups

    private enum Lookup: Sendable {
        case hit(CASDigest), miss, failed
    }

    private var waiting: [CASDigest: [CheckedContinuation<Lookup, Never>]] = [:]
    private var flushScheduled = false

    /// Lookups that arrive within `batchWindow` of each other share one upstream
    /// call; a build's many compiler processes ask at about the same moment.
    private func lookUpstream(_ key: CASDigest) async -> Lookup {
        await withCheckedContinuation { continuation in
            waiting[key, default: []].append(continuation)
            if waiting.count >= CASLimits.maxBatchKeys {
                flush()
            } else if !flushScheduled {
                flushScheduled = true
                Task { [self, batchWindow] in
                    try? await Task.sleep(for: batchWindow)
                    flush()
                }
            }
        }
    }

    private func flush() {
        flushScheduled = false
        guard !waiting.isEmpty else { return }
        let batch = waiting
        waiting = [:]
        batches += 1
        Task { [self] in
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
    }

    /// Acknowledged when recorded locally; the upload happens behind it.
    public func actionPut(_ key: CASDigest, value: CASDigest) {
        remember(key: key, value: value)
        misses[key] = nil
        writePending(key)
        forward(key: key, value: value)
    }

    /// Waits until everything acknowledged so far has reached upstream (or
    /// given up); for shutdown and tests.
    public func drain() async {
        while let task = forwarding.values.first {
            await task.value
        }
    }

    public var pendingCount: Int { forwarding.count }

    private func remember(key: CASDigest, value: CASDigest) {
        if actions.count >= Self.maxActionsInMemory { actions.removeAll(keepingCapacity: true) }
        actions[key] = value
        writeAction(key, value)
    }

    private func forward(key: CASDigest, value: CASDigest) {
        guard forwarding[key] == nil else { return }
        forwarding[key] = Task { [self] in
            var delay = Duration.milliseconds(250)
            for attempt in 1...6 {
                if await upload(value), (try? await upstream.actionPut(key, value: value)) != nil {
                    clearPending(key)
                    break
                }
                if attempt == 6 {
                    log("giving up for now on action \(key.hex); it stays queued on disk")
                    break
                }
                try? await Task.sleep(for: delay)
                delay *= 2
            }
            forwarding[key] = nil
        }
    }

    /// Uploads `digest` and everything below it, children first. False if any
    /// of it could not be sent.
    private func upload(_ digest: CASDigest) async -> Bool {
        if uploaded.contains(digest) { return true }
        if let inflight = uploading[digest] { return await inflight.value }
        let task = Task { [self] () -> Bool in
            guard let blob = await objects.get(digest) ?? readSpool(digest) else {
                log("cannot upload \(digest.hex): not in the local cache")
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
    private func writeAction(_ key: CASDigest, _ value: CASDigest) {
        let file = shard(actionDirectory, key.hex)
        let existed = FileManager.default.fileExists(atPath: file.path)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(value.hex.utf8).write(to: file, options: .atomic)
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

    private func writePending(_ key: CASDigest) {
        FileManager.default.createFile(atPath: pendingDirectory.appendingPathComponent(key.hex).path, contents: Data())
    }

    private func clearPending(_ key: CASDigest) {
        try? FileManager.default.removeItem(at: pendingDirectory.appendingPathComponent(key.hex))
    }

    // The spool

    private func isSpooled(_ digest: CASDigest) -> Bool {
        FileManager.default.fileExists(atPath: shard(spoolDirectory, digest.hex).path)
    }

    private func writeSpool(_ blob: CASBlob) throws {
        let file = shard(spoolDirectory, blob.digest.hex)
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ObjectCache.encode(blob).write(to: file, options: .atomic)
    }

    private func readSpool(_ digest: CASDigest) -> CASBlob? {
        guard let data = FileManager.default.contents(atPath: shard(spoolDirectory, digest.hex).path) else { return nil }
        return ObjectCache.decode(data)
    }

    private func removeSpool(_ digest: CASDigest) {
        try? FileManager.default.removeItem(at: shard(spoolDirectory, digest.hex))
    }

    /// Spooled objects that no action ever claimed (the client died between storing
    /// and recording) are dropped after a day, at start-up.
    private func sweepSpool() {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let files = FileManager.default.enumerator(
            at: spoolDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
        while let file = files?.nextObject() as? URL {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            if values?.isRegularFile == true, (values?.contentModificationDate ?? .distantFuture) < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
