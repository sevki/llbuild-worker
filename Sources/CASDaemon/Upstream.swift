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
}

/// The Worker, over `CASClient`. One client is held and shared by every call; if
/// a call fails (a connection the Worker dropped, say) it is replaced and the
/// call retried once, since every call here is idempotent.
public actor ClientUpstream: CASUpstream {
    private let url: URL
    private var client: CASClient?

    public init(url: URL) {
        self.url = url
    }

    private func current() throws -> CASClient {
        if let client { return client }
        let created = try CASClient(workerURL: url)
        client = created
        return created
    }

    private func discard(_ failed: CASClient) {
        // Only forget the client that failed: another call may already have
        // replaced it.
        guard client === failed else { return }
        client = nil
        Task { await failed.close() }
    }

    private func call<T: Sendable>(_ operation: @Sendable (CASClient) async throws -> T) async throws -> T {
        let first = try current()
        do {
            return try await operation(first)
        } catch {
            discard(first)
            let second = try current()
            do {
                return try await operation(second)
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
}
