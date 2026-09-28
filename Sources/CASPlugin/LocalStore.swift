import CASProtocol
import Foundation

typealias StoredObject = CASBlob

struct StoreError: Error, CustomStringConvertible {
    var description: String
}

/// Objects and action-cache entries under one directory. Every write is a
/// temp-file rename, so concurrent compiler processes can share a directory.
///
/// Layout:
///   objects/<hh>/<hex digest>   "LCAS" u32le version=1, u32le refs, refs..., data
///   actions/<hh>/<hex key>      hex digest of the result object
struct LocalStore: Sendable {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    func contains(_ digest: CASDigest) -> Bool {
        FileManager.default.fileExists(atPath: objectURL(digest).path)
    }

    func put(_ object: StoredObject, digest: CASDigest) throws {
        if contains(digest) { return }
        var blob = [UInt8]()
        blob.reserveCapacity(12 + object.refs.count * CASIdentity.digestSize + object.data.count)
        blob.append(contentsOf: Array("LCAS".utf8))
        blob.append(contentsOf: Self.le32(1))
        blob.append(contentsOf: Self.le32(UInt32(object.refs.count)))
        for ref in object.refs {
            blob.append(contentsOf: ref.bytes)
        }
        blob.append(contentsOf: object.data)
        try write(blob, to: objectURL(digest))
    }

    func get(_ digest: CASDigest) throws -> StoredObject? {
        let url = objectURL(digest)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let blob = [UInt8](try Data(contentsOf: url))
        guard blob.count >= 12, Array(blob[0..<4]) == Array("LCAS".utf8),
              Self.readLE32(blob, 4) == 1 else {
            throw StoreError(description: "corrupt object \(digest.hex)")
        }
        let refCount = Int(Self.readLE32(blob, 8))
        let dataStart = 12 + refCount * CASIdentity.digestSize
        guard blob.count >= dataStart else {
            throw StoreError(description: "truncated object \(digest.hex)")
        }
        var refs = [CASDigest]()
        for index in 0..<refCount {
            let start = 12 + index * CASIdentity.digestSize
            refs.append(CASDigest(bytes: Array(blob[start..<start + CASIdentity.digestSize])))
        }
        return StoredObject(refs: refs, data: Array(blob[dataStart...]))
    }

    func actionGet(_ key: CASDigest) throws -> CASDigest? {
        let url = actionURL(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        guard let value = CASDigest(hex: text) else {
            throw StoreError(description: "corrupt action entry \(key.hex)")
        }
        return value
    }

    func actionPut(_ key: CASDigest, value: CASDigest) throws {
        try write(Array(value.hex.utf8), to: actionURL(key))
    }

    private func objectURL(_ digest: CASDigest) -> URL {
        shardedURL("objects", digest)
    }

    private func actionURL(_ key: CASDigest) -> URL {
        shardedURL("actions", key)
    }

    private func shardedURL(_ kind: String, _ digest: CASDigest) -> URL {
        let hex = digest.hex
        return root.appendingPathComponent(kind, isDirectory: true)
            .appendingPathComponent(String(hex.prefix(2)), isDirectory: true)
            .appendingPathComponent(hex, isDirectory: false)
    }

    private func write(_ bytes: [UInt8], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)")
        try Data(bytes).write(to: temp)
        if rename(temp.path, url.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw StoreError(description: "rename to \(url.path) failed: errno \(code)")
        }
    }

    private static func le32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32(8 * $0)) }
    }

    private static func readLE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << UInt32(8 * $1) }
    }
}
