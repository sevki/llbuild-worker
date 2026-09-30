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
    private let negativeTTL: Duration
    private let log: @Sendable (String) -> Void

    private var actions: [CASDigest: CASDigest] = [:]
    private var misses: [CASDigest: ContinuousClock.Instant] = [:]
    /// Objects known to be upstream, so they are never asked about twice.
    private var uploaded = Set<CASDigest>()
    private var fetching: [CASDigest: Task<CASBlob?, Never>] = [:]
    private var uploading: [CASDigest: Task<Bool, Never>] = [:]
    private var forwarding: [CASDigest: Task<Void, Never>] = [:]

    static let maxActionsInMemory = 500_000

    public init(
        directory: URL, maxBytes: Int64, upstream: any CASUpstream,
        negativeTTL: Duration = .seconds(5), log: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws {
        self.objects = try await ObjectCache.open(
            directory: directory.appendingPathComponent("objects"), maxBytes: maxBytes)
        self.upstream = upstream
        self.actionDirectory = directory.appendingPathComponent("actions")
        self.pendingDirectory = directory.appendingPathComponent("pending")
        self.negativeTTL = negativeTTL
        self.log = log
        try FileManager.default.createDirectory(at: actionDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
    }

    /// Re-queues the actions a previous run acknowledged but had not yet
    /// forwarded.
    public func resumePending() {
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
        if await objects.contains(digest) { return true }
        if uploaded.contains(digest) { return true }
        guard let found = try? await upstream.contains(digest) else { return false }
        if found { uploaded.insert(digest) }
        return found
    }

    public func get(_ digest: CASDigest) async -> CASBlob? {
        if let blob = await objects.get(digest) { return blob }
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

    /// Stores an object a client made. It is forwarded with the action that
    /// first references it; one too big to keep locally is sent upstream now, as
    /// it could not be found later.
    public func put(_ blob: CASBlob) async throws {
        let digest = blob.digest
        _ = try await objects.put(blob)
        if await !objects.contains(digest) {
            try await upstream.put(blob)
            uploaded.insert(digest)
        }
    }

    // MARK: Actions

    public func actionGet(_ key: CASDigest) async -> CASDigest? {
        if let value = actions[key] ?? readAction(key) {
            actions[key] = value
            return value
        }
        if let since = misses[key], ContinuousClock.now - since < negativeTTL { return nil }
        let found: CASDigest?
        do {
            found = try await upstream.actionGet(key)
        } catch {
            return nil
        }
        guard let value = found else {
            misses[key] = .now
            return nil
        }
        remember(key: key, value: value)
        // The value and what it references follow, ahead of the compiler asking.
        prefetch([value])
        return value
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
            guard let blob = await objects.get(digest) else {
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
            return true
        }
        uploading[digest] = task
        let sent = await task.value
        uploading[digest] = nil
        return sent
    }

    // MARK: Files

    private func path(_ directory: URL, _ key: CASDigest) -> URL {
        directory.appendingPathComponent(key.hex)
    }

    private func readAction(_ key: CASDigest) -> CASDigest? {
        guard let data = FileManager.default.contents(atPath: path(actionDirectory, key).path),
              let text = String(data: data, encoding: .utf8),
              let value = CASDigest(hex: text), value.bytes.count == CASIdentity.digestSize else { return nil }
        return value
    }

    private func writeAction(_ key: CASDigest, _ value: CASDigest) {
        try? Data(value.hex.utf8).write(to: path(actionDirectory, key), options: .atomic)
    }

    private func writePending(_ key: CASDigest) {
        FileManager.default.createFile(atPath: path(pendingDirectory, key).path, contents: Data())
    }

    private func clearPending(_ key: CASDigest) {
        try? FileManager.default.removeItem(at: path(pendingDirectory, key))
    }
}
