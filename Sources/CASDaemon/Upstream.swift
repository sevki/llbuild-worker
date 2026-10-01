import CASClient
import CASProtocol
import Foundation

/// The shared store the daemon fronts: the Worker for one scope.
///
/// A protocol so the daemon's logic can be tested without a network, and so the
/// transport (today a WebSocket, later stateless HTTP/2 POST) can change without
/// touching it. Every call may fail; the daemon treats a failure as a miss.
public protocol CASUpstream: Sendable {
    func contains(_ digest: CASDigest) async throws -> Bool
    func get(_ digest: CASDigest) async throws -> CASBlob?
    func put(_ blob: CASBlob) async throws
    func actionGet(_ key: CASDigest) async throws -> CASDigest?
    func actionPut(_ key: CASDigest, value: CASDigest) async throws
    /// `actionGet` for many keys at once, answers in the keys' order.
    func actionGetMany(_ keys: [CASDigest]) async throws -> [CASDigest?]
    /// The trace kept under `key`: what an earlier build that began with that action
    /// looked up, in order. Nil if there is none.
    func traceGet(_ key: CASDigest) async throws -> [CASDigest]?
    func tracePut(_ key: CASDigest, keys: [CASDigest]) async throws
}

extension CASUpstream {
    /// For an upstream that keeps no traces.
    public func traceGet(_ key: CASDigest) async throws -> [CASDigest]? { nil }
    public func tracePut(_ key: CASDigest, keys: [CASDigest]) async throws {}
}

extension CASUpstream {
    /// For an upstream that cannot batch: the lookups run side by side.
    public func actionGetMany(_ keys: [CASDigest]) async throws -> [CASDigest?] {
        try await withThrowingTaskGroup(of: (Int, CASDigest?).self) { group in
            for (index, key) in keys.enumerated() {
                group.addTask { (index, try await self.actionGet(key)) }
            }
            var answers = [CASDigest?](repeating: nil, count: keys.count)
            for try await (index, value) in group { answers[index] = value }
            return answers
        }
    }
}

struct UpstreamUnsupported: Error, CustomStringConvertible {
    var what: String
    var description: String { "\(what) are not available from the Worker" }
}

struct UpstreamTimeout: Error, CustomStringConvertible {
    var description: String { "the Worker did not answer in time" }
}

/// The Worker, over `CASClient`. One client is held and shared by every call; if
/// a call fails (a connection the Worker dropped, say) it is replaced and the
/// call retried once, since every call here is idempotent.
public actor ClientUpstream: CASUpstream {
    private let url: URL
    private var client: CASClient?

    /// How the daemon reaches the Worker.
    public enum Transport: Sendable {
        /// POST when the Worker serves it (found by one probe), the WebSocket if not.
        case automatic
        case httpPost
        case webSocket
    }

    private let transport: Transport
    /// Whether the Worker serves POST, once known (only asked under `.automatic`).
    private var postServed: Bool?

    public init(url: URL, timeout: Duration = .seconds(30), transport: Transport = .automatic) {
        self.url = url
        self.callTimeout = timeout
        self.transport = transport
    }

    private var connecting: Task<CASClient, Error>?
    /// How many clients this upstream has made, for tests: calls that arrive together
    /// must share one.
    private(set) var clientsCreated = 0

    private func current() async throws -> CASClient {
        if let client { return client }
        // One connection attempt at a time: calls that arrive together wait for it, rather
        // than each opening (and probing) a client of its own.
        if let connecting { return try await connecting.value }
        let attempt = Task { [self] () -> CASClient in
            let created: CASClient
            switch transport {
            case .webSocket: created = try CASClient(workerURL: url)
            case .httpPost: created = try CASClient(workerURL: url, transport: .httpPost)
            case .automatic: created = try await automatic()
            }
            return created
        }
        connecting = attempt
        do {
            let created = try await attempt.value
            clientsCreated += 1
            client = created
            connecting = nil
            return created
        } catch {
            connecting = nil
            throw error
        }
    }

    /// POST if the Worker answers it, which is learned once: a stateless call has no
    /// connection that can go stale. A Worker without the endpoint gets the WebSocket.
    private func automatic() async throws -> CASClient {
        if postServed != false {
            let candidate = try CASClient(workerURL: url, transport: .httpPost)
            if postServed == true { return candidate }
            do {
                _ = try await withDeadline(callTimeout, { try await candidate.status() }, onTimeout: { await candidate.close() })
                postServed = true
                return candidate
            } catch {
                postServed = false
                await candidate.close()
            }
        }
        return try CASClient(workerURL: url)
    }

    private func discard(_ failed: CASClient) {
        // Only forget the client that failed: another call may already have
        // replaced it.
        guard client === failed else { return }
        client = nil
        Task { await failed.close() }
    }

    /// No call to the Worker may wait forever: a connection it has stopped answering
    /// (it does not always say so) would hold the call, and with it a build or the
    /// daemon's shutdown. A call that is not answered in `timeout` is failed by closing
    /// its connection, which also fails anything else waiting on it.
    private let callTimeout: Duration

    private func attempt<T: Sendable>(
        _ client: CASClient, _ operation: @escaping @Sendable (CASClient) async throws -> T
    ) async throws -> T {
        try await withDeadline(callTimeout, { try await operation(client) }, onTimeout: { [self] in await discard(client) })
    }

    private func call<T: Sendable>(_ operation: @escaping @Sendable (CASClient) async throws -> T) async throws -> T {
        let first = try await current()
        do {
            return try await attempt(first, operation)
        } catch {
            discard(first)
            let second = try await current()
            do {
                return try await attempt(second, operation)
            } catch {
                discard(second)
                throw error
            }
        }
    }

    public func contains(_ digest: CASDigest) async throws -> Bool {
        try await call { try await $0.contains(digest) }
    }

    public func get(_ digest: CASDigest) async throws -> CASBlob? {
        try await call { try await $0.get(digest) }
    }

    public func put(_ blob: CASBlob) async throws {
        try await call { _ = try await $0.put(blob) }
    }

    public func actionGet(_ key: CASDigest) async throws -> CASDigest? {
        try await call { try await $0.actionGet(key) }
    }

    public func actionPut(_ key: CASDigest, value: CASDigest) async throws {
        try await call { try await $0.actionPut(key, value: value) }
    }

    /// A Worker without traces fails these calls; after a few failures in a row they
    /// are not tried again (the caller sees the error, and counts it). Traces are only
    /// a hint.
    private var traceFailures = 0

    public func traceGet(_ key: CASDigest) async throws -> [CASDigest]? {
        guard traceFailures < 3 else { throw UpstreamUnsupported(what: "traces") }
        do {
            let trace = try await call { try await $0.traceGet(key) }
            traceFailures = 0
            return trace
        } catch {
            traceFailures += 1
            throw error
        }
    }

    public func tracePut(_ key: CASDigest, keys: [CASDigest]) async throws {
        guard traceFailures < 3 else { throw UpstreamUnsupported(what: "traces") }
        do {
            try await call { try await $0.tracePut(key, keys: keys) }
            traceFailures = 0
        } catch {
            traceFailures += 1
            throw error
        }
    }

    /// A Worker that predates the batch call fails it; after that, lookups go one
    /// at a time, as before.
    private var batchSupported = true

    public func actionGetMany(_ keys: [CASDigest]) async throws -> [CASDigest?] {
        if batchSupported {
            do {
                return try await call { try await $0.actionGetMany(keys) }
            } catch {
                // If a plain lookup fails too, the trouble is real; if it works, the
                // Worker just does not have the batch call.
                if let first = keys.first { _ = try await actionGet(first) }
                batchSupported = false
            }
        }
        return try await withThrowingTaskGroup(of: (Int, CASDigest?).self) { group in
            for (index, key) in keys.enumerated() {
                group.addTask { (index, try await self.actionGet(key)) }
            }
            var answers = [CASDigest?](repeating: nil, count: keys.count)
            for try await (index, value) in group { answers[index] = value }
            return answers
        }
    }
}

/// Reports the first of two outcomes, once.
private final class FirstResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    /// True if this result was the one reported.
    @discardableResult
    func report(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        let taken = continuation
        continuation = nil
        lock.unlock()
        guard let taken else { return false }
        taken.resume(with: result)
        return true
    }
}

/// Runs `operation`, but gives up on it after `timeout`. Unlike a task group's timer,
/// this returns on time even if the operation cannot be cancelled and never finishes
/// (a connection that was never answered): it is left behind, and `onTimeout` is the
/// chance to cut whatever it is waiting on.
func withDeadline<T: Sendable>(
    _ timeout: Duration, _ operation: @escaping @Sendable () async throws -> T,
    onTimeout: @escaping @Sendable () async -> Void
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let first = FirstResult(continuation)
        let work = Task {
            do {
                first.report(.success(try await operation()))
            } catch {
                first.report(.failure(error))
            }
        }
        Task {
            try? await Task.sleep(for: timeout)
            if first.report(.failure(UpstreamTimeout())) {
                work.cancel()
                await onTimeout()
            }
        }
    }
}
