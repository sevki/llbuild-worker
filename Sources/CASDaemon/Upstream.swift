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
    /// Whether the connection in use is POST (`.automatic` starts with POST if the Worker
    /// answers it, else falls back to the WebSocket, and looks again from time to time).
    private(set) var usesPost = false
    private var postServed: Bool?
    private var postRetryAt: Date?
    private var postRetryDelay: Duration
    private var upgrading = false

    public init(url: URL, timeout: Duration = .seconds(30), transport: Transport = .automatic, postRetryDelay: Duration = .seconds(300)) {
        self.url = url
        self.callTimeout = timeout
        self.transport = transport
        self.postRetryDelay = postRetryDelay
    }

    private var connecting: Task<CASClient, Error>?
    /// How many clients this upstream has made, for tests: calls that arrive together
    /// must share one.
    private(set) var clientsCreated = 0

    private func current() async throws -> CASClient {
        if let client {
            // Looked for in the background: this call goes on with the client it has.
            if transport == .automatic, !usesPost, !upgrading, let at = postRetryAt, Date() >= at {
                upgrading = true
                Task { [self] in await tryUpgradeToPost() }
            }
            return client
        }
        // One connection attempt at a time: calls that arrive together wait for it, rather
        // than each opening (and probing) a client of its own.
        if let connecting { return try await connecting.value }
        let attempt = Task { [self] () -> CASClient in
            let created: CASClient
            switch transport {
            case .webSocket: created = try CASClient(workerURL: url)
            case .httpPost: created = try CASClient(workerURL: url, transport: .httpPost)
            case .automatic:
                // While a failed probe is fresh, go straight to the WebSocket: POST is looked
                // for again at `postRetryAt`, not on every reconnect.
                if postServed == false, let at = postRetryAt, Date() < at {
                    created = try CASClient(workerURL: url)
                } else {
                    created = try await automatic()
                }
            }
            return created
        }
        connecting = attempt
        do {
            let created = try await attempt.value
            clientsCreated += 1
            if transport == .httpPost { usesPost = true }
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
        let candidate = try CASClient(workerURL: url, transport: .httpPost)
        do {
            _ = try await withDeadline(callTimeout, { try await candidate.status() }, onTimeout: { await candidate.close() })
            postServed = true
            usesPost = true
            postRetryAt = nil
            return candidate
        } catch {
            // Not necessarily "unsupported": the Worker may have been away. The WebSocket serves
            // for now, and POST is tried again later (see `tryUpgradeToPost`).
            await candidate.close()
            postServed = false
            usesPost = false
            postRetryAt = Date().addingTimeInterval(Double(postRetryDelay.components.seconds)
                + Double(postRetryDelay.components.attoseconds) / 1e18)
            return try CASClient(workerURL: url)
        }
    }

    /// While on the WebSocket by fallback, asks again whether the Worker serves POST, and moves
    /// over if it does. At most one probe at a time, and not more often than the retry delay.
    private func tryUpgradeToPost() async {
        defer { upgrading = false }
        postRetryAt = Date().addingTimeInterval(Double(postRetryDelay.components.seconds)
            + Double(postRetryDelay.components.attoseconds) / 1e18)
        guard let candidate = try? CASClient(workerURL: url, transport: .httpPost) else { return }
        do {
            _ = try await withDeadline(callTimeout, { try await candidate.status() }, onTimeout: { await candidate.close() })
        } catch {
            await candidate.close()
            return
        }
        let old = client
        client = candidate
        usesPost = true
        postServed = true
        postRetryAt = nil
        if let old { Task { await old.close() } }
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

    /// Until when traces are not asked for, once the Worker has said it has none. Only a
    /// definitive answer (it does not know the call) counts: a network failure or a
    /// timeout says nothing about support, and must not switch traces off. The answer is
    /// asked for again after ten minutes, since a Worker is deployed over time.
    private var tracesUnsupportedUntil: Date?

    /// Whether an error says the Worker has no such call (as opposed to not answering).
    static func saysUnsupported(_ error: Error) -> Bool {
        let text = "\(error)"
        return text.contains("targetAccessorNotFound") || text.contains("Failed to locate distributed function accessor")
            || text.contains("does not serve")
    }

    private func traceCall<T: Sendable>(_ operation: @escaping @Sendable (CASClient) async throws -> T) async throws -> T {
        if let until = tracesUnsupportedUntil, Date() < until { throw UpstreamUnsupported(what: "traces") }
        do {
            return try await call(operation)
        } catch {
            if Self.saysUnsupported(error) { tracesUnsupportedUntil = Date().addingTimeInterval(600) }
            throw error
        }
    }

    public func traceGet(_ key: CASDigest) async throws -> [CASDigest]? {
        try await traceCall { try await $0.traceGet(key) }
    }

    public func tracePut(_ key: CASDigest, keys: [CASDigest]) async throws {
        try await traceCall { try await $0.tracePut(key, keys: keys) }
    }

    /// Until when batches are not asked for, once the Worker has said it does not know the
    /// call. Only that definitive answer counts (a failure to reach the Worker says nothing
    /// about support), and it holds for ten minutes, since a Worker is deployed over time.
    private var batchUnsupportedUntil: Date?

    public func actionGetMany(_ keys: [CASDigest]) async throws -> [CASDigest?] {
        if let until = batchUnsupportedUntil, Date() < until {
            // known not to be served: lookups go one at a time
        } else {
            do {
                return try await call { try await $0.actionGetMany(keys) }
            } catch {
                guard Self.saysUnsupported(error) else { throw error }
                batchUnsupportedUntil = Date().addingTimeInterval(600)
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

/// Reports the first of two outcomes, once, and retires the timer when it has.
private final class FirstResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var timer: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    /// The timer that will report a timeout. Cancelled as soon as anything has been
    /// reported, so a call that finishes does not leave one sleeping for the rest of its
    /// timeout.
    func attach(timer: Task<Void, Never>) {
        lock.lock()
        let reported = continuation == nil
        if !reported { self.timer = timer }
        lock.unlock()
        if reported { timer.cancel() }
    }

    /// True if this result was the one reported.
    @discardableResult
    func report(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        let taken = continuation
        continuation = nil
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
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
        first.attach(timer: Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            if first.report(.failure(UpstreamTimeout())) {
                work.cancel()
                await onTimeout()
            }
        })
    }
}
