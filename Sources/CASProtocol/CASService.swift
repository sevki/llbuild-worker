import Distributed
import Foundation
import WorkersDistributed

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
    case invalidDigest(String)
    case invalidData
    case storageNotConfigured

    public var description: String {
        switch self {
        case .objectTooLarge(let size, let limit):
            return "object of \(size) bytes exceeds the \(limit) byte control-plane limit"
        case .invalidDigest(let value):
            return "invalid digest: \(value)"
        case .invalidData:
            return "object data is not valid base64"
        case .storageNotConfigured:
            return "this CAS service has no storage backend"
        }
    }
}

public enum CASLimits {
    /// Largest object accepted over the JSON/WebSocket control plane. The
    /// native client caps inbound WebSocket messages at 1 MiB and base64
    /// inflates by a third, so this leaves room for the envelope. Larger
    /// objects need the streaming data path described in docs/design.md.
    public static let maxObjectBytes = 512 * 1024
}

/// Storage behind a `CASService`. The Worker implements it with shard actors;
/// it is a protocol so the service actor stays a stateless façade.
public protocol CASBackend: Sendable {
    func contains(digest: String) async throws -> Bool
    /// Stores the object under the identity the backend computes itself and
    /// returns that digest; a client never gets to name its own key.
    func put(refs: [String], data: [UInt8]) async throws -> String
    func get(digest: String) async throws -> CASObjectPayload?
    func actionGet(key: String) async throws -> String?
    func actionPut(key: String, value: String) async throws
}

/// The llbuild-worker CAS: the distributed actor a Worker hosts and a native
/// client (`casctl`, the swiftc plugin) resolves through `WorkersActorSystem`.
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
            protocolVersion: "0.2.0",
            storageConfigured: backend != nil
        )
    }

    public distributed func contains(digest: String) async throws -> Bool {
        try await requireBackend().contains(digest: try Self.validated(digest))
    }

    /// Stores an object and returns its digest, computed by the service with
    /// `CASIdentity`. Rejects objects over `CASLimits.maxObjectBytes`.
    public distributed func put(refs: [String], data: String) async throws -> String {
        guard let bytes = Data(base64Encoded: data) else { throw CASServiceError.invalidData }
        guard bytes.count <= CASLimits.maxObjectBytes else {
            throw CASServiceError.objectTooLarge(size: bytes.count, limit: CASLimits.maxObjectBytes)
        }
        return try await requireBackend().put(
            refs: try refs.map(Self.validated), data: [UInt8](bytes))
    }

    public distributed func get(digest: String) async throws -> CASObjectPayload? {
        try await requireBackend().get(digest: try Self.validated(digest))
    }

    public distributed func actionGet(key: String) async throws -> String? {
        try await requireBackend().actionGet(key: try Self.validated(key))
    }

    public distributed func actionPut(key: String, value: String) async throws {
        try await requireBackend().actionPut(
            key: try Self.validated(key), value: try Self.validated(value))
    }

    private func requireBackend() throws -> any CASBackend {
        guard let backend else { throw CASServiceError.storageNotConfigured }
        return backend
    }

    private static func validated(_ digest: String) throws -> String {
        guard let parsed = CASDigest(hex: digest), parsed.bytes.count == CASIdentity.digestSize else {
            throw CASServiceError.invalidDigest(digest)
        }
        return digest
    }
}
