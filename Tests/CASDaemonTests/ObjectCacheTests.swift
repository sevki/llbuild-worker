import CASProtocol
import Foundation
import XCTest
@testable import CASDaemon

final class ObjectCacheTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("objectcache-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func blob(_ text: String, refs: [CASDigest] = []) -> CASBlob {
        CASBlob(refs: refs, data: Array(text.utf8))
    }

    func testAStoredObjectComesBackWithItsRefs() async throws {
        let cache = try await ObjectCache.open(directory: directory, maxBytes: 1 << 20)
        let child = blob("child")
        let parent = blob("parent", refs: [child.digest])
        try await cache.put(child)
        let digest = try await cache.put(parent)
        XCTAssertEqual(digest, parent.digest)
        let back = await cache.get(parent.digest)
        XCTAssertEqual(back, parent)
        XCTAssertEqual(back?.refs, [child.digest])
        let has = await cache.contains(child.digest)
        XCTAssertTrue(has)
    }

    func testAnUnknownDigestIsAMiss() async throws {
        let cache = try await ObjectCache.open(directory: directory, maxBytes: 1 << 20)
        let missing = await cache.get(blob("nothing").digest)
        XCTAssertNil(missing)
        let has = await cache.contains(blob("nothing").digest)
        XCTAssertFalse(has)
    }

    func testBinaryBytesIncludingNewlinesSurvive() async throws {
        let cache = try await ObjectCache.open(directory: directory, maxBytes: 1 << 20)
        let odd = CASBlob(refs: [], data: [0, 10, 13, 255, 10, 10, 0, 42])
        try await cache.put(odd)
        let back = await cache.get(odd.digest)
        XCTAssertEqual(back, odd)
    }

    func testEntriesSurviveReopeningTheCache() async throws {
        let first = try await ObjectCache.open(directory: directory, maxBytes: 1 << 20)
        let stored = blob("kept")
        try await first.put(stored)
        let reopened = try await ObjectCache.open(directory: directory, maxBytes: 1 << 20)
        let back = await reopened.get(stored.digest)
        XCTAssertEqual(back, stored)
        let count = await reopened.count
        XCTAssertEqual(count, 1)
        let size = await reopened.size
        XCTAssertGreaterThan(size, 0)
    }

    func testTheLeastRecentlyUsedEntriesGoFirstWhenTheCapIsPassed() async throws {
        let objects = (0..<6).map { blob(String(repeating: String($0), count: 100)) }
        let each = Int64(ObjectCache.encode(objects[0]).count)
        // Room for five, not six.
        let cache = try await ObjectCache.open(directory: directory, maxBytes: each * 5 + each / 2)
        for object in objects.prefix(5) { try await cache.put(object) }
        _ = await cache.get(objects[0].digest)          // objects[0] becomes the most recently used
        try await cache.put(objects[5])                  // past the cap: evict

        let total = await cache.size
        XCTAssertLessThanOrEqual(total, each * 5 + each / 2)
        let oldestGone = await cache.contains(objects[1].digest)        // the least recently used
        XCTAssertFalse(oldestGone)
        let touchedKept = await cache.contains(objects[0].digest)
        XCTAssertTrue(touchedKept)
        let newestKept = await cache.contains(objects[5].digest)
        XCTAssertTrue(newestKept)
    }

    func testAnObjectLargerThanTheWholeCacheIsNotStoredAndDisturbsNothing() async throws {
        let cache = try await ObjectCache.open(directory: directory, maxBytes: 300)
        let kept = blob("small")
        try await cache.put(kept)
        let big = blob(String(repeating: "x", count: 1000))
        let digest = try await cache.put(big)
        XCTAssertEqual(digest, big.digest)
        let stored = await cache.contains(big.digest)
        XCTAssertFalse(stored)
        let back = await cache.get(big.digest)
        XCTAssertNil(back)
        let stillThere = await cache.get(kept.digest)
        XCTAssertEqual(stillThere, kept)
    }

    func testEvictedFilesAreDeletedFromDisk() async throws {
        let objects = (0..<4).map { blob(String(repeating: String($0), count: 100)) }
        let each = Int64(ObjectCache.encode(objects[0]).count)
        let cache = try await ObjectCache.open(directory: directory, maxBytes: each * 2 + each / 2)
        for object in objects { try await cache.put(object) }
        var onDisk = 0
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            let isFile = (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            if isFile, file.lastPathComponent.count == CASIdentity.digestSize * 2 { onDisk += 1 }
        }
        let count = await cache.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(onDisk, 2, "the index and the disk disagree")
    }

    func testLoweringTheCapOnReopenEvictsTheOldestFirst() async throws {
        let objects = (0..<3).map { blob(String(repeating: String($0), count: 100)) }
        let each = Int64(ObjectCache.encode(objects[0]).count)
        let first = try await ObjectCache.open(directory: directory, maxBytes: each * 10)
        for (n, object) in objects.enumerated() {
            try await first.put(object)
            // Distinct modification times: the order a restart recovers.
            let name = object.digest.hex
            let file = directory.appendingPathComponent(String(name.prefix(2))).appendingPathComponent(name)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1_000 + n))], ofItemAtPath: file.path)
        }
        let smaller = try await ObjectCache.open(directory: directory, maxBytes: each * 2 + each / 2)
        let oldest = await smaller.contains(objects[0].digest)
        XCTAssertFalse(oldest)
        let middle = await smaller.contains(objects[1].digest)
        XCTAssertTrue(middle)
        let newest = await smaller.contains(objects[2].digest)
        XCTAssertTrue(newest)
    }

    func testAFileThatCannotBeReadBackIsRemovedAndReadsAsAMiss() async throws {
        let cache = try await ObjectCache.open(directory: directory, maxBytes: 1 << 20)
        let stored = blob("will be damaged")
        try await cache.put(stored)
        let name = stored.digest.hex
        let file = directory.appendingPathComponent(String(name.prefix(2))).appendingPathComponent(name)
        try Data("not an object: no newline".utf8).write(to: file)
        let back = await cache.get(stored.digest)
        XCTAssertNil(back)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let count = await cache.count
        XCTAssertEqual(count, 0)
    }

    func testAnUnfinishedTemporaryFileIsClearedOnOpen() async throws {
        let shard = directory.appendingPathComponent("ab")
        try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: true)
        let leftover = shard.appendingPathComponent(String(repeating: "a", count: 64) + ".tmp")
        try Data("half".utf8).write(to: leftover)
        let cache = try await ObjectCache.open(directory: directory, maxBytes: 1 << 20)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        let count = await cache.count
        XCTAssertEqual(count, 0)
    }

    func testManyConcurrentStoresAndReadsAgree() async throws {
        let cache = try await ObjectCache.open(directory: directory, maxBytes: 1 << 26)
        let objects = (0..<200).map { blob("object \($0)") }
        await withTaskGroup(of: Void.self) { group in
            for object in objects { group.addTask { _ = try? await cache.put(object) } }
        }
        for object in objects {
            let back = await cache.get(object.digest)
            XCTAssertEqual(back, object)
        }
        let count = await cache.count
        XCTAssertEqual(count, 200)
    }

    func testAFileDamagedIntoAnotherValidObjectReadsAsAMiss() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try await ObjectCache.open(directory: directory, maxBytes: 1 << 20)
        let real = CASBlob(refs: [], data: Array("real".utf8))
        try await cache.put(real)
        // The file now holds a different, well-formed object.
        let name = real.digest.hex
        let file = directory.appendingPathComponent(String(name.prefix(2))).appendingPathComponent(name)
        try ObjectCache.encode(CASBlob(refs: [], data: Array("forged".utf8))).write(to: file)
        let read = await cache.get(real.digest)
        XCTAssertNil(read)
        let held = await cache.contains(real.digest)
        XCTAssertFalse(held, "the bad entry is dropped so it can be refetched")
    }
}
