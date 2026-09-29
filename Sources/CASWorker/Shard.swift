import CASProtocol
import Distributed
import Foundation
import JavaScriptKit
import WorkerKitDistributed
import WorkerKit

/// Objects at or above this size keep their body in R2 (when a bucket is
/// bound) instead of SQLite, so the Durable Object holds only metadata for
/// the bulk of the bytes. Chunks of large objects (256 KiB) always qualify.
let r2BodyThresholdBytes = 32 * 1024

/// One CAS shard: a distributed actor living in a Durable Object. Its
/// objects' references, its small objects' bodies and its action-cache
/// entries live in that object's SQLite; large bodies live in R2, keyed by
/// digest. A body is written to R2 before its row, so a row always has a
/// body. Calls can interleave at the R2 awaits, which is harmless: every write
/// is idempotent and content-addressed.
distributed actor CASShard {
    typealias ActorSystem = WorkersActorSystem

    private let storage: SQLStorage
    private let blobs: R2Bucket?
    private var schemaReady = false

    init(actorSystem: WorkersActorSystem, sql: SQLStorage, blobs: R2Bucket? = nil) {
        self.actorSystem = actorSystem
        self.storage = sql
        self.blobs = blobs
    }

    private static func blobKey(_ digest: String) -> String { "obj/\(digest)" }

    /// Creates the tables on first use, so a storage failure surfaces as an
    /// ordinary call error instead of a trap while the Durable Object starts.
    private func database() throws -> SQLStorage {
        if !schemaReady {
            try storage.exec(
                "CREATE TABLE IF NOT EXISTS objects (digest TEXT PRIMARY KEY, refs TEXT NOT NULL, data TEXT NOT NULL, in_r2 INTEGER NOT NULL DEFAULT 0)")
            try storage.exec(
                "CREATE TABLE IF NOT EXISTS actions (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            // A large object's entry: the manifest object listing its chunks.
            try storage.exec(
                "CREATE TABLE IF NOT EXISTS large (digest TEXT PRIMARY KEY, refs TEXT NOT NULL, manifest TEXT NOT NULL, size INTEGER NOT NULL)")
            schemaReady = true
        }
        return storage
    }

    /// Stores an object idempotently. The caller has already computed
    /// `digest`; the shard recomputes it and refuses a mismatch, so a shard
    /// can never hold content under the wrong identity.
    distributed func putObject(digest: String, refs: [String], data: String) async throws {
        guard let bytes = Data(base64Encoded: data) else { throw CASServiceError.invalidData }
        let refDigests = try refs.map { ref -> CASDigest in
            guard let parsed = CASDigest(hex: ref) else { throw CASServiceError.invalidDigest(ref) }
            return parsed
        }
        let actual = CASIdentity.identify(refs: refDigests, data: [UInt8](bytes)).hex
        guard actual == digest else { throw CASServiceError.invalidDigest(digest) }
        let db = try database()
        if try !db.exec("SELECT 1 AS present FROM objects WHERE digest = ?", digest).rows().isEmpty {
            return
        }
        var inline = data
        var inR2 = 0
        if let blobs, bytes.count >= r2BodyThresholdBytes {
            try await blobs.put(Self.blobKey(digest), [UInt8](bytes))
            inline = ""
            inR2 = 1
        }
        try db.exec(
            "INSERT INTO objects (digest, refs, data, in_r2) VALUES (?, ?, ?, ?) ON CONFLICT(digest) DO NOTHING",
            digest, refs.joined(separator: ","), inline, inR2)
    }

    distributed func getObject(digest: String) async throws -> CASObjectPayload? {
        let rows = try database().exec("SELECT refs, data, in_r2 FROM objects WHERE digest = ?", digest).rows()
        guard let row = rows.first, let refs = row["refs", as: String.self],
              var data = row["data", as: String.self] else { return nil }
        if row["in_r2", as: Int.self] == 1 {
            guard let blobs, let body = try await blobs.get(Self.blobKey(digest)) else {
                throw CASServiceError.invalidManifest("body of \(digest) is missing from R2")
            }
            data = Data(try await body.bytes()).base64EncodedString()
        }
        return CASObjectPayload(
            refs: refs.isEmpty ? [] : refs.split(separator: ",").map(String.init), data: data)
    }

    distributed func containsObject(digest: String) throws -> Bool {
        let db = try database()
        if try !db.exec("SELECT 1 AS present FROM objects WHERE digest = ?", digest).rows().isEmpty {
            return true
        }
        return try !db.exec("SELECT 1 AS present FROM large WHERE digest = ?", digest).rows().isEmpty
    }

    /// Records a large object whose content the caller has already verified.
    distributed func putLarge(digest: String, refs: [String], manifest: String, size: Int) throws {
        try database().exec(
            "INSERT INTO large (digest, refs, manifest, size) VALUES (?, ?, ?, ?) ON CONFLICT(digest) DO NOTHING",
            digest, refs.joined(separator: ","), manifest, size)
    }

    distributed func getLarge(digest: String) throws -> CASLargeObject? {
        let rows = try database().exec("SELECT refs, manifest, size FROM large WHERE digest = ?", digest).rows()
        guard let row = rows.first, let refs = row["refs", as: String.self],
              let manifest = row["manifest", as: String.self],
              let size = row["size", as: Int.self] else { return nil }
        return CASLargeObject(
            refs: refs.isEmpty ? [] : refs.split(separator: ",").map(String.init),
            manifest: manifest, size: size)
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

    /// What this shard holds, for the stats page. `inlineBytes` estimates the
    /// decoded size from the base64 text kept in SQLite.
    distributed func totals() throws -> ShardTotals {
        let db = try database()
        let objects = try db.exec(
            "SELECT count(*) AS n, coalesce(sum(in_r2), 0) AS r2, coalesce(sum(length(data)), 0) AS chars FROM objects").rows().first
        let actions = try db.exec("SELECT count(*) AS n FROM actions").rows().first
        let large = try db.exec("SELECT count(*) AS n, coalesce(sum(size), 0) AS bytes FROM large").rows().first
        return ShardTotals(
            objects: objects?["n", as: Int.self] ?? 0,
            objectsInR2: objects?["r2", as: Int.self] ?? 0,
            inlineBytes: (objects?["chars", as: Int.self] ?? 0) / 4 * 3,
            actions: actions?["n", as: Int.self] ?? 0,
            largeObjects: large?["n", as: Int.self] ?? 0,
            largeBytes: large?["bytes", as: Int.self] ?? 0)
    }
}

/// The Durable Object that hosts one `CASShard`, mirroring WorkerKit's
/// per-Durable-Object actor hosting: the actor's id is the object's own id.
@DurableObject
final class CASShardObject {
    let hostSystem: WorkersActorSystem
    let shard: CASShard

    init(state: DurableObjectState, env: Env) {
        let hostSystem = WorkersActorSystem()
        self.hostSystem = hostSystem
        let sql = state.storage.sql
        // Without an R2 binding every body stays in SQLite.
        let blobs = env.jsObject["CASBLOBS"].object == nil ? nil : env.r2("CASBLOBS")
        shard = hostSystem.host(state.id) { CASShard(actorSystem: $0, sql: sql, blobs: blobs) }
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

    /// Every shard, for reading totals across the whole store.
    func allShards() throws -> [CASShard] {
        try "0123456789abcdef".map { try shard(for: String($0)) }
    }

    func contains(digest: String) async throws -> Bool {
        try await shard(for: digest).containsObject(digest: digest)
    }

    func put(digest: String, refs: [String], data: String) async throws {
        try await shard(for: digest).putObject(digest: digest, refs: refs, data: data)
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

    /// Reassembles the object from its manifest's chunks and refuses unless
    /// it has exactly the claimed identity, so a client can never register
    /// content under a digest it does not have.
    func putLarge(digest: String, refs: [String], manifest: String) async throws {
        guard let manifestObject = try await shard(for: manifest).getObject(digest: manifest),
              let manifestBytes = Data(base64Encoded: manifestObject.data),
              let size = CASChunking.size(ofManifestData: [UInt8](manifestBytes)) else {
            throw CASServiceError.invalidManifest("manifest \(manifest) is missing or malformed")
        }
        guard size > CASLimits.maxObjectBytes, size <= CASLimits.maxLargeObjectBytes else {
            throw CASServiceError.objectTooLarge(size: size, limit: CASLimits.maxLargeObjectBytes)
        }
        var assembled = [UInt8]()
        assembled.reserveCapacity(size)
        for chunk in manifestObject.refs {
            guard let object = try await shard(for: chunk).getObject(digest: chunk),
                  object.refs.isEmpty, let bytes = Data(base64Encoded: object.data),
                  bytes.count <= CASLimits.chunkBytes else {
                throw CASServiceError.invalidManifest("chunk \(chunk) is missing or malformed")
            }
            // A manifest may list the same chunk many times, so the reference
            // list can describe far more data than `size` says. Stop as soon
            // as the next chunk would pass it, before the buffer grows.
            guard assembled.count + bytes.count <= size else {
                throw CASServiceError.invalidManifest("chunks exceed the manifest's declared size of \(size) bytes")
            }
            assembled.append(contentsOf: bytes)
        }
        guard assembled.count == size else {
            throw CASServiceError.invalidManifest("chunks total \(assembled.count) bytes, manifest says \(size)")
        }
        let refDigests = try refs.map { ref -> CASDigest in
            guard let parsed = CASDigest(hex: ref) else { throw CASServiceError.invalidDigest(ref) }
            return parsed
        }
        guard CASIdentity.identify(refs: refDigests, data: assembled).hex == digest else {
            throw CASServiceError.invalidDigest(digest)
        }
        try await shard(for: digest).putLarge(digest: digest, refs: refs, manifest: manifest, size: size)
    }

    func getLarge(digest: String) async throws -> CASLargeObject? {
        try await shard(for: digest).getLarge(digest: digest)
    }
}

/// One WebSocket connection's gateway. Unlike WorkerKit's `RPCGateway`,
/// which relays to a Worker entry point that has no `env`, this Durable Object
/// hosts the `CASService` itself so the service can reach the shard namespace.
@DurableObject
public final class CASGateway {
    let state: DurableObjectState
    let hostSystem: WorkersActorSystem
    let service: CASService
    let stats: StatsClient?

    public init(state: DurableObjectState, env: Env) {
        self.state = state
        let hostSystem = WorkersActorSystem()
        self.hostSystem = hostSystem
        let shards = ShardBackend(namespace: env.durableObject("CASSHARD"))
        let stats = StatsClient(env: env)
        self.stats = stats
        let backend: any CASBackend = stats.map { StatsBackend(inner: shards, stats: $0) } ?? shards
        let service = CASService(actorSystem: hostSystem, backend: backend)
        hostSystem.host(service)
        self.service = service
    }

    public func fetch(_ req: Request) async throws -> Response {
        guard req.headers.get("Upgrade")?.lowercased() == "websocket" else {
            return .error("Expected Upgrade: websocket", 426)
        }
        stats?.record([StatsName.connections: 1])
        return .webSocketUpgrade(state.acceptWebSocket(tags: ["rpc"]))
    }

    public func webSocketMessage(_ ws: WebSocket, _ message: WebSocketMessage) async throws {
        guard case .text(let text) = message else { return }
        ws.send(await hostSystem.receiveJSON(text))
    }
}
