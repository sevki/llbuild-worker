import CASClient
import CASProtocol
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

@testable import CASDaemon

/// An in-memory Worker that counts what it is asked and can be switched off.
actor FakeUpstream: CASUpstream {
    struct Down: Error {}
    var objects: [CASDigest: CASBlob] = [:]
    var actions: [CASDigest: CASDigest] = [:]
    var down = false
    var gets: [CASDigest] = []
    var puts: [CASDigest] = []
    var containsCalls = 0
    var actionGets = 0

    func setDown(_ value: Bool) { down = value }
    func seed(_ blob: CASBlob) { objects[blob.digest] = blob }
    func seed(action key: CASDigest, value: CASDigest) { actions[key] = value }

    func contains(_ digest: CASDigest) async throws -> Bool {
        if down { throw Down() }
        containsCalls += 1
        return objects[digest] != nil
    }
    func get(_ digest: CASDigest) async throws -> CASBlob? {
        if down { throw Down() }
        gets.append(digest)
        return objects[digest]
    }
    func put(_ blob: CASBlob) async throws {
        if down { throw Down() }
        for ref in blob.refs where objects[ref] == nil { throw Down() }
        puts.append(blob.digest)
        objects[blob.digest] = blob
    }
    func actionGet(_ key: CASDigest) async throws -> CASDigest? {
        if down { throw Down() }
        actionGets += 1
        return actions[key]
    }
    func actionPut(_ key: CASDigest, value: CASDigest) async throws {
        if down { throw Down() }
        guard objects[value] != nil else { throw Down() }
        actions[key] = value
    }
}

final class DaemonTests: XCTestCase {
    var directory: URL!
    var upstream: FakeUpstream!
    var daemon: CASDaemon!
    var port = 0

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("casd-\(UUID().uuidString)")
        upstream = FakeUpstream()
        let fake = upstream!
        daemon = CASDaemon(.init(directory: directory, maxBytes: 64 << 20) { _ in fake })
        port = try await daemon.start()
    }

    override func tearDown() async throws {
        await daemon.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    func client(_ scope: String = "s") throws -> CASClient {
        try CASClient(workerURL: URL(string: "http://127.0.0.1:\(port)/\(scope)")!)
    }

    func blob(_ text: String, refs: [CASDigest] = []) -> CASBlob {
        CASBlob(refs: refs, data: Array(text.utf8))
    }

    func testStatusAndLookupsAnswerLikeTheWorker() async throws {
        let client = try client()
        let status = try await client.status()
        XCTAssertTrue(status.storageConfigured)
        let missing = blob("nothing").digest
        let has = try await client.contains(missing)
        XCTAssertFalse(has)
        let action = try await client.actionGet(missing)
        XCTAssertNil(action)
        await client.close()
    }

    func testWritesAreLocalUntilTheActionThenReachUpstreamChildrenFirst() async throws {
        let client = try client()
        let child = blob("child"), parent = blob("parent", refs: [blob("child").digest])
        try await client.put(child)
        try await client.put(parent)
        let key = blob("key").digest
        let before = await upstream.objects.count
        XCTAssertEqual(before, 0, "nothing is forwarded until the action")
        try await client.actionPut(key, value: parent.digest)
        await daemon.drain()
        let puts = await upstream.puts
        XCTAssertEqual(puts, [child.digest, parent.digest])
        let stored = await upstream.actions[key]
        XCTAssertEqual(stored, parent.digest)
        await client.close()
    }

    func testAnActionWhoseValueWasNotUploadedIsRefused() async throws {
        let client = try client()
        do {
            try await client.actionPut(blob("k").digest, value: blob("never uploaded").digest)
            XCTFail("expected a refusal")
        } catch {}
        await client.close()
    }

    func testAnObjectIsFetchedUpstreamOnce() async throws {
        let object = blob("shared")
        await upstream.seed(object)
        let client = try client()
        for _ in 0..<3 {
            let fetched = try await client.get(object.digest)
            XCTAssertEqual(fetched, object)
        }
        let gets = await upstream.gets
        XCTAssertEqual(gets, [object.digest])
        await client.close()
    }

    func testAnActionHitBringsItsClosureAhead() async throws {
        let leaf = blob("leaf"), mid = blob("mid", refs: [leaf.digest]), root = blob("root", refs: [mid.digest])
        for object in [leaf, mid, root] { await upstream.seed(object) }
        let key = blob("key").digest
        await upstream.seed(action: key, value: root.digest)
        let client = try client()
        let value = try await client.actionGet(key)
        XCTAssertEqual(value, root.digest)

        // No client read yet: the daemon fetches the closure by itself.
        for _ in 0..<100 {
            if await upstream.gets.count == 3 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let fetched = await Set(upstream.gets)
        XCTAssertEqual(fetched, [leaf.digest, mid.digest, root.digest])
        await upstream.setDown(true)
        let local = try await client.get(leaf.digest)
        XCTAssertEqual(local, leaf, "served locally with the Worker unreachable")
        await client.close()
    }

    func testTroubleUpstreamIsAMissAndWritesAreRetried() async throws {
        await upstream.setDown(true)
        let client = try client()
        let unreachable = try await client.actionGet(blob("a").digest)
        XCTAssertNil(unreachable)
        let there = try await client.contains(blob("b").digest)
        XCTAssertFalse(there)

        let object = blob("built while offline")
        try await client.put(object)
        let key = blob("k").digest
        try await client.actionPut(key, value: object.digest)
        try await Task.sleep(for: .milliseconds(100))
        await upstream.setDown(false)
        await daemon.drain()
        let stored = await upstream.actions[key]
        XCTAssertEqual(stored, object.digest, "forwarded once the Worker came back")
        await client.close()
    }

    func testAnObjectThatDoesNotMatchItsDigestIsRejected() async throws {
        let url = URL(string: "http://127.0.0.1:\(port)/s/objects/\(blob("real").digest.hex)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = Data("forged".utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
    }

    func testScopesAreSeparateAndBadNamesRefused() async throws {
        let a = try client("a"), b = try client("b")
        let object = blob("only in a")
        try await a.put(object)
        let inB = try await b.get(object.digest)
        XCTAssertNil(inB)
        await a.close()
        await b.close()

        for path in ["/../etc/objects/\(object.digest.hex)", "/%2e%2e/objects/\(object.digest.hex)"] {
            let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404, path)
        }
    }

    func testManyCallsShareOneConnection() async throws {
        let client = try client()
        let digests = (0..<200).map { blob("n\($0)").digest }
        let results = try await withThrowingTaskGroup(of: Bool.self) { group in
            for digest in digests { group.addTask { try await client.contains(digest) } }
            return try await group.reduce(into: [Bool]()) { $0.append($1) }
        }
        XCTAssertEqual(results.count, 200)
        await client.close()
    }

    func testLargeObjectRoundTrip() async throws {
        let big = CASBlob(refs: [], data: (0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let client = try client()
        try await client.put(big)
        let back = try await client.get(big.digest)
        XCTAssertEqual(back, big)
        await client.close()
    }

    func testPendingActionsSurviveARestart() async throws {
        await upstream.setDown(true)
        let client = try client()
        let object = blob("kept")
        try await client.put(object)
        let key = blob("pk").digest
        try await client.actionPut(key, value: object.digest)
        await client.close()
        await daemon.stop()

        await upstream.setDown(false)
        let fake = upstream!
        daemon = CASDaemon(.init(directory: directory, maxBytes: 64 << 20) { _ in fake })
        port = try await daemon.start()
        let again = try self.client()
        _ = try await again.status()   // the scope is opened, its pending actions resumed
        await daemon.drain()
        let stored = await upstream.actions[key]
        XCTAssertEqual(stored, object.digest)
        await again.close()
    }
}
