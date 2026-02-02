//
//  KeychainStoreTests.swift
//  WorkHomepageTests
//
//  Round-trips KeychainStore.set/get/delete with a per-test unique key.
//

import XCTest
@testable import WorkHomepage

final class KeychainStoreTests: XCTestCase {
    private var key: String = ""

    override func setUp() {
        super.setUp()
        key = "test." + UUID().uuidString
    }

    override func tearDown() {
        KeychainStore.delete(key: key)
        super.tearDown()
    }

    func testSetThenGetReturnsValue() {
        let value = "secret-" + UUID().uuidString
        XCTAssertTrue(KeychainStore.set(key: key, value: value))
        XCTAssertEqual(KeychainStore.get(key: key), value)
    }

    func testGetReturnsNilWhenAbsent() {
        XCTAssertNil(KeychainStore.get(key: key))
    }

    func testSetReplacesExistingValue() {
        XCTAssertTrue(KeychainStore.set(key: key, value: "first"))
        XCTAssertTrue(KeychainStore.set(key: key, value: "second"))
        XCTAssertEqual(KeychainStore.get(key: key), "second")
    }

    func testDeleteRemovesValue() {
        XCTAssertTrue(KeychainStore.set(key: key, value: "to-delete"))
        XCTAssertTrue(KeychainStore.delete(key: key))
        XCTAssertNil(KeychainStore.get(key: key))
    }

    func testDeleteOnAbsentKeyDoesNotCrashAndIsIdempotent() {
        // Should still report success-ish (errSecItemNotFound treated as success).
        XCTAssertTrue(KeychainStore.delete(key: key))
        XCTAssertTrue(KeychainStore.delete(key: key))
    }
}
