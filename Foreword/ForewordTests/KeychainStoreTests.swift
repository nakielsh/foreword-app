//
//  KeychainStoreTests.swift
//  ForewordTests
//
//  Round-trips KeychainStore.set/get/delete with a per-test unique key.
//

import XCTest
@testable import Foreword

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

    // MARK: - Access-denied path / unhappy paths
    //
    // Real Keychain access-denial is gated by `kSecAttrAccessControl` +
    // user presence, which we cannot fake from a unit test. What we CAN
    // pin is the contract the rest of the app relies on:
    //
    //   * `get` on a non-existent key returns nil and does not crash.
    //   * `set` followed by `get` round-trips cleanly even with weird
    //     values (empty / unicode / multiline).
    //   * Stress: many parallel reads of an absent key all return nil
    //     without ever throwing or trapping.
    //
    // If a future regression introduces a fatalError on the SecItem
    // failure path (rather than returning nil / false), this triggers it.

    func testGetOnNonExistentKeyReturnsNilAndDoesNotCrash() {
        // Use a UUID that was never written to. Repeated reads must remain
        // nil and never trip a trap or fatalError.
        let absentKey = "absent." + UUID().uuidString
        for _ in 0..<10 {
            XCTAssertNil(KeychainStore.get(key: absentKey))
        }
    }

    func testSetWithEmptyValueRoundTripsAndDoesNotCrash() {
        // Empty string is a degenerate but valid value. `set` returns true
        // and a subsequent `get` returns the same empty string.
        XCTAssertTrue(KeychainStore.set(key: key, value: ""))
        XCTAssertEqual(KeychainStore.get(key: key), "")
    }

    func testSetWithUnicodeValueRoundTrips() {
        let weird = "🐈\u{200D}\u{2B1B} multiline\nvalue with NUL-adjacent \u{0001} chars"
        XCTAssertTrue(KeychainStore.set(key: key, value: weird))
        XCTAssertEqual(KeychainStore.get(key: key), weird)
    }

    func testParallelGetsOnAbsentKeyAllReturnNil() async {
        // Fans out 16 concurrent `get` calls; the underlying SecItem API is
        // thread-safe but a future caching layer could regress this. All
        // must return nil; none may crash or hang.
        let absentKey = "absent." + UUID().uuidString
        await withTaskGroup(of: String?.self) { group in
            for _ in 0..<16 {
                group.addTask { KeychainStore.get(key: absentKey) }
            }
            for await result in group {
                XCTAssertNil(result)
            }
        }
    }
}
