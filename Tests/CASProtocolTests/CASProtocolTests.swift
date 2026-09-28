import CASProtocol
import Foundation
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
