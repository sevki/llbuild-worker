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
