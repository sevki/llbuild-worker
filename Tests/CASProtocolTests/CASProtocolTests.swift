import CASClient
import CASProtocol
import Foundation
import WorkerKitDistributed
import XCTest

final class CASProtocolTests: XCTestCase {
    func testCASObjectCodableRoundTrip() throws {
        let original = CASObject(
            refs: [CASID(value: "0~YWJj")],
            data: Data([0, 1, 2, 255])
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CASObject.self, from: encoded)

        XCTAssertEqual(decoded, original)
    }

    func testCASServiceStatusCodableRoundTrip() throws {
        let original = CASServiceStatus(
            service: "llbuild-worker",
            protocolVersion: "0.1.0",
            storageConfigured: false
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CASServiceStatus.self, from: encoded)

        XCTAssertEqual(decoded, original)
    }
}

final class CASIdentityTests: XCTestCase {
    private func hex(_ bytes: [UInt8]) -> String { CASDigest(bytes: bytes).hex }

    func testSHA256KnownVectors() {
        XCTAssertEqual(
            hex(SHA256.hash([])),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(
            hex(SHA256.hash(Array("abc".utf8))),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // 56 bytes: forces the padding into a second block.
        XCTAssertEqual(
            hex(SHA256.hash(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    func testSHA256IncrementalMatchesOneShot() {
        let data = (0..<1000).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        var hasher = SHA256()
        hasher.update(Array(data[0..<3]))
        hasher.update(Array(data[3..<200]))
        hasher.update(Array(data[200...]))
        XCTAssertEqual(hasher.finalize(), SHA256.hash(data))
    }

    func testIdentityDependsOnRefsAndData() {
        let leaf = CASIdentity.identify(refs: [], data: [1, 2, 3])
        XCTAssertEqual(leaf, CASIdentity.identify(refs: [], data: [1, 2, 3]))
        XCTAssertNotEqual(leaf, CASIdentity.identify(refs: [], data: [1, 2, 4]))
        let parent = CASIdentity.identify(refs: [leaf], data: [1, 2, 3])
        XCTAssertNotEqual(leaf, parent)
        // Ref order matters, and data cannot masquerade as a ref.
        let other = CASIdentity.identify(refs: [], data: [9])
        XCTAssertNotEqual(
            CASIdentity.identify(refs: [leaf, other], data: []),
            CASIdentity.identify(refs: [other, leaf], data: []))
        XCTAssertNotEqual(
            CASIdentity.identify(refs: [leaf], data: []),
            CASIdentity.identify(refs: [], data: leaf.bytes))
    }

    func testDigestHexRoundTrip() {
        let digest = CASIdentity.identify(refs: [], data: [42])
        XCTAssertEqual(CASDigest(hex: digest.hex), digest)
        XCTAssertNil(CASDigest(hex: "zz"))
        XCTAssertNil(CASDigest(hex: "abc"))
    }
}

final class CASChunkingTests: XCTestCase {
    func testChunksCoverTheDataInOrder() {
        let data = (0..<(CASLimits.chunkBytes * 2 + 17)).map { UInt8(truncatingIfNeeded: $0) }
        let chunks = CASChunking.chunks(of: data)
        XCTAssertEqual(chunks.map(\.count), [CASLimits.chunkBytes, CASLimits.chunkBytes, 17])
        XCTAssertEqual(Array(chunks.joined()), data)
        XCTAssertEqual(CASChunking.chunks(of: []).count, 0)
    }

    func testManifestRoundTripAndRejection() {
        XCTAssertEqual(CASChunking.size(ofManifestData: CASChunking.manifestData(size: 123_456_789)), 123_456_789)
        XCTAssertNil(CASChunking.size(ofManifestData: []))
        XCTAssertNil(CASChunking.size(ofManifestData: Array("not a manifest at all".utf8)))
        var truncated = CASChunking.manifestData(size: 5)
        truncated.removeLast()
        XCTAssertNil(CASChunking.size(ofManifestData: truncated))
    }

    // MARK: Authentication

    func testTokenInTheQueryIsPercentDecoded() {
        // URLQueryItem may escape the padding of a base64 token.
        XCTAssertEqual(presentedToken(url: "https://w/__rpc?token=abc%3D", authorization: nil), "abc=")
        XCTAssertEqual(presentedToken(url: "https://w/__rpc?x=1&token=abc=&y=2", authorization: nil), "abc=")
        XCTAssertEqual(presentedToken(url: "https://w/__rpc?token=a%2Fb%2Bc", authorization: nil), "a/b+c")
        XCTAssertEqual(presentedToken(url: "https://w/__rpc?token=plain#frag", authorization: nil), "plain")
        XCTAssertNil(presentedToken(url: "https://w/__rpc", authorization: nil))
    }

    func testBearerTokenWinsAndClientEncodingAuthenticates() throws {
        XCTAssertEqual(presentedToken(url: "https://w/__rpc?token=q", authorization: "Bearer h"), "h")
        // What the client really sends must compare equal to the configured token.
        let token = "dGVzdC10b2tlbg=="
        let url = CASClient.authenticated(
            try XCTUnwrap(URL(string: "https://worker.example/__rpc")),
            environment: ["LLBUILD_CAS_TOKEN": token], tokenPath: "/nonexistent")
        let presented = try XCTUnwrap(presentedToken(url: url.absoluteString, authorization: nil))
        XCTAssertTrue(constantTimeEqual(presented, token))
        XCTAssertFalse(constantTimeEqual(presented, token + "x"))
    }

    // MARK: Action cache

    func testActionPutRefusesAValueThatIsNotStored() async throws {
        let backend = RecordingBackend()
        let service = CASService(actorSystem: WorkersActorSystem(worker: URL(string: "ws://127.0.0.1:1")!), backend: backend)
        let key = String(repeating: "a", count: 64), value = String(repeating: "b", count: 64)

        do {
            try await service.actionPut(key: key, value: value)
            XCTFail("an action pointing at a missing object was accepted")
        } catch let error as CASServiceError {
            XCTAssertEqual(error, .missingObject(value))
        }
        XCTAssertTrue(backend.actions.isEmpty, "the key must stay free so a good value can still be written")

        backend.stored.insert(value)
        try await service.actionPut(key: key, value: value)
        XCTAssertEqual(backend.actions[key], value)
    }

    func testActionGetManyAnswersInTheOrderOfTheKeys() async throws {
        let backend = RecordingBackend()
        let service = CASService(actorSystem: WorkersActorSystem(worker: URL(string: "ws://127.0.0.1:1")!), backend: backend)
        let keys = ["a", "b", "c", "d"].map { String(repeating: $0, count: 64) }
        backend.actions[keys[0]] = "1" + String(repeating: "0", count: 63)
        backend.actions[keys[2]] = "2" + String(repeating: "0", count: 63)

        let answers = try await service.actionGetMany(keys: keys)
        XCTAssertEqual(answers, [backend.actions[keys[0]], nil, backend.actions[keys[2]], nil])
        let none = try await service.actionGetMany(keys: [])
        XCTAssertEqual(none, [])
    }

    func testActionGetManyRefusesABadKeyAndAnOversizedBatch() async throws {
        let service = CASService(
            actorSystem: WorkersActorSystem(worker: URL(string: "ws://127.0.0.1:1")!), backend: RecordingBackend())
        do {
            _ = try await service.actionGetMany(keys: ["not a digest"])
            XCTFail("a bad key was accepted")
        } catch let error as CASServiceError {
            XCTAssertEqual(error, .invalidDigest("not a digest"))
        }
        let many = Array(repeating: String(repeating: "a", count: 64), count: CASLimits.maxBatchKeys + 1)
        do {
            _ = try await service.actionGetMany(keys: many)
            XCTFail("an oversized batch was accepted")
        } catch let error as CASServiceError {
            XCTAssertEqual(error, .objectTooLarge(size: many.count, limit: CASLimits.maxBatchKeys))
        }
    }
}

private final class RecordingBackend: CASBackend, @unchecked Sendable {
    var stored = Set<String>()
    var actions = [String: String]()

    func contains(digest: String) async throws -> Bool { stored.contains(digest) }
    func put(digest: String, refs: [String], data: String) async throws {}
    func get(digest: String) async throws -> CASObjectPayload? { nil }
    func actionGet(key: String) async throws -> String? { actions[key] }
    func actionPut(key: String, value: String) async throws { actions[key] = value }
    func putLarge(digest: String, refs: [String], manifest: String) async throws {}
    func getLarge(digest: String) async throws -> CASLargeObject? { nil }
}

final class ByteSizeTests: XCTestCase {
    func testUsesSIUnitsNotBinary() {
        XCTAssertEqual(ByteSize.unitSymbols, ["B", "kB", "MB", "GB", "TB"])
        XCTAssertEqual(ByteSize.format(0), "0 B")
        XCTAssertEqual(ByteSize.format(999), "999 B")
        XCTAssertEqual(ByteSize.format(1000), "1.0 kB")
        XCTAssertEqual(ByteSize.format(1024), "1.0 kB", "1024 bytes is 1.0 kB in SI, not 1 KiB")
        XCTAssertEqual(ByteSize.format(1_500), "1.5 kB")
        XCTAssertEqual(ByteSize.format(512 * 1024), "524.3 kB")
        XCTAssertEqual(ByteSize.format(1_000_000), "1.0 MB")
        XCTAssertEqual(ByteSize.format(64 * 1024 * 1024), "67.1 MB")
        XCTAssertEqual(ByteSize.format(2_500_000_000), "2.5 GB")
        XCTAssertEqual(ByteSize.format(3_000_000_000_000), "3.0 TB")
    }

    func testEveryUnitIsOneStepAboveTheLast() {
        // The step is derived from the first two prefixes; this is what makes
        // that valid: each later unit begins exactly one step further up.
        XCTAssertEqual(ByteSize.step, 1000)
        var size = ByteSize.step
        for symbol in ByteSize.unitSymbols.dropFirst() {
            XCTAssertEqual(ByteSize.format(size), "1.0 \(symbol)")
            size *= ByteSize.step
        }
    }

    func testRoundingNeverShowsAThousandOfTheSmallerUnit() {
        XCTAssertEqual(ByteSize.format(999_949), "999.9 kB")
        XCTAssertEqual(ByteSize.format(999_950), "1.0 MB")
        XCTAssertEqual(ByteSize.format(999_999_999), "1.0 GB")
        // Beyond the largest prefix it keeps counting in TB.
        XCTAssertEqual(ByteSize.format(1_500_000_000_000_000), "1500.0 TB")
    }
}
