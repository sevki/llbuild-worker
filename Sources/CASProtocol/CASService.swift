import Distributed
import Foundation
import WorkerKitDistributed

/// CAS identity in llbuild2's Codable string form.
///
/// The current service reports status only. Before adding object operations,
/// pin the llbuild2 revision and validate its exact identity encoding.
public struct CASID: Codable, Hashable, Sendable {
    public let value: String

    public init(value: String) {
        self.value = value
    }
}

/// Wire representation of an llbuild2 object.
public struct CASObject: Codable, Sendable, Equatable {
    public let refs: [CASID]
    public let data: Data

    public init(refs: [CASID], data: Data) {
        self.refs = refs
        self.data = data
    }
}

/// Capabilities returned by the worker before the CLI attempts CAS operations.
public struct CASServiceStatus: Codable, Sendable, Equatable {
    public let service: String
    public let protocolVersion: String
    public let storageConfigured: Bool

    public init(service: String, protocolVersion: String, storageConfigured: Bool) {
        self.service = service
        self.protocolVersion = protocolVersion
        self.storageConfigured = storageConfigured
    }
}

/// A CAS object on the wire: references as hex digests, data as base64.
///
/// Strings, not `Data`, so the encoding is the same whichever side of the
/// JSON control plane produced it.
public struct CASObjectPayload: Codable, Sendable, Equatable {
    public var refs: [String]
    public var data: String

    public init(refs: [String], data: String) {
        self.refs = refs
        self.data = data
    }
}

public enum CASServiceError: Error, Codable, Equatable, CustomStringConvertible {
    case objectTooLarge(size: Int, limit: Int)
    case invalidManifest(String)
    case invalidDigest(String)
    case invalidData
    case missingObject(String)
    case storageNotConfigured

    public var description: String {
        switch self {
        case .objectTooLarge(let size, let limit):
            return "object of \(size) bytes exceeds the \(limit) byte control-plane limit"
        case .invalidManifest(let reason):
            return "invalid chunk manifest: \(reason)"
        case .invalidDigest(let value):
            return "invalid digest: \(value)"
        case .invalidData:
            return "object data is not valid base64"
        case .missingObject(let digest):
            return "object \(digest) is not stored"
        case .storageNotConfigured:
            return "this CAS service has no storage backend"
        }
    }
}

public enum CASLimits {
    /// Largest single object accepted over the JSON/WebSocket control plane.
    /// The native client caps inbound WebSocket messages at 1 MiB and base64
    /// inflates by a third, so this leaves room for the envelope.
    public static let maxObjectBytes = 512 * 1024

    /// Size of each chunk of a large object.
    public static let chunkBytes = 256 * 1024

    /// Largest logical object. The Worker reassembles a large object in
    /// memory to verify its identity, so this is bounded by its isolate.
    public static let maxLargeObjectBytes = 64 * 1024 * 1024

    /// Largest object accepted over the plain-HTTP object endpoints (`GET`/
    /// `PUT /{scope}/objects/{digest}`), which have no WebSocket
    /// message-size ceiling to chunk around — one streamed body instead of
    /// `chunkBytes` pieces. Bounded by the Worker isolate's memory, same as
    /// `maxLargeObjectBytes`.
    public static let maxHTTPObjectBytes = 64 * 1024 * 1024

    /// Most keys one `actionGetMany` may carry: a reply is one short string per key.
    public static let maxBatchKeys = 256

    /// Most action keys one trace may hold (a key is 64 hex characters).
    public static let maxTraceKeys = 8192
}

/// A large object's entry: its references, the manifest object that lists its
/// chunks, and its total size.
public struct CASLargeObject: Codable, Sendable, Equatable {
    public var refs: [String]
    public var manifest: String
    public var size: Int

    public init(refs: [String], manifest: String, size: Int) {
        self.refs = refs
        self.manifest = manifest
        self.size = size
    }
}

/// Storage behind a `CASService`. The Worker implements it with shard actors;
/// it is a protocol so the service actor stays a stateless façade.
public protocol CASBackend: Sendable {
    func contains(digest: String) async throws -> Bool
    /// Stores an object under `digest`, which the shard that holds it
    /// recomputes and rejects on a mismatch, so a client can name a key but
    /// never put content under the wrong one. `data` is base64, passed
    /// through untouched so the front-end does no per-byte work.
    func put(digest: String, refs: [String], data: String) async throws
    func get(digest: String) async throws -> CASObjectPayload?
    func actionGet(key: String) async throws -> String?
    func actionPut(key: String, value: String) async throws
    /// Records a large object after verifying that its manifest's chunks
    /// reassemble to content with exactly this identity.
    func putLarge(digest: String, refs: [String], manifest: String) async throws
    func getLarge(digest: String) async throws -> CASLargeObject?
    /// The keys a build looked up, in order, recorded under the first of them (see
    /// `CASService.tracePut`). A backend that keeps no traces inherits these.
    func traceGet(key: String) async throws -> [String]?
    func tracePut(key: String, keys: [String]) async throws
}

extension CASBackend {
    public func traceGet(key: String) async throws -> [String]? { nil }
    public func tracePut(key: String, keys: [String]) async throws {}
}

/// The llbuild-worker CAS: the distributed actor a Worker hosts and a native
/// client (`castool`, the swiftc plugin) resolves through `WorkersActorSystem`.
///
/// It holds no state. Hosted in a Worker it is given a `backend`; a client
/// resolving it remotely never runs these method bodies.
public distributed actor CASService {
    public typealias ActorSystem = WorkersActorSystem

    private let backend: (any CASBackend)?

    public init(actorSystem: WorkersActorSystem, backend: (any CASBackend)? = nil) {
        self.actorSystem = actorSystem
        self.backend = backend
    }

    public distributed func status() -> CASServiceStatus {
        CASServiceStatus(
            service: "llbuild-worker",
            protocolVersion: "0.3.0",
            storageConfigured: backend != nil
        )
    }

    public distributed func contains(digest: String) async throws -> Bool {
        try await requireBackend().contains(digest: try Self.validated(digest))
    }

    /// Stores an object under `digest`. Rejects objects over
    /// `CASLimits.maxObjectBytes`; the shard holding it verifies the digest.
    public distributed func put(digest: String, refs: [String], data: String) async throws {
        let size = Self.decodedSize(ofBase64: data)
        guard size <= CASLimits.maxObjectBytes else {
            throw CASServiceError.objectTooLarge(size: size, limit: CASLimits.maxObjectBytes)
        }
        try await requireBackend().put(
            digest: try Self.validated(digest), refs: try refs.map(Self.validated), data: data)
    }

    /// Registers `digest` as the object whose chunks `manifest` lists. The
    /// service reassembles it and refuses unless it has that identity.
    public distributed func putLarge(digest: String, refs: [String], manifest: String) async throws {
        try await requireBackend().putLarge(
            digest: try Self.validated(digest), refs: try refs.map(Self.validated),
            manifest: try Self.validated(manifest))
    }

    public distributed func getLarge(digest: String) async throws -> CASLargeObject? {
        try await requireBackend().getLarge(digest: try Self.validated(digest))
    }

    public distributed func get(digest: String) async throws -> CASObjectPayload? {
        try await requireBackend().get(digest: try Self.validated(digest))
    }

    public distributed func actionGet(key: String) async throws -> String? {
        try await requireBackend().actionGet(key: try Self.validated(key))
    }

    /// Many `actionGet`s in one call, for a client with many lookups outstanding:
    /// one round trip instead of one each. The answers are in the order of the
    /// keys, nil for an action that is not stored. Objects are not part of it; they
    /// stay on the plain HTTP endpoints.
    public distributed func actionGetMany(keys: [String]) async throws -> [String?] {
        guard keys.count <= CASLimits.maxBatchKeys else {
            throw CASServiceError.objectTooLarge(size: keys.count, limit: CASLimits.maxBatchKeys)
        }
        let backend = try requireBackend()
        let valid = try keys.map(Self.validated)
        return try await withThrowingTaskGroup(of: (Int, String?).self) { group in
            for (index, key) in valid.enumerated() {
                group.addTask { (index, try await backend.actionGet(key: key)) }
            }
            var answers = [String?](repeating: nil, count: valid.count)
            for try await (index, value) in group { answers[index] = value }
            return answers
        }
    }

    /// The trace recorded under `key`: the action keys a build looked up, in the
    /// order it first looked them up, which started with `key`. A client about to
    /// repeat that build reads it to ask for what comes next before the compiler
    /// does. Nil if there is none.
    public distributed func traceGet(key: String) async throws -> [String]? {
        try await requireBackend().traceGet(key: try Self.validated(key))
    }

    /// Records a trace under its first key, replacing any earlier one: unlike an
    /// action, a trace is a hint about the latest build, not a fact about content.
    /// A wrong or stale trace costs a client some unneeded lookups, nothing more.
    public distributed func tracePut(key: String, keys: [String]) async throws {
        guard keys.count <= CASLimits.maxTraceKeys else {
            throw CASServiceError.objectTooLarge(size: keys.count, limit: CASLimits.maxTraceKeys)
        }
        try await requireBackend().tracePut(key: try Self.validated(key), keys: try keys.map(Self.validated))
    }

    public distributed func actionPut(key: String, value: String) async throws {
        let backend = try requireBackend()
        let key = try Self.validated(key), value = try Self.validated(value)
        // An action key is immutable once written, so it must never point at an
        // object the store does not have: that would leave every later lookup
        // dangling and the key impossible to repair. Clients upload the value
        // (and what it references) before the action.
        guard try await backend.contains(digest: value) else {
            throw CASServiceError.missingObject(value)
        }
        try await backend.actionPut(key: key, value: value)
    }

    private func requireBackend() throws -> any CASBackend {
        guard let backend else { throw CASServiceError.storageNotConfigured }
        return backend
    }

    /// Bytes a base64 string decodes to, from its length alone: the front-end
    /// must bound the size without decoding the data.
    private static func decodedSize(ofBase64 text: String) -> Int {
        let utf8 = text.utf8
        let padding = utf8.reversed().prefix(2).filter { $0 == UInt8(ascii: "=") }.count
        return max(0, utf8.count / 4 * 3 - padding)
    }

    private static func validated(_ digest: String) throws -> String {
        guard let parsed = CASDigest(hex: digest), parsed.bytes.count == CASIdentity.digestSize else {
            throw CASServiceError.invalidDigest(digest)
        }
        return digest
    }
}
