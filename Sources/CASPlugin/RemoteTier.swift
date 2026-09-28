import CASClient
import CASProtocol
import Foundation

private final class ResultBox<T: Sendable>: @unchecked Sendable {
    var result: Result<T, Error>?
}

/// The shared tier behind the local store: the Worker's distributed
/// `CASService`, called from the plugin's synchronous C entry points.
///
/// Remote trouble must never fail a compile, so every call returns nil on
/// failure and the first failure switches the tier off for this process.
/// Set LLBUILD_CAS_DEBUG=1 to see what it decided.
final class RemoteTier: @unchecked Sendable {
    private let client: CASClient
    private let lock = NSLock()
    private var uploaded = Set<CASDigest>()
    private var disabled = false
    private let timeout: TimeInterval

    static let debug = ProcessInfo.processInfo.environment["LLBUILD_CAS_DEBUG"] != nil

    init(url: URL, timeout: TimeInterval = 30) throws {
        client = try CASClient(workerURL: url)
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

    /// Runs `operation` to completion on the calling thread, or returns nil.
    private func blocking<T: Sendable>(
        _ what: String, _ operation: @escaping @Sendable (CASClient) async throws -> T
    ) -> T? {
        guard isEnabled else { return nil }
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        let client = self.client
        Task.detached {
            do {
                box.result = .success(try await operation(client))
            } catch {
                box.result = .failure(error)
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            disable("\(what) timed out after \(Int(timeout))s")
            return nil
        }
        switch box.result! {
        case .success(let value):
            return value
        case .failure(let error):
            disable("\(what) failed: \(error)")
            return nil
        }
    }

    func contains(_ digest: CASDigest) -> Bool? {
        blocking("contains") { try await $0.contains(digest) }
    }

    /// nil on failure; `.some(nil)` when the remote simply does not have it.
    func get(_ digest: CASDigest) -> CASBlob?? {
        blocking("get") { try await $0.get(digest) }
    }

    func actionGet(_ key: CASDigest) -> CASDigest?? {
        blocking("actionGet") { try await $0.actionGet(key) }
    }

    func actionPut(_ key: CASDigest, value: CASDigest) -> Bool {
        blocking("actionPut") { try await $0.actionPut(key, value: value) } != nil
    }

    /// Uploads `digest` and everything it references, children first, so the
    /// remote never holds an object whose references are missing. False if
    /// any part cannot be uploaded (absent locally, or over the size limit).
    func ensureUploaded(_ digest: CASDigest, from store: LocalStore) -> Bool {
        lock.lock()
        let already = uploaded.contains(digest)
        lock.unlock()
        if already { return true }

        guard let blob = try? store.get(digest) else {
            log("cannot upload \(digest.hex): not in the local store")
            return false
        }
        for ref in blob.refs where !ensureUploaded(ref, from: store) {
            return false
        }
        guard blob.data.count <= CASLimits.maxObjectBytes else {
            log("not uploading \(digest.hex): \(blob.data.count) bytes is over the \(CASLimits.maxObjectBytes) byte limit")
            return false
        }
        if contains(digest) != true {
            guard blocking("put", { try await $0.put(blob) }) != nil else { return false }
        }
        lock.lock()
        uploaded.insert(digest)
        lock.unlock()
        return true
    }

    func close() {
        let client = self.client
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await client.close()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
    }
}
