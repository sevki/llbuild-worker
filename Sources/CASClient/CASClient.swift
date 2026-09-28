import CASProtocol
import Distributed
import Foundation
import WorkersDistributed

public struct CASClientError: Error, CustomStringConvertible {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// Native client for a llbuild-worker CAS: resolves the distributed
/// `CASService` over `WorkersActorSystem` and checks everything that comes
/// back. The service is not trusted for identity: a fetched object must hash
/// to the digest it was requested under, and a stored one must come back
/// under the digest computed locally.
public final class CASClient: @unchecked Sendable {
    private let system: WorkersActorSystem
    private let service: CASService

    public init(workerURL: URL) throws {
        system = WorkersActorSystem(worker: workerURL)
        service = try CASService.resolve(id: "cas-service", using: system)
    }

    public func status() async throws -> CASServiceStatus {
        try await service.status()
    }

    public func contains(_ digest: CASDigest) async throws -> Bool {
        try await service.contains(digest: digest.hex)
    }

    @discardableResult
    public func put(_ blob: CASBlob) async throws -> CASDigest {
        let expected = blob.digest
        let returned = try await service.put(
            refs: blob.refs.map(\.hex), data: Data(blob.data).base64EncodedString())
        guard returned == expected.hex else {
            throw CASClientError("service stored the object as \(returned), expected \(expected.hex)")
        }
        return expected
    }

    public func get(_ digest: CASDigest) async throws -> CASBlob? {
        guard let payload = try await service.get(digest: digest.hex) else { return nil }
        guard let data = Data(base64Encoded: payload.data) else {
            throw CASClientError("object \(digest.hex) has invalid base64 data")
        }
        let refs = try payload.refs.map { ref -> CASDigest in
            guard let parsed = CASDigest(hex: ref) else {
                throw CASClientError("object \(digest.hex) has invalid ref \(ref)")
            }
            return parsed
        }
        let blob = CASBlob(refs: refs, data: [UInt8](data))
        guard blob.digest == digest else {
            throw CASClientError("object \(digest.hex) does not match its digest")
        }
        return blob
    }

    public func actionGet(_ key: CASDigest) async throws -> CASDigest? {
        guard let value = try await service.actionGet(key: key.hex) else { return nil }
        guard let parsed = CASDigest(hex: value) else {
            throw CASClientError("action \(key.hex) has invalid value \(value)")
        }
        return parsed
    }

    public func actionPut(_ key: CASDigest, value: CASDigest) async throws {
        try await service.actionPut(key: key.hex, value: value.hex)
    }

    public func close() async {
        system.close()
        await system.wait()
    }
}
