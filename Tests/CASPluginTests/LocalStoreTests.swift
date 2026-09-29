import CASProtocol
import Foundation
import XCTest

@testable import CASPlugin

final class LocalStoreTests: XCTestCase {
    private func makeStore() throws -> LocalStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cas-plugin-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return LocalStore(root: root)
    }

    func testObjectRoundTripWithRefs() throws {
        let store = try makeStore()
        let leaf = StoredObject(refs: [], data: [1, 2, 3])
        let leafID = CASIdentity.identify(refs: [], data: leaf.data)
        try store.put(leaf, digest: leafID)

        let parent = StoredObject(refs: [leafID], data: Array("payload".utf8))
        let parentID = CASIdentity.identify(refs: parent.refs, data: parent.data)
        try store.put(parent, digest: parentID)

        XCTAssertTrue(store.contains(parentID))
        let loaded = try XCTUnwrap(try store.get(parentID))
        XCTAssertEqual(loaded.refs, [leafID])
        XCTAssertEqual(loaded.data, Array("payload".utf8))
        XCTAssertNil(try store.get(CASIdentity.identify(refs: [], data: [9])))
    }

    func testEmptyObject() throws {
        let store = try makeStore()
        let id = CASIdentity.identify(refs: [], data: [])
        try store.put(StoredObject(refs: [], data: []), digest: id)
        XCTAssertEqual(try store.get(id)?.data, [])
    }

    func testActionCache() throws {
        let store = try makeStore()
        let key = CASIdentity.identify(refs: [], data: Array("key".utf8))
        let value = CASIdentity.identify(refs: [], data: Array("value".utf8))
        XCTAssertNil(try store.actionGet(key))
        try store.actionPut(key, value: value)
        XCTAssertEqual(try store.actionGet(key), value)
    }
}
