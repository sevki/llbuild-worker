import Foundation
import XCTest

@testable import CASPlugin

final class RemoteConfigTests: XCTestCase {
    private func file(_ contents: String) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-config-\(UUID().uuidString)").path
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    func testNoRemoteConfigured() throws {
        XCTAssertNil(try RemoteConfig.resolve(options: [:], environment: [:]))
    }

    func testRemoteURLOption() throws {
        XCTAssertEqual(
            try RemoteConfig.resolve(options: ["remote-url": "https://cas.example.workers.dev"], environment: [:]),
            URL(string: "https://cas.example.workers.dev"))
        XCTAssertThrowsError(try RemoteConfig.resolve(options: ["remote-url": "ftp://x"], environment: [:]))
        XCTAssertThrowsError(try RemoteConfig.resolve(options: ["remote-url": "not a url"], environment: [:]))
    }

    func testRemoteServicePathAsURLOrConfigFile() throws {
        // What Xcode passes: COMPILATION_CACHE_REMOTE_SERVICE_PATH as `remote-service-path`.
        XCTAssertEqual(
            try RemoteConfig.resolve(options: ["remote-service-path": "http://127.0.0.1:8787"], environment: [:]),
            URL(string: "http://127.0.0.1:8787"))
        XCTAssertEqual(
            try RemoteConfig.resolve(options: ["remote-service-path": try file("https://a.example\n")], environment: [:]),
            URL(string: "https://a.example"))
        XCTAssertEqual(
            try RemoteConfig.resolve(
                options: ["remote-service-path": try file(#"{"url": "https://b.example"}"#)], environment: [:]),
            URL(string: "https://b.example"))
    }

    func testBadConfigFilesAreErrorsNotSilentlyIgnored() throws {
        XCTAssertThrowsError(try RemoteConfig.resolve(options: ["remote-service-path": "/nonexistent/path"], environment: [:]))
        XCTAssertThrowsError(try RemoteConfig.resolve(options: ["remote-service-path": try file("{}")], environment: [:]))
        XCTAssertThrowsError(try RemoteConfig.resolve(options: ["remote-service-path": try file("garbage")], environment: [:]))
    }

    func testPrecedenceAndEnvironmentFallback() throws {
        let env = ["LLBUILD_CAS_REMOTE_URL": "https://env.example"]
        XCTAssertEqual(try RemoteConfig.resolve(options: [:], environment: env), URL(string: "https://env.example"))
        XCTAssertEqual(
            try RemoteConfig.resolve(
                options: ["remote-service-path": "https://path.example"], environment: env),
            URL(string: "https://path.example"))
        XCTAssertEqual(
            try RemoteConfig.resolve(
                options: ["remote-url": "https://url.example", "remote-service-path": "https://path.example"],
                environment: env),
            URL(string: "https://url.example"))
    }
}
