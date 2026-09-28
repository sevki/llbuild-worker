import CASProtocol
import Distributed
import Foundation
import JavaScriptKit
import WorkersDistributed
import WorkersSwift

/// One CAS shard: a distributed actor living in a Durable Object, with its
/// objects and action-cache entries in that object's SQLite. The Durable
/// Object's single-threaded execution serializes every call, so no locking is
/// needed here.
distributed actor CASShard {
    typealias ActorSystem = WorkersActorSystem

    private let storage: SQLStorage
    private var schemaReady = false

    init(actorSystem: WorkersActorSystem, sql: SQLStorage) {
        self.actorSystem = actorSystem
        self.storage = sql
    }

    /// Creates the tables on first use, so a storage failure surfaces as an
    /// ordinary call error instead of a trap while the Durable Object starts.
    private func database() throws -> SQLStorage {
        if !schemaReady {
            try storage.exec(
                "CREATE TABLE IF NOT EXISTS objects (digest TEXT PRIMARY KEY, refs TEXT NOT NULL, data TEXT NOT NULL)")
            try storage.exec(
                "CREATE TABLE IF NOT EXISTS actions (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            schemaReady = true
        }
        return storage
    }

    /// Stores an object idempotently. The caller has already computed
    /// `digest`; the shard recomputes it and refuses a mismatch, so a shard
    /// can never hold content under the wrong identity.
    distributed func putObject(digest: String, refs: [String], data: String) throws {
        guard let bytes = Data(base64Encoded: data) else { throw CASServiceError.invalidData }
        let refDigests = try refs.map { ref -> CASDigest in
            guard let parsed = CASDigest(hex: ref) else { throw CASServiceError.invalidDigest(ref) }
            return parsed
        }
        let actual = CASIdentity.identify(refs: refDigests, data: [UInt8](bytes)).hex
        guard actual == digest else { throw CASServiceError.invalidDigest(digest) }
        try database().exec(
            "INSERT INTO objects (digest, refs, data) VALUES (?, ?, ?) ON CONFLICT(digest) DO NOTHING",
            digest, refs.joined(separator: ","), data)
    }

    distributed func getObject(digest: String) throws -> CASObjectPayload? {
        let rows = try database().exec("SELECT refs, data FROM objects WHERE digest = ?", digest).rows()
        guard let row = rows.first, let refs = row["refs", as: String.self],
              let data = row["data", as: String.self] else { return nil }
        return CASObjectPayload(
            refs: refs.isEmpty ? [] : refs.split(separator: ",").map(String.init), data: data)
    }

    distributed func containsObject(digest: String) throws -> Bool {
        try !database().exec("SELECT 1 AS present FROM objects WHERE digest = ?", digest).rows().isEmpty
    }

    /// An action key always maps to one value; writing a different one is a
    /// caller bug, so it is rejected instead of silently replacing the entry.
    distributed func putAction(key: String, value: String) throws {
        if let existing = try getAction(key: key), existing != value {
            throw CASServiceError.invalidDigest(key)
        }
        try database().exec(
            "INSERT INTO actions (key, value) VALUES (?, ?) ON CONFLICT(key) DO NOTHING", key, value)
    }

    distributed func getAction(key: String) throws -> String? {
        try database().exec("SELECT value FROM actions WHERE key = ?", key).rows().first?["value", as: String.self]
    }
}

/// The Durable Object that hosts one `CASShard`, mirroring workers-swift's
/// per-Durable-Object actor hosting: the actor's id is the object's own id.
@DurableObject
final class CASShardObject {
    let hostSystem: WorkersActorSystem
    let shard: CASShard

    init(state: DurableObjectState, env: Env) {
        let hostSystem = WorkersActorSystem()
        self.hostSystem = hostSystem
        let sql = state.storage.sql
        shard = hostSystem.host(state.id) { CASShard(actorSystem: $0, sql: sql) }
    }
}

/// `CASBackend` over shard actors: a digest picks a shard by its first hex
/// digit, so the keyspace splits across 16 Durable Objects. Fixed for now;
/// changing it needs a resharding plan (see docs/design.md).
struct ShardBackend: CASBackend {
    let namespace: DurableObjectNamespace
    let system: WorkersActorSystem

    init(namespace: DurableObjectNamespace) {
        self.namespace = namespace
        self.system = WorkersActorSystem(durableObjects: namespace)
    }

    private func shard(for digest: String) throws -> CASShard {
        try CASShard.resolve(id: namespace.idFromName("shard-\(digest.prefix(1))"), using: system)
    }

    func contains(digest: String) async throws -> Bool {
        try await shard(for: digest).containsObject(digest: digest)
    }

    func put(refs: [String], data: [UInt8]) async throws -> String {
        let refDigests = refs.compactMap { CASDigest(hex: $0) }
        let digest = CASIdentity.identify(refs: refDigests, data: data).hex
        try await shard(for: digest).putObject(
            digest: digest, refs: refs, data: Data(data).base64EncodedString())
        return digest
    }

    func get(digest: String) async throws -> CASObjectPayload? {
        try await shard(for: digest).getObject(digest: digest)
    }

    func actionGet(key: String) async throws -> String? {
        try await shard(for: key).getAction(key: key)
    }

    func actionPut(key: String, value: String) async throws {
        try await shard(for: key).putAction(key: key, value: value)
    }
}

/// One WebSocket connection's gateway. Unlike workers-swift's `RPCGateway`,
/// which relays to a Worker entry point that has no `env`, this Durable Object
/// hosts the `CASService` itself so the service can reach the shard namespace.
@DurableObject
public final class CASGateway {
    let state: DurableObjectState
    let hostSystem: WorkersActorSystem
    let service: CASService

    public init(state: DurableObjectState, env: Env) {
        self.state = state
        let hostSystem = WorkersActorSystem()
        self.hostSystem = hostSystem
        let backend = ShardBackend(namespace: env.durableObject("CASSHARD"))
        let service = CASService(actorSystem: hostSystem, backend: backend)
        hostSystem.host(service)
        self.service = service
    }

    public func fetch(_ req: Request) async throws -> Response {
        guard req.headers.get("Upgrade")?.lowercased() == "websocket" else {
            return .error("Expected Upgrade: websocket", 426)
        }
        return .webSocketUpgrade(state.acceptWebSocket(tags: ["rpc"]))
    }

    public func webSocketMessage(_ ws: WebSocket, _ message: WebSocketMessage) async throws {
        guard case .text(let text) = message else { return }
        ws.send(await hostSystem.receiveJSON(text))
    }
}
