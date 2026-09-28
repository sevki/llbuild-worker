import Distributed

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

/// Distributed control-plane actor shared by the Worker and native CLI.
///
/// The actor is deliberately status-only in this first transport slice.
/// CAS reads and writes require a durable shard backend and a separate
/// streaming data path; they must not be represented as working until that
/// backend exists.
public distributed actor CASService {
    public typealias ActorSystem = WorkersActorSystem

    public distributed func status() -> CASServiceStatus {
        CASServiceStatus(
            service: "llbuild-worker",
            protocolVersion: "0.1.0",
            storageConfigured: false
        )
    }
}
