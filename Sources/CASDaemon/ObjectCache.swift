import CASProtocol
import Foundation
import SwiftLRUCache

/// A content-addressed cache of objects on disk, for a daemon that sits between
/// compiler processes and the Worker. An object's name is its digest, so an entry
/// can never be stale: a cached object is the object, whenever it was stored.
///
/// Entries live at `<directory>/<first two hex digits>/<digest>` as one line of
/// comma-separated reference digests followed by the object's bytes, written to a
/// temporary file and renamed so a reader never sees half an object.
///
/// Which entries to keep is `SwiftLRUCache`'s job: it indexes the files by digest
/// with their sizes, limits the total to `maxBytes`, and calls `dispose` when it
/// evicts one, which is where the file is deleted. An object bigger than the whole
/// cache is not stored. A file that cannot be read back as an object (cut short,
/// refs that are not digests) is removed and reads as a miss.
public actor ObjectCache {
    public let directory: URL
    public let maxBytes: Int64
    private let index: LRUCache<String, Int64>

    /// Opens the cache in `directory` (created if missing) and indexes what is
    /// there, oldest first, so the recency order carries over from the last run
    /// (reads set a file's modification time). If the cap is lower than before, the
    /// oldest entries are evicted as the rest are indexed.
    public static func open(directory: URL, maxBytes: Int64) async throws -> ObjectCache {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = try ObjectCache(directory: directory, maxBytes: maxBytes)

        var found = [(name: String, size: Int64, modified: Date)]()
        let files = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        while let file = files?.nextObject() as? URL {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            let name = file.lastPathComponent
            // A full-length digest: `CASDigest(hex:)` alone would accept the two-digit
            // shard directories' names.
            guard values?.isRegularFile == true, name.count == CASIdentity.digestSize * 2, CASDigest(hex: name) != nil else {
                // A temporary file left by a store that never finished.
                if name.hasSuffix(".tmp") { try? FileManager.default.removeItem(at: file) }
                continue
            }
            found.append((name, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast))
        }
        for entry in found.sorted(by: { $0.modified < $1.modified }) {
            await cache.index.set(entry.name, value: entry.size)
        }
        return cache
    }

    private init(directory: URL, maxBytes: Int64) throws {
        self.directory = directory
        self.maxBytes = maxBytes
        var configuration = try Configuration<String, Int64>(maxSize: Int(maxBytes))
        configuration.maxEntrySize = Int(maxBytes)
        configuration.sizeCalculation = { size, _ in Int(size) }
        configuration.dispose = { _, name, reason in
            // Evicted for room, or removed because it could not be read: either way
            // the file goes. (A replaced entry is never disposed of here: `put`
            // does not store a digest that is already indexed.)
            if reason == .evict || reason == .delete {
                try? FileManager.default.removeItem(at: Self.path(of: name, in: directory))
            }
        }
        self.index = LRUCache(configuration: configuration)
    }

    /// Bytes held by the entries.
    public var size: Int64 { get async { Int64(await index.calculatedSize) } }
    /// How many objects are held.
    public var count: Int { get async { await index.size } }

    public func contains(_ digest: CASDigest) async -> Bool {
        await index.has(digest.hex)
    }

    /// The object stored under `digest`, which counts as a use, or `nil`.
    public func get(_ digest: CASDigest) async -> CASBlob? {
        let name = digest.hex
        guard await index.get(name) != nil else { return nil }
        let file = Self.path(of: name, in: directory)
        // Identity as well as shape: a file damaged into another well-formed object
        // must read as a miss and be refetched, not be served under the wrong name.
        guard let data = try? Data(contentsOf: file), let blob = Self.decode(data), blob.digest == digest else {
            _ = await index.delete(name)
            return nil
        }
        // So the recency order survives a restart.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return blob
    }

    /// Stores `blob` under its own digest and returns it. An object larger than
    /// `maxBytes` is not stored.
    @discardableResult
    public func put(_ blob: CASBlob) async throws -> CASDigest {
        let digest = blob.digest
        let name = digest.hex
        if await index.has(name) { _ = await index.get(name); return digest }

        let encoded = Self.encode(blob)
        guard Int64(encoded.count) <= maxBytes else { return digest }

        let file = Self.path(of: name, in: directory)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = file.appendingPathExtension("tmp")
        try encoded.write(to: temporary, options: .atomic)
        // `.atomic` renames the data into `temporary`; this second rename makes the
        // entry appear under its real name only once it is whole.
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)
        await index.set(name, value: Int64(encoded.count))
        return digest
    }

    // MARK: - Files

    private static func path(of name: String, in directory: URL) -> URL {
        directory.appendingPathComponent(String(name.prefix(2)), isDirectory: true).appendingPathComponent(name)
    }

    static func encode(_ blob: CASBlob) -> Data {
        var data = Data(blob.refs.map(\.hex).joined(separator: ",").utf8)
        data.append(UInt8(ascii: "\n"))
        data.append(contentsOf: blob.data)
        return data
    }

    static func decode(_ file: Data) -> CASBlob? {
        guard let newline = file.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        let header = String(decoding: file[file.startIndex..<newline], as: UTF8.self)
        var refs = [CASDigest]()
        for part in header.split(separator: ",", omittingEmptySubsequences: true) {
            guard let ref = CASDigest(hex: String(part)) else { return nil }
            refs.append(ref)
        }
        return CASBlob(refs: refs, data: [UInt8](file[file.index(after: newline)...]))
    }
}
