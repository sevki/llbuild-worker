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

    /// Stores an object of any size up to `CASLimits.maxLargeObjectBytes`.
    /// Objects over `CASLimits.maxObjectBytes` go up as chunks plus a manifest
    /// and are then registered, which the service only accepts after
    /// reassembling them and recomputing the identity.
    @discardableResult
    public func put(_ blob: CASBlob) async throws -> CASDigest {
        if blob.data.count <= CASLimits.maxObjectBytes {
            return try await putSmall(blob)
        }
        guard blob.data.count <= CASLimits.maxLargeObjectBytes else {
            throw CASServiceError.objectTooLarge(size: blob.data.count, limit: CASLimits.maxLargeObjectBytes)
        }
        let expected = blob.digest
        if try await contains(expected) { return expected }
        let chunkDigests = try await concurrently(CASChunking.chunks(of: blob.data)) { chunk in
            try await self.putSmall(CASBlob(refs: [], data: chunk))
        }
        let manifest = try await putSmall(
            CASBlob(refs: chunkDigests, data: CASChunking.manifestData(size: blob.data.count)))
        try await service.putLarge(digest: expected.hex, refs: blob.refs.map(\.hex), manifest: manifest.hex)
        return expected
    }

    private func putSmall(_ blob: CASBlob) async throws -> CASDigest {
        let digest = blob.digest
        try await service.put(
            digest: digest.hex, refs: blob.refs.map(\.hex),
            data: Data(blob.data).base64EncodedString())
        return digest
    }

    public func get(_ digest: CASDigest) async throws -> CASBlob? {
        if let small = try await getSmall(digest) { return small }
        guard let large = try await service.getLarge(digest: digest.hex) else { return nil }
        guard let manifestDigest = CASDigest(hex: large.manifest),
              let manifest = try await getSmall(manifestDigest),
              CASChunking.size(ofManifestData: manifest.data) == large.size else {
            throw CASClientError("large object \(digest.hex) has an invalid manifest")
        }
        let pieces = try await concurrently(manifest.refs) { chunk in
            guard let piece = try await self.getSmall(chunk) else {
                throw CASClientError("large object \(digest.hex) is missing chunk \(chunk.hex)")
            }
            return piece.data
        }
        var data = [UInt8]()
        data.reserveCapacity(large.size)
        for piece in pieces { data.append(contentsOf: piece) }
        let refs = try large.refs.map { ref -> CASDigest in
            guard let parsed = CASDigest(hex: ref) else {
                throw CASClientError("large object \(digest.hex) has invalid ref \(ref)")
            }
            return parsed
        }
        let blob = CASBlob(refs: refs, data: data)
        guard data.count == large.size, blob.digest == digest else {
            throw CASClientError("large object \(digest.hex) does not match its digest")
        }
        return blob
    }

    private func getSmall(_ digest: CASDigest) async throws -> CASBlob? {
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

    /// Chunks in flight at once. They land on different shard actors, so they
    /// proceed in parallel; the bound keeps the connection's queue short.
    private static let chunkConcurrency = 8

    /// Maps `items` with up to `chunkConcurrency` calls in flight, keeping
    /// the results in input order.
    private func concurrently<Item: Sendable, Result: Sendable>(
        _ items: [Item], _ transform: @escaping @Sendable (Item) async throws -> Result
    ) async throws -> [Result] {
        try await withThrowingTaskGroup(of: (Int, Result).self) { group in
            var results = [Result?](repeating: nil, count: items.count)
            var next = 0
            func launch() {
                let index = next
                next += 1
                let item = items[index]
                group.addTask { (index, try await transform(item)) }
            }
            while next < min(Self.chunkConcurrency, items.count) { launch() }
            while let (index, result) = try await group.next() {
                results[index] = result
                if next < items.count { launch() }
            }
            return results.map { $0! }
        }
    }

    public func close() async {
        system.close()
        await system.wait()
    }
}
