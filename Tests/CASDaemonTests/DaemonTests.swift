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
    func resetCounters() { gets = []; puts = []; manyCalls = []; actionGets = 0 }
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
    var traces: [CASDigest: [CASDigest]] = [:]
    var tracePuts = 0
    func traceGet(_ key: CASDigest) async throws -> [CASDigest]? {
        if down { throw Down() }
        return traces[key]
    }
    func tracePut(_ key: CASDigest, keys: [CASDigest]) async throws {
        if down { throw Down() }
        tracePuts += 1
        traces[key] = keys
    }

    var manyCalls: [Int] = []
    func actionGetMany(_ keys: [CASDigest]) async throws -> [CASDigest?] {
        if down { throw Down() }
        manyCalls.append(keys.count)
        try await Task.sleep(for: .milliseconds(20))     // a round trip, so lookups pile up behind it
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

/// A TCP listener that completes connections at the kernel and then says nothing,
/// like a Worker that has stopped answering.
final class SilentServer {
    private let descriptor: Int32
    let port: Int

    init() {
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        listen(fd, 16)
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &length) }
        }
        descriptor = fd
        port = Int(UInt16(bigEndian: bound.sin_port))
    }

    deinit { close(descriptor) }
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

    func testTheDaemonAnswersABatchOfLookupsLikeTheWorker() async throws {
        let object = blob("batched")
        await upstream.seed(object)
        let hit = blob("hit").digest, miss = blob("miss").digest
        await upstream.seed(action: hit, value: object.digest)
        let client = try client()
        let answers = try await client.actionGetMany([miss, hit, miss])
        XCTAssertEqual(answers, [nil, object.digest, nil])
        let none = try await client.actionGetMany([])
        XCTAssertEqual(none, [])
        await client.close()
    }

    func testADamagedSpoolFileIsNotTakenForACopyAndAPutRepairsIt() async throws {
        await daemon.stop()
        let fake = upstream!
        // A cache too small to keep anything, so the spool holds the only copy.
        daemon = CASDaemon(.init(directory: directory, maxBytes: 1) { _ in fake })
        port = try await daemon.start()
        let client = try client()
        let object = blob("only in the spool")
        try await client.put(object)
        let file = directory.appendingPathComponent("s/spool")
            .appendingPathComponent(String(object.digest.hex.prefix(2))).appendingPathComponent(object.digest.hex)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        try Data("garbage".utf8).write(to: file)
        await upstream.setDown(true)            // so `contains` cannot be answered upstream
        let held = try await client.contains(object.digest)
        XCTAssertFalse(held, "a damaged file is not a copy")
        try await client.put(object)            // repairs it
        let repaired = try await client.contains(object.digest)
        XCTAssertTrue(repaired)
        await client.close()
    }

    func testPruningNeverTakesTheRecordOfAnActionStillPending() async throws {
        await daemon.stop()
        let fake = upstream!
        daemon = CASDaemon(.init(directory: directory, maxBytes: 1 << 20, maxActions: 10, retryInterval: .seconds(3600)) { _ in fake })
        port = try await daemon.start()
        await upstream.setDown(true)            // every action stays pending
        let client = try client()
        let object = blob("shared value")
        try await client.put(object)
        let keys = (0..<30).map { blob("pending \($0)").digest }
        for key in keys { try await client.actionPut(key, value: object.digest) }
        await client.close()
        await daemon.stop()

        await upstream.setDown(false)
        daemon = CASDaemon(.init(directory: directory, maxBytes: 1 << 20, maxActions: 10) { _ in fake })
        port = try await daemon.start()
        let again = try self.client()
        _ = try await again.status()
        await daemon.drain()
        var stored = 0
        for key in keys where await upstream.actions[key] == object.digest { stored += 1 }
        XCTAssertEqual(stored, 30, "every acknowledged action survived the restart")
        await again.close()
    }

    func testAPutOfAnOldSpooledObjectRefreshesItsAge() async throws {
        await daemon.stop()
        let fake = upstream!
        daemon = CASDaemon(.init(directory: directory, maxBytes: 1) { _ in fake })   // nothing fits the cache
        port = try await daemon.start()
        await upstream.setDown(true)
        let client = try client()
        let object = blob("old but wanted again")
        try await client.put(object)
        let file = directory.appendingPathComponent("s/spool")
            .appendingPathComponent(String(object.digest.hex.prefix(2))).appendingPathComponent(object.digest.hex)
        let old = Date().addingTimeInterval(-3 * 24 * 3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)

        try await client.put(object)
        let modified = try XCTUnwrap(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        XCTAssertGreaterThan(modified, Date().addingTimeInterval(-60), "a sweep that listed it as old must see it as new")
        await client.close()
    }

    // MARK: Traces

    /// Runs a "build": looks up `keys` in order, through a daemon over `upstream`
    /// with a fresh cache directory, then stops it so the trace is uploaded.
    private func build(_ keys: [CASDigest], debounce: Duration = .seconds(20)) async throws {
        await daemon.stop()
        let fake = upstream!
        daemon = CASDaemon(.init(
            directory: directory.appendingPathComponent("build-\(UUID().uuidString)"), maxBytes: 64 << 20,
            traceDebounce: debounce) { _ in fake })
        port = try await daemon.start()
        let client = try self.client()
        for key in keys { _ = try await client.actionGet(key) }
        await daemon.drain()
        await client.close()
        // The daemon fetches the closures of what it found in the background; let that
        // settle, so it does not count against whatever the test measures next.
        var seen = -1
        while seen != (await upstream.gets.count) {
            seen = await upstream.gets.count
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    private func seedBuild(_ count: Int) async -> (keys: [CASDigest], objects: [CASBlob]) {
        var keys: [CASDigest] = [], objects: [CASBlob] = []
        for index in 0..<count {
            let leaf = blob("leaf \(index)"), root = blob("root \(index)", refs: [leaf.digest])
            let key = blob("trace action \(index)").digest
            await upstream.seed(leaf)
            await upstream.seed(root)
            await upstream.seed(action: key, value: root.digest)
            keys.append(key)
            objects += [leaf, root]
        }
        return (keys, objects)
    }

    func testABuildLeavesItsTraceUnderItsFirstAction() async throws {
        let (keys, _) = await seedBuild(12)
        try await build(keys)
        let trace = await upstream.traces[keys[0]]
        XCTAssertEqual(trace, keys, "every action looked up, in order, under the first")
    }

    func testTheNextBuildIsPrefetchedFromTheTrace() async throws {
        let (keys, objects) = await seedBuild(30)
        try await build(keys)
        await upstream.resetCounters()

        // A new machine: empty cache, same Worker. Only the first action is asked for.
        await daemon.stop()
        let fake = upstream!
        daemon = CASDaemon(.init(directory: directory.appendingPathComponent("fresh"), maxBytes: 64 << 20) { _ in fake })
        port = try await daemon.start()
        let client = try client()
        let first = try await client.actionGet(keys[0])
        XCTAssertNotNil(first)

        // Nothing else is asked for, yet the rest of the build arrives.
        var fetched = 0
        for _ in 0..<100 {
            fetched = await upstream.gets.count
            if fetched >= objects.count { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(fetched, objects.count, "every object of the build was fetched ahead of the compiler")

        // And the lookups and reads are local now, with the Worker unreachable.
        await upstream.setDown(true)
        for key in keys {
            let value = try await client.actionGet(key)
            XCTAssertNotNil(value)
        }
        for object in objects {
            let local = try await client.get(object.digest)
            XCTAssertEqual(local, object)
        }
        await client.close()
    }

    func testABuildThatStartsWithAnotherActionStillFindsTheTrace() async throws {
        let (keys, objects) = await seedBuild(30)
        try await build(keys)
        await upstream.resetCounters()

        // The compile jobs started in a different order: the first lookup is not the old first.
        await daemon.stop()
        let fake = upstream!
        daemon = CASDaemon(.init(directory: directory.appendingPathComponent("shuffled"), maxBytes: 64 << 20) { _ in fake })
        port = try await daemon.start()
        let client = try client()
        for key in [keys[5], keys[2], keys[0]] { _ = try await client.actionGet(key) }

        var fetched = 0
        for _ in 0..<100 {
            fetched = await upstream.gets.count
            if fetched >= objects.count { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(fetched, objects.count, "found under a later lookup, and the whole build was fetched")
        await client.close()
    }

    func testATraceThatCouldNotBeSentIsSentAtTheNextFlush() async throws {
        let (keys, _) = await seedBuild(6)
        await daemon.stop()
        let fake = upstream!
        daemon = CASDaemon(.init(directory: directory.appendingPathComponent("retry-trace"), maxBytes: 64 << 20) { _ in fake })
        port = try await daemon.start()
        let client = try client()
        for key in keys { _ = try await client.actionGet(key) }

        await upstream.setDown(true)            // the Worker is away at the first flush
        await daemon.drain()
        let early = await upstream.traces[keys[0]]
        XCTAssertNil(early)

        await upstream.setDown(false)           // and back at the next
        await daemon.drain()
        let later = await upstream.traces[keys[0]]
        XCTAssertEqual(later, keys, "the trace was not given up on")
        await client.close()
    }

    func testAnUnchangedTraceIsNotUploadedAgain() async throws {
        let (keys, _) = await seedBuild(10)
        try await build(keys)
        let once = await upstream.tracePuts
        try await build(keys)
        // The second build started from the trace the first left, and looked up the same keys.
        try await Task.sleep(for: .milliseconds(200))
        let twice = await upstream.tracePuts
        XCTAssertEqual(once, 8, "one trace, kept under each of the first 8 lookups")
        XCTAssertEqual(twice, 8, "nothing new to record")
    }

    func testATraceIsUploadedShortlyAfterTheLastNewLookupWithoutAStop() async throws {
        let (keys, _) = await seedBuild(6)
        await daemon.stop()
        let fake = upstream!
        // A debounce well above the pauses a slow machine leaves between six lookups.
        daemon = CASDaemon(.init(directory: directory.appendingPathComponent("debounced"), maxBytes: 64 << 20, traceDebounce: .milliseconds(600)) { _ in fake })
        port = try await daemon.start()
        let client = try client()
        for key in keys { _ = try await client.actionGet(key) }
        var trace: [CASDigest]?
        for _ in 0..<100 where trace?.count != keys.count {
            try await Task.sleep(for: .milliseconds(50))
            trace = await upstream.traces[keys[0]]
        }
        XCTAssertEqual(trace, keys, "uploaded without a stop, once the lookups paused")
        let puts = await upstream.tracePuts
        XCTAssertLessThanOrEqual(puts, keys.count, "one round of uploads (one per anchor), not one per lookup")
        await client.close()
    }

    func testAWorkerWithoutTracesStillServesLookups() async throws {
        // `ClientUpstream` and the default methods treat a missing trace as nothing to do.
        let (keys, _) = await seedBuild(3)
        await upstream.setDown(true)
        let client = try client()
        let answer = try await client.actionGet(keys[0])
        XCTAssertNil(answer, "a failed lookup is a miss, and the trace lookup that follows it fails quietly")
        await client.close()
    }

    // MARK: Scopes

    private func restart(maxScopes: Int) async throws {
        await daemon.stop()
        let fake = upstream!
        daemon = CASDaemon(.init(directory: directory, maxBytes: 1 << 20, retryInterval: .seconds(3600), maxScopes: maxScopes) { _ in fake })
        port = try await daemon.start()
    }

    private func status(ofScope scope: String) async throws -> Bool {
        let client = try self.client(scope)
        defer { Task { await client.close() } }
        do { return try await client.status().storageConfigured } catch { return false }
    }

    func testTheOldestIdleScopeIsRetiredToMakeRoomForANewOne() async throws {
        try await restart(maxScopes: 2)
        for scope in ["one", "two", "three"] {
            let served = try await status(ofScope: scope)
            XCTAssertTrue(served, scope)
        }
        // "one" was retired for "three", and is opened again when it is asked for.
        let again = try await status(ofScope: "one")
        XCTAssertTrue(again)
    }

    func testANewScopeIsRefusedWhileEveryOpenOneHasWorkPending() async throws {
        try await restart(maxScopes: 1)
        await upstream.setDown(true)
        let busy = try client("busy")
        let object = blob("unsent")
        try await busy.put(object)
        try await busy.actionPut(blob("pending key").digest, value: object.digest)

        let url = URL(string: "http://127.0.0.1:\(port)/another/objects/\(object.digest.hex)")!
        let (_, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
        await busy.close()
    }

    func testScopesThatDifferOnlyInCaseGetDifferentDirectories() async throws {
        let names = ["Prod", "prod", "PROD", "p_rod", "P_rod", "pRod", "_prod", "__prod", "a.B", "a.b"]
        let directories = names.map { CASDaemon.directoryName(for: $0).lowercased() }
        XCTAssertEqual(Set(directories).count, names.count, "no two scopes may meet on a case-insensitive disk: \(directories)")

        let upper = try client("Prod"), lower = try client("prod")
        let object = blob("belongs to Prod")
        try await upper.put(object)
        let seen = try await lower.get(object.digest)
        XCTAssertNil(seen)
        await upper.close()
        await lower.close()
    }

    func testABurstOfNewScopesNeverExceedsTheCap() async throws {
        try await restart(maxScopes: 2)
        let port = self.port
        let codes = await withTaskGroup(of: Int.self) { group in
            for index in 0..<12 {
                group.addTask {
                    let url = URL(string: "http://127.0.0.1:\(port)/burst\(index)/objects/\(String(repeating: "a", count: 64))")!
                    let (_, response) = try! await URLSession.shared.data(from: url)
                    return (response as? HTTPURLResponse)?.statusCode ?? 0
                }
            }
            return await group.reduce(into: [Int]()) { $0.append($1) }
        }
        XCTAssertTrue(codes.allSatisfy { $0 == 404 || $0 == 503 }, "\(codes)")
        let open = daemon.openScopeCount
        XCTAssertLessThanOrEqual(open, 2, "scopes open: \(open)")
    }

    func testScopeDirectoriesOnDiskAreBounded() async throws {
        await daemon.stop()
        let fake = upstream!
        daemon = CASDaemon(.init(directory: directory, maxBytes: 1 << 20, maxScopes: 1, maxScopeDirectories: 3) { _ in fake })
        port = try await daemon.start()
        for scope in ["d1", "d2", "d3", "d4", "d5", "d6"] {
            let served = try await status(ofScope: scope)
            XCTAssertTrue(served, scope)
            try await Task.sleep(for: .milliseconds(30))     // distinct modification times
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let scopes = names.filter { $0.hasPrefix("d") }
        XCTAssertLessThanOrEqual(scopes.count, 3, "scope directories on disk: \(scopes.sorted())")
        XCTAssertTrue(scopes.contains("d6"), "the newest is kept")
    }

    func testAScopeThatFailedToOpenIsNotKeptAndCanBeOpenedLater() async throws {
        try await restart(maxScopes: 2)
        // A file where the scope's directory should go: opening it fails.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appendingPathComponent("blocked")
        try Data("in the way".utf8).write(to: blocker)
        let failed = try await status(ofScope: "blocked")
        XCTAssertFalse(failed)
        let stuck = try await status(ofScope: "blocked")
        XCTAssertFalse(stuck)
        // Failed openings must not use up the places, nor remember the failure.
        XCTAssertEqual(daemon.openScopeCount, 0)

        try FileManager.default.removeItem(at: blocker)
        let recovered = try await status(ofScope: "blocked")
        XCTAssertTrue(recovered, "the filesystem recovered, and so did the scope")
    }

    func testPruningNeverDeletesAScopeDirectoryHoldingUnsentWrites() async throws {
        await daemon.stop()
        let fake = upstream!
        func start() async throws {
            daemon = CASDaemon(.init(
                directory: directory, maxBytes: 1 << 20, retryInterval: .seconds(3600),
                maxScopes: 1, maxScopeDirectories: 2) { _ in fake })
            port = try await daemon.start()
        }
        try await start()
        await upstream.setDown(true)                     // what is written stays pending
        let object = blob("acknowledged but unsent")
        let key = blob("unsent key").digest
        let writer = try client("keeper")
        try await writer.put(object)
        try await writer.actionPut(key, value: object.digest)
        await writer.close()

        // A restart: "keeper" is no longer open, and is the oldest directory.
        await daemon.stop()
        try await start()
        for scope in ["x1", "x2", "x3"] {
            let served = try await status(ofScope: scope)
            _ = served
            try await Task.sleep(for: .milliseconds(30))
        }
        let kept = FileManager.default.fileExists(atPath: directory.appendingPathComponent("keeper/pending").path)
        XCTAssertTrue(kept, "the directory with unsent writes survives pruning")

        // The Worker comes back and the scope is opened: what was acknowledged is sent.
        await upstream.setDown(false)
        let again = try client("keeper")
        _ = try await again.status()
        await daemon.drain()
        let stored = await upstream.actions[key]
        XCTAssertEqual(stored, object.digest)
        await again.close()
    }

    func testANewScopeIsRefusedWhenEveryDirectoryHoldsUnsentWrites() async throws {
        await daemon.stop()
        let fake = upstream!
        func start(maxScopes: Int) async throws {
            daemon = CASDaemon(.init(
                directory: directory, maxBytes: 1 << 20, retryInterval: .seconds(3600),
                maxScopes: maxScopes, maxScopeDirectories: 2) { _ in fake })
            port = try await daemon.start()
        }
        try await start(maxScopes: 2)
        await upstream.setDown(true)
        for scope in ["first", "second"] {
            let writer = try client(scope)
            let object = blob("unsent in \(scope)")
            try await writer.put(object)
            try await writer.actionPut(blob("key \(scope)").digest, value: object.digest)
            await writer.close()
            try await Task.sleep(for: .milliseconds(30))
        }
        // After a restart nothing is open, but both directories hold unsent writes.
        await daemon.stop()
        try await start(maxScopes: 2)
        let url = URL(string: "http://127.0.0.1:\(port)/third/objects/\(String(repeating: "a", count: 64))")!
        let (_, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503, "no directory can be removed safely")
        for scope in ["first", "second"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(scope)/pending").path), scope)
        }
    }

    func testAScopeWithAnOpenConnectionIsNotRetiredUnderIt() async throws {
        try await restart(maxScopes: 2)
        let keep = try client("keep")
        _ = try await keep.status()                       // a WebSocket to "keep", held open
        for scope in ["other-one", "other-two", "other-three"] {
            let served = try await status(ofScope: scope)
            _ = served
        }
        let object = blob("written after the churn")
        try await keep.put(object)
        try await keep.actionPut(blob("kept key").digest, value: object.digest)
        let value = try await keep.actionGet(blob("kept key").digest)
        XCTAssertEqual(value, object.digest, "the connection still writes to a live scope")
        await keep.close()
    }

    func testScopeNamesAreTheWorkersRules() async throws {
        let digest = String(repeating: "a", count: 64)
        func code(_ scope: String) async throws -> Int {
            let url = URL(string: "http://127.0.0.1:\(port)/\(scope)/objects/\(digest)")!
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        let accepted = try await code(String(repeating: "a", count: 63))
        XCTAssertEqual(accepted, 404, "63 characters is a scope (the object is just not there)")
        for refused in [String(repeating: "a", count: 64), "has.dot", "caf%C3%A9"] {
            let status = try await code(refused)
            XCTAssertEqual(status, 404, refused)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(refused).path), refused)
        }
        // A refused scope never opened: only the valid one made a directory.
        let made = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).count
        XCTAssertEqual(made, 1)
    }

    func testARequestThePathDoesNotServeOpensNoScope() async throws {
        for path in ["/ghost/bogus", "/ghost/objects/not-a-digest", "/ghost"] {
            let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404, path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ghost").path))
    }

    // MARK: HTTP POST transport

    func testTheClientCanCallOverOnePostPerCall() async throws {
        let object = blob("by post")
        await upstream.seed(object)
        let key = blob("post key").digest
        await upstream.seed(action: key, value: object.digest)

        let client = try CASClient(workerURL: URL(string: "http://127.0.0.1:\(port)/s")!, transport: .httpPost)
        let status = try await client.status()
        XCTAssertTrue(status.storageConfigured)
        let value = try await client.actionGet(key)
        XCTAssertEqual(value, object.digest)
        let answers = try await client.actionGetMany([key, blob("absent").digest])
        XCTAssertEqual(answers, [object.digest, nil])
        let has = try await client.contains(blob("absent").digest)
        XCTAssertFalse(has)
        // Many at once: each is its own request.
        let many = try await withThrowingTaskGroup(of: CASDigest?.self) { group in
            for _ in 0..<30 { group.addTask { try await client.actionGet(key) } }
            return try await group.reduce(into: [CASDigest?]()) { $0.append($1) }
        }
        XCTAssertEqual(many.count, 30)
        XCTAssertTrue(many.allSatisfy { $0 == object.digest })
        await client.close()
    }

    func testTheDaemonsUpstreamUsesPostWhenTheWorkerServesIt() async throws {
        // A second daemon in front of the first one, which plays the Worker.
        let object = blob("through two daemons")
        await upstream.seed(object)
        let key = blob("chained key").digest
        await upstream.seed(action: key, value: object.digest)
        let workerPort = port
        let front = CASDaemon(.init(
            directory: directory.appendingPathComponent("front"), maxBytes: 64 << 20
        ) { scope in ClientUpstream(url: URL(string: "http://127.0.0.1:\(workerPort)/\(scope)")!, transport: .automatic) })
        let frontPort = try await front.start()
        let client = try CASClient(workerURL: URL(string: "http://127.0.0.1:\(frontPort)/s")!)
        let value = try await client.actionGet(key)
        XCTAssertEqual(value, object.digest)
        let blobBack = try await client.get(object.digest)
        XCTAssertEqual(blobBack, object)
        await client.close()
        await front.stop()
    }

    func testCallsThatArriveTogetherShareOneClient() async throws {
        let upstreamClient = ClientUpstream(url: URL(string: "http://127.0.0.1:\(port)/s")!, transport: .automatic)
        let key = blob("shared client").digest
        _ = try await withThrowingTaskGroup(of: CASDigest?.self) { group in
            for _ in 0..<25 { group.addTask { try await upstreamClient.actionGet(key) } }
            return try await group.reduce(into: [CASDigest?]()) { $0.append($1) }
        }
        let made = await upstreamClient.clientsCreated
        XCTAssertEqual(made, 1, "25 calls at once opened \(made) clients")
    }

    func testCacheSizesThatCannotBeHeldAreUsageErrorsNotCrashes() {
        XCTAssertEqual(CASDaemon.cacheBytes(gigabytes: "4"), 4 << 30)
        XCTAssertEqual(CASDaemon.cacheBytes(gigabytes: "0.5"), 1 << 29)
        for bad in ["nan", "inf", "-inf", "-1", "0", "1e300", "abc", "", "9999999999999999"] {
            XCTAssertNil(CASDaemon.cacheBytes(gigabytes: bad), bad)
        }
    }

    func testListenAddressesAreParsedIncludingIPv6() {
        XCTAssertEqual(CASDaemon.parseListenAddress("127.0.0.1:4170")?.host, "127.0.0.1")
        XCTAssertEqual(CASDaemon.parseListenAddress("127.0.0.1:4170")?.port, 4170)
        XCTAssertEqual(CASDaemon.parseListenAddress("[::1]:4170")?.host, "::1")
        XCTAssertEqual(CASDaemon.parseListenAddress("[::1]:4170")?.port, 4170)
        XCTAssertEqual(CASDaemon.parseListenAddress("::1:4170")?.host, "::1")
        XCTAssertEqual(CASDaemon.parseListenAddress("localhost:80")?.port, 80)
        XCTAssertNil(CASDaemon.parseListenAddress("nonsense"))
        XCTAssertNil(CASDaemon.parseListenAddress("1.2.3.4:abc"))
        XCTAssertNil(CASDaemon.parseListenAddress(":4170"))
        XCTAssertNil(CASDaemon.parseListenAddress("127.0.0.1:99999"))
    }

    func testPruningNeverDeletesAScopeHoldingObjectsNoActionHasClaimedYet() async throws {
        await daemon.stop()
        let fake = upstream!
        func start() async throws {
            daemon = CASDaemon(.init(
                directory: directory, maxBytes: 1 << 20, retryInterval: .seconds(3600),
                maxScopes: 1, maxScopeDirectories: 2) { _ in fake })
            port = try await daemon.start()
        }
        try await start()
        let writer = try client("holder")
        let object = blob("stored, not yet claimed")
        try await writer.put(object)          // acknowledged: its only copy may be the spool
        await writer.close()
        await daemon.stop()
        try await start()
        for scope in ["y1", "y2", "y3"] {
            let served = try await status(ofScope: scope)
            _ = served
            try await Task.sleep(for: .milliseconds(30))
        }
        let spooled = directory.appendingPathComponent("holder/spool")
            .appendingPathComponent(String(object.digest.hex.prefix(2))).appendingPathComponent(object.digest.hex)
        XCTAssertTrue(FileManager.default.fileExists(atPath: spooled.path), "the unclaimed object survived pruning")
    }

    func testTheDaemonForwardsTraceCallsLikeTheWorker() async throws {
        let (keys, _) = await seedBuild(5)
        let client = try client()
        try await client.tracePut(keys[0], keys: keys)
        let stored = await upstream.traces[keys[0]]
        XCTAssertEqual(stored, keys, "the trace went upstream")
        let back = try await client.traceGet(keys[0])
        XCTAssertEqual(back, keys)
        let none = try await client.traceGet(blob("no trace").digest)
        XCTAssertNil(none)
        await client.close()
    }

    func testPendingActionsAreBoundedAndRefusedWhenTheQueueIsFull() async throws {
        await daemon.stop()
        let fake = upstream!
        daemon = CASDaemon(.init(
            directory: directory, maxBytes: 1 << 20, retryInterval: .seconds(3600), maxPendingActions: 3) { _ in fake })
        port = try await daemon.start()
        await upstream.setDown(true)                      // nothing can be sent
        let client = try client()
        let object = blob("queued value")
        try await client.put(object)

        var refused = 0
        for index in 0..<6 {
            do { try await client.actionPut(blob("queued \(index)").digest, value: object.digest) } catch { refused += 1 }
        }
        XCTAssertEqual(refused, 3, "room for three pending actions")
        // A repeat of one already pending is not a new one.
        try await client.actionPut(blob("queued 0").digest, value: object.digest)

        await upstream.setDown(false)
        await daemon.drain()                              // they are sent, which makes room
        try await client.actionPut(blob("after the queue drained").digest, value: object.digest)
        await client.close()
    }

    func testInvalidPendingMarkersDoNotCountAgainstTheQueue() async throws {
        await daemon.stop()
        let fake = upstream!
        // Junk in a scope's pending folder from some earlier run, before the scope is opened.
        let pending = directory.appendingPathComponent("s/pending")
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        for index in 0..<5 { try Data().write(to: pending.appendingPathComponent("not-a-digest-\(index)")) }
        daemon = CASDaemon(.init(
            directory: directory, maxBytes: 1 << 20, retryInterval: .seconds(3600), maxPendingActions: 3) { _ in fake })
        port = try await daemon.start()
        let client = try client()
        let object = blob("after junk")
        try await client.put(object)
        try await client.actionPut(blob("first real action").digest, value: object.digest)
        await client.close()
    }

    func testTheInMemoryActionMapIsBoundedOnEveryPath() async throws {
        let cache = try await ScopeCache(
            directory: directory.appendingPathComponent("bounded"), maxBytes: 1 << 20, upstream: upstream,
            maxActionsInMemory: 5)
        let value = blob("v")
        try await cache.put(value)
        for index in 0..<20 { try await cache.actionPut(blob("written \(index)").digest, value: value.digest) }
        var held = await cache.actionsInMemory
        XCTAssertLessThanOrEqual(held, 5, "writes")
        // Read back from disk: each read goes into memory, and must respect the bound too.
        for index in 0..<20 { _ = await cache.actionGet(blob("written \(index)").digest) }
        held = await cache.actionsInMemory
        XCTAssertLessThanOrEqual(held, 5, "reads")
        await cache.drain()
    }

    func testTheSpoolIsBoundedAndRefusesWritesWhenFull() async throws {
        await daemon.stop()
        let fake = upstream!
        daemon = CASDaemon(.init(directory: directory, maxBytes: 1 << 20, retryInterval: .seconds(3600), maxSpoolBytes: 2500) { _ in fake })
        port = try await daemon.start()
        let client = try client()

        var accepted: [CASBlob] = []
        var refused = 0
        for index in 0..<6 {
            let object = CASBlob(refs: [], data: Array(repeating: UInt8(index), count: 1000))
            do {
                try await client.put(object)
                accepted.append(object)
            } catch {
                refused += 1
            }
        }
        XCTAssertEqual(accepted.count, 2, "room for two 1000-byte objects in 2500 bytes")
        XCTAssertEqual(refused, 4)

        // Once what is spooled has been sent, there is room again.
        let root = CASBlob(refs: accepted.map(\.digest), data: Array("root".utf8))
        try await client.put(root)
        await upstream.setDown(false)
        for index in 0..<2 { _ = index }
        try await client.actionPut(blob("spool key").digest, value: root.digest)
        await daemon.drain()
        let fresh = CASBlob(refs: [], data: Array(repeating: 9, count: 1000))
        try await client.put(fresh)
        await client.close()
    }

    func testTracesAreNotSwitchedOffByNetworkTrouble() async throws {
        struct Said: Error, CustomStringConvertible { var description: String }
        XCTAssertTrue(ClientUpstream.saysUnsupported(Said(description: "ExecuteDistributedTargetError(errorCode: targetAccessorNotFound)")))
        XCTAssertTrue(ClientUpstream.saysUnsupported(Said(description: "Failed to locate distributed function accessor")))
        XCTAssertFalse(ClientUpstream.saysUnsupported(Said(description: "the Worker did not answer in time")))
        XCTAssertFalse(ClientUpstream.saysUnsupported(Said(description: "The request timed out.")))

        // A Worker that never answers: five trace calls in a row all time out, and none of
        // them is turned away as "unsupported".
        let silent = SilentServer()
        let upstream = ClientUpstream(url: URL(string: "http://127.0.0.1:\(silent.port)/s")!, timeout: .milliseconds(150), transport: .httpPost)
        for attempt in 1...5 {
            do {
                _ = try await upstream.traceGet(blob("k").digest)
                XCTFail("no answer was expected")
            } catch {
                XCTAssertFalse(error is UpstreamUnsupported, "attempt \(attempt): \(error)")
            }
        }
    }

    func testACallToAWorkerThatNeverAnswersFailsInsteadOfHanging() async throws {
        let silent = SilentServer()
        let upstream = ClientUpstream(url: URL(string: "http://127.0.0.1:\(silent.port)/s")!, timeout: .milliseconds(400))
        let started = ContinuousClock.now
        do {
            _ = try await upstream.actionGet(blob("anything").digest)
            XCTFail("a call with no answer succeeded")
        } catch {}
        let took = ContinuousClock.now - started
        XCTAssertLessThan(took, .seconds(10), "the call gave up after \(took)")
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
