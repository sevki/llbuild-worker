import CASClient
import CASProtocol
import Dispatch
import Foundation

/// Runs the remote client's work on its own threads instead of Swift's shared
/// cooperative pool.
///
/// The plugin is called from threads it does not own. Swift Build calls the
/// async entry points from cooperative-pool threads; blocking one of those
/// while waiting on a task that itself needs a pool thread starves the pool
/// (all threads waiting, none able to run the work). Giving the client a
/// separate executor breaks that dependency.
final class PluginExecutor: TaskExecutor, @unchecked Sendable {
    let queue = DispatchQueue(
        label: "llbuild-worker.cas.remote", qos: .userInitiated, attributes: .concurrent)

    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        queue.async { unowned.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}

/// A call's completion, handed out exactly once. Whoever finishes first (the
/// operation or the timeout) takes it; after that the box holds nothing, so a
/// timer that is still queued keeps only this empty box alive.
private final class PendingCall<T: Sendable>: @unchecked Sendable {
    typealias Completion = @Sendable (Result<T, Error>) -> Void

    private let lock = NSLock()
    private var completion: Completion?

    init(_ completion: @escaping Completion) {
        self.completion = completion
    }

    func take() -> Completion? {
        lock.lock()
        defer { lock.unlock() }
        let taken = completion
        completion = nil
        return taken
    }
}

private final class ValueBox<T: Sendable>: @unchecked Sendable {
    var value: T?
}

struct RemoteUnavailable: Error, CustomStringConvertible {
    var description: String
}

/// The shared tier behind the local store: the Worker's distributed
/// `CASService`, reached from the plugin's C entry points.
///
/// Remote trouble must never fail a compile, so every call reports failure as
/// a value and the first failure switches the tier off for this process.
/// Set LLBUILD_CAS_DEBUG=1 to see what it decided.
final class RemoteTier: @unchecked Sendable {
    static let executor = PluginExecutor()
    static let debug = ProcessInfo.processInfo.environment["LLBUILD_CAS_DEBUG"] != nil

    private let url: URL
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var connection: CASClient?
    private var uploaded = Set<CASDigest>()
    private var disabled = false

    init(url: URL, timeout: TimeInterval = 30) {
        self.url = url
        self.timeout = timeout
    }

    func log(_ message: @autoclosure () -> String) {
        if Self.debug {
            FileHandle.standardError.write(Data("llbuild-worker CAS: \(message())\n".utf8))
        }
    }

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !disabled
    }

    private func disable(_ reason: String) {
        lock.lock()
        let wasEnabled = !disabled
        disabled = true
        lock.unlock()
        if wasEnabled { log("remote disabled: \(reason)") }
    }

    /// Connects on first use. Only called from tasks running on `executor`,
    /// so the connection's own tasks inherit that executor too.
    private func client() throws -> CASClient {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }
        let created = try CASClient(workerURL: url)
        connection = created
        return created
    }

    /// Runs `operation` on the plugin's executor and reports the outcome to
    /// `completion` exactly once, from whichever thread finishes first:
    /// the operation, or a timeout.
    func run<T: Sendable>(
        _ what: String, timeout limit: TimeInterval? = nil,
        _ operation: @escaping @Sendable (CASClient) async throws -> T,
        completion: @escaping @Sendable (Result<T, Error>) -> Void
    ) {
        guard isEnabled else {
            completion(.failure(RemoteUnavailable(description: "remote is disabled")))
            return
        }
        let pending = PendingCall<T>(completion)
        let seconds = limit ?? timeout
        // A queued timer is not freed when cancelled, only skipped when its
        // deadline arrives. So it must not hold anything that matters: it
        // captures the (emptied, once finished) `pending` box and a weak
        // `self`, never the completion or the plugin.
        let timer = DispatchWorkItem { [weak self] in
            guard let completion = pending.take() else { return }
            self?.disable("\(what) timed out after \(Int(seconds))s")
            completion(.failure(RemoteUnavailable(description: "\(what) timed out")))
        }
        Self.executor.queue.asyncAfter(deadline: .now() + seconds, execute: timer)
        Task(executorPreference: Self.executor) { [self] in
            do {
                let value = try await operation(try client())
                timer.cancel()
                pending.take()?(.success(value))
            } catch {
                timer.cancel()
                if let completion = pending.take() {
                    disable("\(what) failed: \(error)")
                    completion(.failure(error))
                }
            }
        }
    }

    /// The blocking form, for the plugin's synchronous entry points. Nil on
    /// any failure.
    func blocking<T: Sendable>(
        _ what: String, timeout limit: TimeInterval? = nil,
        _ operation: @escaping @Sendable (CASClient) async throws -> T
    ) -> T? {
        let box = ValueBox<T>()
        let done = DispatchSemaphore(value: 0)
        run(what, timeout: limit, operation) { result in
            if case .success(let value) = result { box.value = value }
            done.signal()
        }
        done.wait()
        return box.value
    }

    // MARK: - Objects and actions

    func contains(_ digest: CASDigest) -> Bool? {
        blocking("contains") { try await $0.contains(digest) }
    }

    /// nil on failure; `.some(nil)` when the remote simply does not have it.
    func get(_ digest: CASDigest) -> CASBlob?? {
        blocking("get") { try await $0.get(digest) }
    }

    func getAsync(_ digest: CASDigest, completion: @escaping @Sendable (Result<CASBlob?, Error>) -> Void) {
        run("get", { try await $0.get(digest) }, completion: completion)
    }

    func actionGet(_ key: CASDigest) -> CASDigest?? {
        blocking("actionGet") { try await $0.actionGet(key) }
    }

    func actionGetAsync(
        _ key: CASDigest, completion: @escaping @Sendable (Result<CASDigest?, Error>) -> Void
    ) {
        run("actionGet", { try await $0.actionGet(key) }, completion: completion)
    }

    /// Uploads `value` and everything it references (children first, so the
    /// remote never holds an object whose references are missing), then
    /// records the action. The result is true only if all of it was shared;
    /// otherwise the action stays local.
    private static let publishTimeout: TimeInterval = 300

    func publish(key: CASDigest, value: CASDigest, from store: LocalStore) -> Bool {
        blocking("publish", timeout: Self.publishTimeout) {
            try await self.publishOperation(key: key, value: value, store: store, client: $0)
        } ?? false
    }

    func publishAsync(
        key: CASDigest, value: CASDigest, from store: LocalStore,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        run("publish", timeout: Self.publishTimeout, {
            try await self.publishOperation(key: key, value: value, store: store, client: $0)
        }) { completion((try? $0.get()) ?? false) }
    }

    private func publishOperation(
        key: CASDigest, value: CASDigest, store: LocalStore, client: CASClient
    ) async throws -> Bool {
        guard try await ensureUploaded(value, from: store, client: client) else {
            log("kept action \(key.hex) local")
            return false
        }
        try await client.actionPut(key, value: value)
        log("shared action \(key.hex)")
        return true
    }

    private func ensureUploaded(_ digest: CASDigest, from store: LocalStore, client: CASClient) async throws -> Bool {
        if hasUploaded(digest) { return true }

        guard let blob = try? store.get(digest) else {
            log("cannot upload \(digest.hex): not in the local store")
            return false
        }
        for ref in blob.refs {
            guard try await ensureUploaded(ref, from: store, client: client) else { return false }
        }
        guard blob.data.count <= CASLimits.maxLargeObjectBytes else {
            log("not uploading \(digest.hex): \(blob.data.count) bytes is over the \(CASLimits.maxLargeObjectBytes) byte limit")
            return false
        }
        if try await !client.contains(digest) {
            try await client.put(blob)
        }
        markUploaded(digest)
        return true
    }

    // Synchronous helpers: an NSLock may not be held across, or taken from,
    // async code directly.
    private func hasUploaded(_ digest: CASDigest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return uploaded.contains(digest)
    }

    private func markUploaded(_ digest: CASDigest) {
        lock.lock()
        defer { lock.unlock() }
        uploaded.insert(digest)
    }

    func close() {
        lock.lock()
        let connection = self.connection
        lock.unlock()
        guard let connection else { return }
        let done = DispatchSemaphore(value: 0)
        Task(executorPreference: Self.executor) {
            await connection.close()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
    }
}
