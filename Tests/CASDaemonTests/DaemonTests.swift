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
    var manyCalls: [Int] = []
    func actionGetMany(_ keys: [CASDigest]) async throws -> [CASDigest?] {
        if down { throw Down() }
        manyCalls.append(keys.count)
        return keys.map { actions[$0] }
    }
    func actionPut(_ key: CASDigest, value: CASDigest) async throws {
        if down { throw Down() }
        guard objects[value] != nil else { throw Down() }
        // As at the Worker: a key keeps its first value.
        if let existing = actions[key], existing != value { throw Down() }
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

    func testLookupsThatArriveTogetherShareOneUpstreamCall() async throws {
        let object = blob("value")
        await upstream.seed(object)
        var keys: [CASDigest] = []
        for index in 0..<40 {
            let key = blob("action \(index)").digest
            keys.append(key)
            if index % 2 == 0 { await upstream.seed(action: key, value: object.digest) }
        }
        let client = try client()
        let answers = try await withThrowingTaskGroup(of: (Int, CASDigest?).self) { group in
            for (index, key) in keys.enumerated() {
                group.addTask { (index, try await client.actionGet(key)) }
            }
            var all = [CASDigest?](repeating: nil, count: keys.count)
            for try await (index, value) in group { all[index] = value }
            return all
        }
        for (index, answer) in answers.enumerated() {
            XCTAssertEqual(answer, index % 2 == 0 ? object.digest : nil, "key \(index)")
        }
        let calls = await upstream.manyCalls
        XCTAssertEqual(calls.reduce(0, +), 40)
        XCTAssertLessThan(calls.count, 10, "40 lookups should not cost 40 calls: \(calls)")
        let singles = await upstream.actionGets
        XCTAssertEqual(singles, 0)
        await client.close()
    }

    func testAcknowledgedObjectsSurviveCachePressureUntilTheActionIsSent() async throws {
        await daemon.stop()
        let fake = upstream!
        // A cache far smaller than the closure being built.
        daemon = CASDaemon(.init(directory: directory, maxBytes: 4096) { _ in fake })
        port = try await daemon.start()
        let client = try client()

        var previous: [CASDigest] = []
        var all: [CASBlob] = []
        for index in 0..<40 {
            let object = CASBlob(refs: previous, data: Array(repeating: UInt8(index), count: 1000))
            try await client.put(object)
            all.append(object)
            previous = [object.digest]
        }
        let key = blob("pressure").digest
        try await client.actionPut(key, value: all.last!.digest)
        await daemon.drain()
        let stored = await upstream.actions[key]
        XCTAssertEqual(stored, all.last!.digest)
        let held = await Set(upstream.objects.keys)
        XCTAssertEqual(held, Set(all.map(\.digest)), "every object of the chain reached the Worker")
        await client.close()
    }

    func testAStaleSpoolFileIsSweptUnlessAPendingActionNeedsIt() async throws {
        await upstream.setDown(true)
        let client = try client()
        let child = blob("needed"), parent = blob("parent", refs: [child.digest]), orphan = blob("orphan")
        for object in [child, parent, orphan] { try await client.put(object) }
        try await client.actionPut(blob("k").digest, value: parent.digest)
        await client.close()
        await daemon.stop()

        // A restart more than a day later.
        let spool = directory.appendingPathComponent("s/spool")
        let files = FileManager.default.enumerator(at: spool, includingPropertiesForKeys: [.isRegularFileKey])
        let old = Date().addingTimeInterval(-3 * 24 * 3600)
        while let file = files?.nextObject() as? URL {
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
            }
        }
        let fake = upstream!
        daemon = CASDaemon(.init(directory: directory, maxBytes: 1 << 20) { _ in fake })
        port = try await daemon.start()
        let again = try self.client()
        _ = try await again.status()
        func spooled(_ d: CASDigest) -> Bool {
            FileManager.default.fileExists(atPath: spool.appendingPathComponent(String(d.hex.prefix(2))).appendingPathComponent(d.hex).path)
        }
        XCTAssertTrue(spooled(child.digest), "reachable from a pending action")
        XCTAssertTrue(spooled(parent.digest))
        XCTAssertFalse(spooled(orphan.digest), "nothing claims it")
        await again.close()
    }

    func testAnActionKeyKeepsItsFirstValue() async throws {
        let client = try client()
        let first = blob("first"), second = blob("second")
        try await client.put(first)
        try await client.put(second)
        let key = blob("key").digest
        try await client.actionPut(key, value: first.digest)
        try await client.actionPut(key, value: first.digest)   // a repeat is fine
        do {
            try await client.actionPut(key, value: second.digest)
            XCTFail("a different value for an existing key was accepted")
        } catch {}
        let kept = try await client.actionGet(key)
        XCTAssertEqual(kept, first.digest)
        await client.close()
    }

    func testAnUpstreamValueThatWonTheKeyReplacesAQueuedOne() async throws {
        let mine = blob("mine"), theirs = blob("theirs")
        await upstream.seed(theirs)
        let key = blob("contested").digest
        await upstream.seed(action: key, value: theirs.digest)
        let client = try client()
        try await client.put(mine)
        try await client.actionPut(key, value: mine.digest)
        await daemon.drain()
        let stored = await upstream.actions[key]
        XCTAssertEqual(stored, theirs.digest, "the Worker keeps the first value")
        let pending = await Set((try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("s/pending").path)) ?? [])
        XCTAssertTrue(pending.isEmpty, "nothing is retried forever")
        await client.close()
    }

    func testAnActionQueuedWhileTheWorkerWasDownIsSentWhenItReturns() async throws {
        await daemon.stop()
        let fake = upstream!
        daemon = CASDaemon(.init(directory: directory, maxBytes: 1 << 20, retryInterval: .milliseconds(200)) { _ in fake })
        port = try await daemon.start()
        await upstream.setDown(true)
        let client = try client()
        let object = blob("patient")
        try await client.put(object)
        let key = blob("pk2").digest
        try await client.actionPut(key, value: object.digest)
        try await Task.sleep(for: .seconds(2))   // past the first few attempts
        let early = await upstream.actions[key]
        XCTAssertNil(early)

        await upstream.setDown(false)
        var stored: CASDigest?
        for _ in 0..<50 where stored == nil {
            try await Task.sleep(for: .milliseconds(100))
            stored = await upstream.actions[key]
        }
        XCTAssertEqual(stored, object.digest, "retried without a restart")
        await client.close()
    }

    func testAnObjectAlreadyUpstreamNeedsNoLocalCopyToForwardItsAction() async throws {
        let child = blob("already there"), parent = blob("new parent", refs: [child.digest])
        await upstream.seed(child)            // upstream has it; the daemon never saw it
        let client = try client()
        try await client.put(parent)
        // A daemon that has just restarted knows nothing of `child`.
        let key = blob("rk").digest
        try await client.actionPut(key, value: parent.digest)
        await daemon.drain()
        let stored = await upstream.actions[key]
        XCTAssertEqual(stored, parent.digest)
        await client.close()
    }

    func testOnlyTheLoopbackIsServed() async throws {
        let fake = upstream!
        for host in ["0.0.0.0", "192.168.1.5", "::"] {
            let other = CASDaemon(.init(host: host, directory: directory, maxBytes: 1 << 20) { _ in fake })
            do {
                _ = try await other.start()
                XCTFail("\(host) was accepted")
            } catch {}
        }
    }

    func testOldActionRecordsAreDroppedPastTheCap() async throws {
        await daemon.stop()
        let fake = upstream!
        daemon = CASDaemon(.init(directory: directory, maxBytes: 1 << 20, maxActions: 10) { _ in fake })
        port = try await daemon.start()
        let client = try client()
        let object = blob("v")
        try await client.put(object)
        for index in 0..<30 { try await client.actionPut(blob("a\(index)").digest, value: object.digest) }
        await daemon.drain()
        await daemon.stop()

        let files = FileManager.default.enumerator(at: directory.appendingPathComponent("s/actions"), includingPropertiesForKeys: [.isRegularFileKey])
        var count = 0
        while let file = files?.nextObject() as? URL {
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { count += 1 }
        }
        XCTAssertLessThanOrEqual(count, 11 + 1, "the action directory holds \(count) records")
        XCTAssertGreaterThan(count, 0)
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
